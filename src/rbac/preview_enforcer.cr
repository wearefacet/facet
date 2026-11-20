# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"

module Facet
  module RBAC
    # Authorization branch for preview-mode capability principals.
    #
    # A `Principal::Preview` is scoped to one draft domain — the capability
    # was issued at preview-session time after the caller proved (against
    # their real identity) that they may edit the draft's doctype definitions.
    # Authorization here is purely domain-scoped:
    #
    # - **Inside the draft domain** — every CRUD action on documents is allowed.
    #   No named scope or context set resolution. The draft has no
    #   production-tuned scopes and the user is concurrently editing the schema.
    # - **Cross-domain references into live domains** — denied. Preview tests
    #   *your* draft's behaviour; live production data is never surfaced
    #   through a draft's reference fields.
    # - **Doctype / domain schema edits** — denied. Schema authoring goes
    #   through the Builder editor (the user's real role), never through the
    #   preview API.
    # - **`core.DocumentView` / `core.CollectionView` reads** (children of
    #   `core.DocType`) — allowed *only* when the row's parent doctype belongs
    #   to the bound draft domain. The live app reads these rows to render
    #   listing tabs and document templates; without this carve-out, preview
    #   would have no UI. Writes to these definitions stay denied.
    #
    # See `doc/backend/draft-domains.md` → Preview Mode for the contract.
    module PreviewEnforcer
      # Doctypes whose projections live under `domain = 'core'` but belong
      # conceptually to a draft's schema. The live app reads these to render
      # — they are the only cross-domain reads a preview principal may make.
      PRIVATE_SCHEMA_DOCTYPES = Set{"DocumentView", "CollectionView"}

      # Authorizes a document mutation (create / read / update / delete /
      # named action) under a preview principal.
      #
      # `doc_id` is the target document id; it is `nil` for create (the row
      # does not exist yet) — preview authorises create on doctype identity
      # alone, same as the role-based `WriteEnforcer` does.
      #
      # The four standard actions (`read`, `create`, `update`, `delete`) plus
      # named actions all flow through here. The preview model grants them
      # uniformly on in-scope targets — authoring-time gates already ran on the
      # caller's real identity at session issuance.
      def self.authorizes?(
        db : DB::Connection,
        action : String,
        domain : String,
        doc_type : String,
        doc_id : String?,
        auth_context : AuthContext,
      ) : Bool
        preview_domain = auth_context.preview_domain
        # `auth_context.preview?` is the gating call site in the enforcers, so
        # this branch should never see a non-preview context. Fail closed.
        return false if preview_domain.nil?

        # Schema authoring is denied from preview — it goes through the
        # Builder editor on the caller's real role.
        return false if schema_authoring?(domain, doc_type, action)

        # The draft domain's doctype definitions live under `domain = 'core'
        # as `core.DocType` rows whose `content->>'domain' = preview_domain`.
        # The live application reads these to render doctype marks and listing
        # configurations; their children (`core.DocumentView`,
        # `core.CollectionView`) do the same. The carve-out is read-only.
        if domain == "core" && PRIVATE_SCHEMA_DOCTYPES.includes?(doc_type)
          return read_only?(action) && parent_doctype_belongs_to_draft?(db, doc_id, preview_domain)
        end

        # Single-document reads of the bound draft's own schema rows. The list
        # path already narrows these via `list_where_clauses` (an `id = $N`
        # clause for `core.Domain`, a `content->>'domain' = $N` clause for
        # `core.DocType`); the single-doc read path needs the same row-level
        # carve-out, otherwise the live dashboard's fallback fetch of
        # `core.Domain/:id` (e.g. on entering `/_abc` during preview) and any
        # direct `core.DocType/:id` read fall through to the default rule
        # below — `"core" == preview_domain` is always false because the draft
        # id is the row's id, not its `domain` column. Cross-draft reads are
        # rejected by the row-level id / `content->>'domain'` checks, so a
        # preview principal for `_abc` cannot read `_xyz`'s row by guessing.
        # Writes stay denied by the `schema_authoring?` gate above.
        if domain == "core" && read_only?(action) &&
           schema_row_belongs_to_draft?(db, doc_type, doc_id, preview_domain)
          return true
        end

        # The default rule: the target domain must equal the bound draft
        # domain. Cross-domain reads (e.g. a draft's `reference` field
        # targeting `iam.Account`) are denied — preview tests the draft, not
        # live data.
        domain == preview_domain
      end

      # Builds SQL WHERE fragments for a list query under a preview principal.
      #
      # Returns `{clauses, params}` mirroring the role-based enforcer's
      # `list_where_clauses`.
      #
      # - Draft-domain document lists (`domain = preview_domain`): no
      #   restriction — the caller's base `domain = $1 AND doc_type = $2`
      #   already scopes the result.
      # - `core.DocType` lists: scope to the bound draft so `DoctypeRegistry`
      #   (which loads every doctype definition in a single
      #   `GET /Api/core/DocType?items=500`) sees only the draft's rows.
      # - `core.Domain` lists: scope to the bound draft id so the live nav's
      #   `core.Domain` fetch surfaces the bound draft row alone.
      # - `core.DocumentView` / `core.CollectionView` lists: the caller's
      #   `parent_id` filter scopes to one parent doctype; `authorizes?`
      #   gates by parent-belongs-to-draft at the row level.
      # - Anything else outside the bound draft: `1=0` (non-disclosing empty
      #   result, same as a denied role).
      def self.list_where_clauses(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        start_idx : Int32 = 1,
      ) : {Array(String), Array(::DB::Any)}
        preview_domain = auth_context.preview_domain
        return {["1=0"] of String, [] of ::DB::Any} if preview_domain.nil?

        # `core.DocType`: emit a `content->>'domain' = $N` clause so the
        # registry sees only the bound draft's doctypes.
        if domain == "core" && doc_type == "DocType"
          return {["content->>'domain' = $#{start_idx}"] of String, [preview_domain] of ::DB::Any}
        end

        # `core.Domain`: emit an `id = $N` clause so the nav list surfaces
        # only the draft's row.
        if domain == "core" && doc_type == "Domain"
          return {["id = $#{start_idx}"] of String, [preview_domain] of ::DB::Any}
        end

        # `core.DocumentView` / `core.CollectionView`: row-level filter
        # (`parent_id` at the caller's where) + per-row parent-belongs-to-
        # draft check in `authorizes?` is sufficient. Emit no extra clause.
        if domain == "core" && PRIVATE_SCHEMA_DOCTYPES.includes?(doc_type)
          return {[] of String, [] of ::DB::Any}
        end

        # Default rule: the target domain must equal the bound draft domain.
        domain == preview_domain ? {[] of String, [] of ::DB::Any} : {["1=0"] of String, [] of ::DB::Any}
      end

      # ── Private ──────────────────────────────────────────────────────

      # True for actions that mutate doctype or domain definitions. These go
      # through the Builder editor (caller's real role); preview is data-only.
      private def self.schema_authoring?(domain : String, doc_type : String, action : String) : Bool
        return false unless read_only?(action) == false # only writes are gated here
        case {domain, doc_type}
        when {"core", "DocType"}, {"core", "Domain"}
          true
        else
          false
        end
      end

      # True for the four read actions (`read`). Preview is read-write for
      # draft documents but the schema-doctype carve-out is read-only —
      # view-template edits go through the Builder.
      private def self.read_only?(action : String) : Bool
        action == "read"
      end

      # True when the (`domain = 'core'`) schema row identified by
      # `(doc_type, doc_id)` belongs to the bound draft. The list path narrows
      # `core.Domain` / `core.DocType` via `list_where_clauses`; this mirrors
      # that gate at the row level so single-doc reads of the bound draft's
      # own `core.Domain` projection and `core.DocType` definitions authorise
      # during preview. False for any other doctype — the default rule applies.
      # `doc_type == "Domain"` checks the row id against `preview_domain` (the
      # draft id IS the Domain projection's id). `doc_type == "DocType"`
      # checks the row's `content->>'domain'`. Without this gate, the live
      # dashboard's `GET /Api/core/Domain/:id` fall-back write after entering
      # `/_abc` would be denied as a non-disclosing 404 — `"core" == "_abc"`
      # is always false because the draft id is the row's id, not its `domain`
      # column. Cross-draft reads fall through to the default rule too, since
      # the id / `content` checks fail.
      private def self.schema_row_belongs_to_draft?(
        db : DB::Connection,
        doc_type : String,
        doc_id : String?,
        preview_domain : String,
      ) : Bool
        case doc_type
        when "Domain"
          doc_id == preview_domain
        when "DocType"
          doctype_belongs_to_draft?(db, doc_id, preview_domain)
        else
          false
        end
      end

      # Verifies that the `core.DocType` row identified by `doc_id` carries
      # `content->>'domain' = preview_domain`. Mirrors the `list_where_clauses`
      # carve-out for `core.DocType` lists so single-doc reads of the bound
      # draft's doctype definitions authorise during preview. Without this,
      # the live app reading `/Api/core/DocType/_abc.Widget` would be denied
      # on the default rule (`"core" == "_abc"` is false) — a cross-draft leak
      # is closed by the row-level `content` check, not by the URL.
      private def self.doctype_belongs_to_draft?(
        db : DB::Connection,
        doc_id : String?,
        preview_domain : String,
      ) : Bool
        return false if doc_id.nil? || doc_id.empty?

        belongs = db.query_one?(
          <<-SQL,
            SELECT EXISTS (
              SELECT 1
              FROM projections
              WHERE domain = 'core'
                AND doc_type = 'DocType'
                AND id = $1
                AND deleted_at IS NULL
                AND content->>'domain' = $2
            ) AS belongs
          SQL
          doc_id, preview_domain,
          as: Bool,
        )
        !!belongs
      end

      # Verifies that the `core.DocumentView` / `core.CollectionView` row
      # identified by `doc_id` has its `meta.parent_id` set to a
      # `core.DocType` whose `content->>'domain'` equals the bound draft
      # domain. Without this check, a preview principal for draft `_abc` could
      # read the view templates of draft `_xyz` simply by guessing ids — a
      # cross-draft leak the capability model must close.
      private def self.parent_doctype_belongs_to_draft?(
        db : DB::Connection,
        doc_id : String?,
        preview_domain : String,
      ) : Bool
        return false if doc_id.nil? || doc_id.empty?

        belongs = db.query_one?(
          <<-SQL,
            SELECT EXISTS (
              SELECT 1
              FROM projections child
              JOIN projections parent
                ON parent.domain = 'core'
               AND parent.doc_type = 'DocType'
               AND parent.id = child.meta->>'parent_id'
               AND parent.deleted_at IS NULL
              WHERE child.domain = 'core'
                AND child.doc_type IN ('DocumentView', 'CollectionView')
                AND child.id = $1
                AND child.deleted_at IS NULL
                AND parent.content->>'domain' = $2
            ) AS belongs
          SQL
          doc_id, preview_domain,
          as: Bool,
        )
        !!belongs
      end
    end
  end
end
