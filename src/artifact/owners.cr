# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "db"
require "../database"
require "../rbac"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../document/artifact_refs"
require "./store"
require "./access"

module Facet
  module Artifact
    # Owner-row append flows.
    #
    # `artifact_owners` rows are append-only (invariant #2, see
    # `doc/backend/artifact.md`). Any flow that puts an existing artifact id
    # into a new document — re-attach, `Document::Copy`, cross-domain field
    # replication — appends an owner row rather than re-uploading or moving
    # one. No bytes are ever copied: artifacts are transversal, so a new
    # owner row is the whole operation.
    #
    # The appended row records provenance for the *target* document and field,
    # with the `view_tag` snapshot taken from the target doctype's current
    # `FieldDefinition#tags` at append time (the same snapshot rule as the
    # upload path).
    module Owners
      # Appends a single `artifact_owners` row. Idempotent — `ON CONFLICT
      # DO NOTHING` collapses a duplicate (same artifact + domain + doc +
      # field_path) into a no-op, which is correct: the provenance already
      # exists.
      #
      # `view_tag` is the snapshot of `FieldDefinition#tags` for the target
      # field at append time. `actioner_id` is the actor driving the append
      # (the copy / replication actor, not necessarily the original uploader).
      def self.append(
        db : DB::Connection,
        artifact_id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        field_path : String,
        view_tag : Array(String)?,
        actioner_id : String,
      ) : Nil
        # Idempotency is handled at the SQL level (`ON CONFLICT DO NOTHING`)
        # rather than by rescuing the UNIQUE violation. Rescuing a PG error
        # inside a transaction aborts the transaction in PostgreSQL — the
        # caller's subsequent COMMIT would silently roll back the whole
        # mutation. The append-only flow must never abort its caller.
        ::Facet::Artifact::Store.insert_owner_row_idempotent(
          db,
          artifact_id: artifact_id,
          domain: domain,
          doc_type: doc_type,
          doc_id: doc_id,
          field_path: field_path,
          view_tag: view_tag,
          created_by: actioner_id,
        )
      end

      # Appends an owner row for every artifact referenced by `content`
      # (walked via `Document::ArtifactRefs.extract_from_content`), against
      # the document `(domain, doc_type, doc_id)`.
      #
      # The `view_tag` snapshot for each field is resolved from the target
      # doctype's *current* definition at the referenced field path — the
      # same normalizer that produces `artifact_owners.field_path`, so array
      # entries get their own owner row with their own snapshot.
      #
      # When `auth_context` is not the system principal, each artifact must
      # be readable by the actor (`Artifact::Access.can_read?`); a
      # non-readable artifact fails loud with `403` rather than silently
      # granting provenance over bytes the actor cannot see. The system
      # principal bypasses the read gate (copy / replication run as system).
      def self.append_for_document(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        content : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
      ) : Facet::ServiceError?
        refs = ::Facet::Document::ArtifactRefs.extract_from_content(content, definition)

        refs.each do |ref|
          unless auth_context.system?
            unless ::Facet::Artifact::Access.can_read?(db, auth_context, ref.artifact_id)
              return Facet::ServiceError.new(403, "Forbidden")
            end
          end

          view_tag = resolve_view_tag(definition, ref.resource_field)
          append(
            db,
            artifact_id: ref.artifact_id,
            domain: domain,
            doc_type: doc_type,
            doc_id: doc_id,
            field_path: ref.resource_field,
            view_tag: view_tag,
            actioner_id: actioner_id,
          )
        end

        nil
      end

      # Appends an owner row for every artifact referenced by `content` that
      # the actor can already read. Unlike `append_for_document`, a
      # non-readable artifact is silently skipped rather than failing loud.
      #
      # This is the **re-attach / share** flow. Two reference shapes append:
      #
      # - A JSON create/update that puts an existing artifact id into a
      #   `file` field.
      # - A JSON create/update that embeds a `urn:facet:artifact:<id>` link
      #   in a longtext field. The link shares the artifact with every
      #   reader of the document — this is the deliberate-share channel, and
      #   the target longtext field's `view` tag is the share ceiling (the
      #   appended row snapshots it; see `Artifact::Access`).
      #
      # Knowing an id must never confer ownership — the actor must already
      # hold read access through some other provenance. An account that merely
      # pastes a link gets no owner row (no self-grant); a user who
      # legitimately read the artifact and embeds it gets proper provenance,
      # so the document stops depending on the original owner's survival for
      # read access.
      #
      # A non-readable artifact is **silently skipped**, never an error: a
      # save must not break because the document links a file the actor
      # cannot read (the link stays a dead capsule for that actor). A
      # fabricated id with no `artifacts` row is likewise skipped (lossless
      # — no bytes to own; the FK would otherwise abort the caller's
      # transaction).
      #
      # Runs inside the caller's transaction. Returns `nil`.
      def self.append_readable_for_document(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        content : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
      ) : Nil
        refs = ::Facet::Document::ArtifactRefs.extract_from_content(content, definition)

        refs.each do |ref|
          # `file` fields carry attachments; longtext URNs are inline links
          # that share the artifact with the document's readers. Both confer
          # ownership. `extract_from_content` yields both; the field-path
          # resolution below tells them apart.
          leaf = ::Facet::Document::ArtifactRefs.resolve_field_path(definition, ref.resource_field)
          next unless leaf

          type_name = leaf.type.try(&.type_name)
          next unless type_name == "file" || type_name == "longtext"

          # A fabricated id that has no `artifacts` row must be skipped, not
          # appended: the `artifact_owners.artifact_id` FK would otherwise
          # abort the caller's transaction. A nonexistent artifact has no
          # bytes to own, so dropping it is lossless (mirrors `reconcile`).
          next unless ::Facet::Artifact::Store.find_artifact(db, ref.artifact_id)

          # The anti-self-grant gate: only append when the actor can already
          # read the artifact through some other provenance. System bypasses
          # (internal flows already gate their own reads).
          next unless auth_context.system? || ::Facet::Artifact::Access.can_read?(db, auth_context, ref.artifact_id)

          append(
            db,
            artifact_id: ref.artifact_id,
            domain: domain,
            doc_type: doc_type,
            doc_id: doc_id,
            field_path: ref.resource_field,
            view_tag: leaf.tags,
            actioner_id: actioner_id,
          )
        end

        nil
      end

      # ── Private ────────────────────────────────────────────────────────

      # Resolves the `view` snapshot for a normalized `field_path` against
      # the doctype definition. A path that no longer resolves yields `nil`
      # (the default tag), matching `Artifact::Access`'s fail-closed rule —
      # but the append still records the row so the provenance is on the
      # books; read-time resolution decides whether it grants access.
      private def self.resolve_view_tag(
        definition : Doctype::DoctypeDefinition,
        field_path : String,
      ) : Array(String)?
        leaf = ::Facet::Document::ArtifactRefs.resolve_field_path(definition, field_path)
        leaf.try(&.tags)
      end
    end
  end
end
