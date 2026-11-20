# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../rbac"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../document/artifact_refs"
require "./store"

module Facet
  module Artifact
    # Provenance-based read check for artifacts.
    #
    # An artifact is readable iff the caller can read at least one document
    # it was uploaded against. The link is recorded at upload time in
    # `artifact_owners`; `artifact_references` never participates in an
    # access decision (it's prune bookkeeping, see `doc/backend/artifact.md`
    # → Prune).
    #
    # For each live `artifact_owners` row, both must hold:
    #
    #   a) `RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)`
    #      → the caller has a `read` permission scoped to the document.
    #
    #   b) the caller's `visible_tags` covers the owner row's snapshot
    #      `view_tag` AND the live `tags` resolved from the doctype
    #      definition at `field_path`.
    #
    # Tag rules (from the design plan):
    #
    #   - Tightening a field's `tags` takes effect immediately.
    #   - Loosening them doesn't retroactively widen artifacts uploaded under
    #     the stricter tag (the snapshot `view_tag` on the owner row is the
    #     tighter floor).
    #   - A `field_path` that no longer resolves in the doctype fails
    #     closed → the row is skipped.
    #
    # System bypass returns `true`; the enforcers themselves short-circuit
    # for the `Principal::System` principal.
    module Access
      # Returns true when `auth_context` may read the artifact identified
      # by `artifact_id`. Non-disclosing on denial — every reason (no
      # owner rows, all owner docs deleted, no read permission, tags
      # uncovered, field_path unresolvable) collapses to `false` so the
      # caller surfaces a single 403/404 shape.
      def self.can_read?(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        artifact_id : String,
      ) : Bool
        # System bypass — every enforcer returns true for the system
        # principal. Note that artifacts uploaded against draft / non-live
        # documents are still gated by the live-document check below
        # (system bypass covers only the read permission, not the doc's
        # existence).
        owners = ::Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        return false if owners.empty?

        owners.any? do |owner|
          can_read_owner?(db, auth_context, owner)
        end
      end

      # Anonymous app-origin variant of `can_read?`. Returns true when the
      # artifact is reachable through the named app's grant ceiling — used by
      # the download gateway's `?app=` path. There is no user id and no role;
      # the gate is: "could any account via this app read this artifact?".
      #
      # Account-scoped standalone-upload owner rows never match — they are
      # bound to an account, not a document grant. Only document-scoped
      # owners participate.
      #
      # The tag gate (`tags_cover?`) is **not** consulted here. App
      # permissions are doc-level; field sensitivity tags are a per-role RBAC
      # concern, and we have no role (`doc/backend/artifact.md` →
      # Download gateway).
      def self.can_read_for_app?(
        db : DB::Connection,
        app_scope : ::Facet::RBAC::AppScope,
        artifact_id : String,
      ) : Bool
        owners = ::Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        return false if owners.empty?

        owners.any? do |owner|
          owner_readable_for_app?(db, app_scope, owner)
        end
      end

      # Returns true when `app_scope` may read the artifact through one
      # specific owner row. Exposed so `Artifact::Grants.mint_ephemeral_for_app`
      # doesn't re-issue the owner-row SQL fetch when it picks the provenance
      # to bind the grant against.
      def self.owner_readable_for_app?(
        db : DB::Connection,
        app_scope : ::Facet::RBAC::AppScope,
        owner : ::Facet::Artifact::Store::OwnerRow,
      ) : Bool
        # Account-scoped standalone uploads never authorise an app-origin
        # read — they are bound to an account, not a document grant.
        return false if owner.doc_type == ::Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE

        # The live-document join — same discipline as the user path. An
        # owner row pointing at a tombstoned document is skipped.
        return false unless ::Facet::Artifact::Store.document_live?(
                              db, owner.domain, owner.doc_type, owner.doc_id,
                            )

        # Does any grant in the app ceiling cover `read` on this owner's
        # `(domain, [doc_type])`? The owner row's `field_path` is the
        # normalized doctype-leaf path segment, not the doc path — the
        # grant ceiling is doc-level, so we match against `[doc_type]` only.
        # A grant action named `read` or the wildcard `*` permits the read.
        owner_path = [owner.doc_type]
        app_scope.grants.any? do |grant|
          grant.covers?(owner.domain, owner_path) &&
            grant.actions.any? { |a| a.name == "read" || a.name == ::Facet::RBAC::Permission::WILDCARD_ACTION }
        end
      end

      # Returns true when `auth_context` may read the artifact through one
      # specific owner row. Exposed so callers that already loaded the
      # owner rows (`Artifact::Grants.mint_ephemeral` picks the readable
      # owner to bind the grant against) don't re-issue the SQL fetch.
      def self.can_read_owner?(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        owner : ::Facet::Artifact::Store::OwnerRow,
      ) : Bool
        owner_read?(db, auth_context, owner)
      end

      # ── Owner-row evaluation ───────────────────────────────────────────

      # Returns true when the caller can read *one specific* owner row's
      # provenance document. Both gates a) and b) above must pass, after
      # the live-document check disciplines out tombstoned owners (a
      # tombstoned document must not keep bytes alive through this row).
      #
      # Account-scoped owner rows (the standalone-upload provenance — see
      # `ACCOUNT_OWNER_DOC_TYPE` in `Artifact::Routes`) short-circuit both
      # gates: the row is the uploader's own provenance, so the read is
      # granted iff the caller's `account_id` matches the row's `doc_id`.
      # Once the artifact is linked into a real document, that link writes a
      # document-scoped owner row via the re-attach flow, and the regular
      # RBAC gate covers reads through that row.
      private def self.owner_read?(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        owner : ::Facet::Artifact::Store::OwnerRow,
      ) : Bool
        # Account-scoped standalone-upload provenance. The owner row's
        # `doc_id` carries the uploader's account id; the read is owned by
        # that account alone. System bypasses this branch (covered below by
        # the regular system short-circuit) — but system reads of account
        # artifacts also go through the document-owner path when linked, so
        # this branch never needs to grant system.
        if !auth_context.system? && owner.doc_type == ::Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE
          return auth_context.account_id == owner.doc_id
        end

        # The live-document join — required by `doc/backend/artifact.md`.
        # An owner row pointing at a tombstoned document is skipped, never
        # matching — even for system bypass, because the provenance has
        # ceased to be a live document. (System can still read the artifact
        # contents via direct Shrine paths if needed; that path lives
        # outside this access check.)
        return false unless ::Facet::Artifact::Store.document_live?(
                              db, owner.domain, owner.doc_type, owner.doc_id,
                            )

        # Gate a: read permission on the provenance document.
        unless ::Facet::RBAC::ReadEnforcer.authorized?(
                 db, owner.domain, owner.doc_type, owner.doc_id, auth_context,
               )
          return false
        end

        # System bypass is sufficient past the live-document gate — the
        # enforcer above already returned true. The view-tag gate below
        # is RBAC-scope machinery that does not apply to the bypass
        # principal (the system principal's `visible_tags` is undefined).
        return true if auth_context.system?

        # Gate b: visible_tags coverage. Re-evaluates the tags for the
        # snapshot view_tag (the field's tags at upload time) AND the live
        # tags resolved from the current doctype definition.
        visible_tags = visible_tags_for(auth_context)
        return false unless tags_cover?(visible_tags, owner.view_tag)

        # Live tags — resolve the field_path against the doctype definition.
        # A field_path that no longer resolves fails closed (dispatched via
        # `nil` → `tags_cover?` returns false when the live tag set is nil).
        definition = ::Facet::Doctype::DefinitionStore.fetch(
          db, "#{owner.domain}.#{owner.doc_type}",
        )

        # No definition available (doctype deleted but documents remain —
        # can happen transiently during domain operations). Fail closed:
        # the path cannot resolve without a definition.
        return false unless definition

        leaf = ::Facet::Document::ArtifactRefs.resolve_field_path(
          definition, owner.field_path,
        )
        return false unless leaf

        # Attachments (`file` fields) and inline longtext URN links both
        # carry provenance. Any other leaf type fails closed.
        type_name = leaf.type.try(&.type_name)
        return false unless type_name == "file" || type_name == "longtext"

        live_tags = leaf.tags
        tags_cover?(visible_tags, live_tags)
      end

      # Returns the visible_tags set for a non-system principal. The
      # system bypass path returns earlier — this is only reached from
      # within the view-tag gate, where `principal` is `Real`.
      private def self.visible_tags_for(
        auth_context : ::Facet::RBAC::AuthContext,
      ) : Set(String)
        principal = auth_context.principal
        case principal
        when ::Facet::RBAC::Principal::System
          # Unreachable in the view-tag gate (system bypassed above), but
          # the type system needs a return branch. An empty set fails
          # closed for every tag check.
          ::Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS
        when ::Facet::RBAC::Principal::Real
          principal.active_role.visible_tags
        else
          ::Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS
        end
      end

      # Returns true when `visible_tags` covers every tag in `required`.
      # `nil` is treated as `["default"]` (mirroring `FieldDefinition#tags`'s
      # convention; the wildcard `["*"]` matches everything).
      # An empty `required` (a field with no explicit tags) is considered
      # public — every principal can read it.
      private def self.tags_cover?(visible_tags : Set(String), required : Array(String)?) : Bool
        return true if visible_tags.includes?(::Facet::RBAC::ActiveRole::WILDCARD_TAG)
        required = ::Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS if required.nil? || required.empty?
        required.all? { |t| visible_tags.includes?(t) }
      end
    end
  end
end
