# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../util/identifier"
require "./scope_context"
require "./scope_predicate"
require "./enforcer_support"

module Facet
  module RBAC
    # Enforces RBAC on read operations (single document and list).
    #
    # Permission scopes reference named scopes declared on the target
    # doctype. At enforcement time, the alias is expanded against the
    # doctype definition into a `field -> ScopeValue` `where` map, then:
    #
    # - For single-doc read: fetch-then-check (we need the content).
    # - For list: compile the expanded `where` into SQL (never fetch-all-then-filter).
    # - Apply field-level read mask on serialization.
    module ReadEnforcer
      # Checks whether the caller may read a single document.
      #
      # Returns `true` if authorized, `false` for non-disclosing not-found.
      # `authorize_path` overrides the doctype path the gate checks — see
      # `WriteEnforcer.authorize_create` for the nested-route contract. The
      # row-level scope evaluation stays leaf-based (`doc_type`).
      #
      # `authorize_root_id` is the `core.DocType` row id a nested route
      # descends from. When the path targets a definition-plane child
      # (`CollectionView` / `DocumentView`), a reader of the described doctype
      # reads the configuration row too — the nested twin of B-86.
      def self.authorized?(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : Bool
        return PreviewEnforcer.authorizes?(db, "read", domain, doc_type, doc_id, auth_context) if auth_context.preview?

        # Definition-plane children of a readable doctype (B-86 on the nested
        # route): the configuration belongs to the doctype, so reading the
        # doctype reads every row of it.
        return true if definition_child_readable?(auth_context, authorize_path, authorize_root_id)

        # Structural metadata (B-86, B-123): the metadata gate is a union
        # with the generic gate, so a scoped read line on the metadata
        # doctype can never remove a row the caller's grants reach. A Denied
        # gate — no read line on the metadata doctype at all — serves the
        # rows the grants reach (flat gate only).
        metadata = authorize_path.nil? && MetadataGate.metadata_doctype?(domain, doc_type)
        if metadata &&
           EnforcerSupport.dispatch_action("read", domain, doc_type, auth_context, authorize_path).denied?
          return MetadataGate.row_readable?(doc_type, doc_id, auth_context)
        end

        result = EnforcerSupport.row_authorized?(db, "read", domain, doc_type, doc_id, auth_context, authorize_path)

        # Monotonic union (B-123): a scoped read line whose row scope fails
        # still serves the row when the metadata gate reaches it.
        return MetadataGate.row_readable?(doc_type, doc_id, auth_context) if metadata && !result

        result
      end

      # Checks whether the caller may read a single document AND that the
      # document exists and is not soft-deleted.
      #
      # Used by the HTTP layer to gate access to nested child routes on the
      # immediate parent before listing or reading its children. Differs from
      # `authorized?` in that this also verifies existence/non-deleted in the
      # same statement, so a not-found and a denied read both surface as a
      # non-disclosing `false` (callers return 404).
      def self.parent_authorized?(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        return true if auth_context.system?
        if auth_context.preview?
          # The preview enforcer gates on draft-domain identity. For nested
          # child routes the parent lives in the draft's namespace — existence
          # and not-deleted are verified in the same statement so a not-found
          # and a denied read both surface as a non-disclosing 404 (matching
          # the role-based path's contract).
          return false unless PreviewEnforcer.authorizes?(db, "read", domain, doc_type, doc_id, auth_context)
          return EnforcerSupport.exists_undeleted?(db, domain, doc_type, doc_id)
        end

        gate = EnforcerSupport.dispatch_action("read", domain, doc_type, auth_context, authorize_path)
        if gate.denied?
          # Structural metadata (B-86): the parent gate on a metadata row
          # passes when the caller's grants reach what the row describes
          # (flat gate only) — existence is still verified below.
          if authorize_path.nil? && MetadataGate.metadata_doctype?(domain, doc_type) &&
             MetadataGate.row_readable?(doc_type, doc_id, auth_context)
            EnforcerSupport.exists_undeleted?(db, domain, doc_type, doc_id)
          else
            false
          end
        elsif gate.allowed?
          EnforcerSupport.exists_undeleted?(db, domain, doc_type, doc_id)
        else
          scope_context, context_results, definition =
            EnforcerSupport.load_scope_inputs(db, domain, doc_type, auth_context)

          base_params = [domain, doc_type, doc_id] of ::DB::Any
          scope_clauses, scope_params =
            EnforcerSupport.build_permission_scope_clauses(gate.permissions, scope_context, context_results, definition, start_idx: base_params.size + 1)

          # Monotonic union (B-123): a scoped read line on the metadata
          # doctype must never remove a row the metadata gate reaches.
          scope_clauses, scope_params = parent_metadata_union(
            domain, doc_type, auth_context, authorize_path,
            scope_clauses, scope_params, base_params.size + scope_params.size + 1,
          )

          # A matching unrestricted permission produces no clause here — treated
          # as "in scope but row content is unrestricted", so the existence
          # check suffices.
          where_sql = if scope_clauses.empty?
                        "domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL"
                      else
                        "domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL AND (#{scope_clauses.join(" OR ")})"
                      end
          params = base_params + scope_params

          exists = db.query_one?(
            "SELECT 1 FROM projections WHERE #{where_sql} LIMIT 1",
            args: params,
            as: Int32
          )
          !exists.nil?
        end
      end

      # Monotonic union (B-123) for the parent gate: OR the metadata clause
      # into the scope group so a scoped read line on a metadata doctype never
      # removes a row the metadata gate reaches (flat gate only). An empty
      # scope group already passes the existence check, so it is left as-is.
      private def self.parent_metadata_union(
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        authorize_path : Array(String)?,
        scope_clauses : Array(String),
        scope_params : Array(::DB::Any),
        start_idx : Int32,
      ) : {Array(String), Array(::DB::Any)}
        if authorize_path.nil? &&
           MetadataGate.metadata_doctype?(domain, doc_type) &&
           !scope_clauses.empty?
          meta_clauses, meta_params = MetadataGate.list_clause(doc_type, auth_context, start_idx)
          # The metadata gate reaches every row — no restriction.
          return {[] of String, [] of ::DB::Any} if meta_clauses.empty?
          return {scope_clauses, scope_params} if meta_clauses == ["1=0"]

          scope_clauses << meta_clauses.first
          return {scope_clauses, scope_params + meta_params}
        end

        {scope_clauses, scope_params}
      end

      # Authorizes a sidecar list attached to a host document.
      #
      # The sidecar grant is the nested `read` permission on the host-scoped
      # path (`read hr.Employee.Comment`). Flat `read` grants on the sidecar
      # doctype (`read core.Comment`) do NOT participate — they serve the
      # flat endpoint only. Scopes are NOT evaluated here:
      # this is only the action-level gate. The row-level filter (sidecar
      # records whose `target` points at a host record the caller can
      # read) is enforced by the handler's `target` filter plus the host
      # read gate that already ran.
      #
      # Returns `true` if the nested grant authorises the list, `false`
      # otherwise. The gate is class-level (no row scope), so a `false`
      # is a resource-class denial: handlers surface it as `403`, the
      # same answer the sidecar write gates give. An unknown segment
      # answers 404 before this gate runs.
      def self.sidecar_authorized?(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        sidecar_domain : String,
        sidecar_doctype : String,
        auth_context : AuthContext,
      ) : Bool
        EnforcerSupport.sidecar_action_authorized?(db, "read", host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_context)
      end

      # Builds SQL WHERE fragments for list queries.
      #
      # Returns a tuple of SQL clause strings and their bound parameters.
      # On `Denied`, returns `["1=0"]`. This method serves the composed
      # fan-out surfaces (`Document::Backrefs`, `Document::Resolve`,
      # `Artifact::Refs`, the audit child feed), where one unreadable
      # doctype must narrow to nothing instead of failing the whole
      # response. The primary list endpoints answer the same gate state
      # with 403 instead (`ReadEnforcer.list_denied?`) — one gate result,
      # one answer per operation class, matching the write side. The
      # structural doctypes (`core.DocType`, `core.Domain`) are the
      # exception: on `Denied` the gate serves the rows the caller's grants
      # reach (`MetadataGate`, flat gate only — see rbac.md → Definition
      # and domain visibility).
      #
      # `start_idx` is the placeholder index for the FIRST bound parameter;
      # this lets callers compose the scope clauses with other WHERE fragments
      # that already occupy earlier placeholder positions (e.g. `domain = $1`,
      # `doc_type = $2`, parent_id filters). Defaults to 1 to preserve the
      # standalone unit-test contract.
      #
      # `authorize_path` overrides the doctype path the Layer-1 ceiling and
      # the permission dispatch check — the composition path on nested child
      # routes, the bare path on flat routes. Scope-alias expansion stays
      # leaf-based (named scopes live on the child doctype).
      #
      # `authorize_root_id` is the `core.DocType` row id a nested route
      # descends from: on a definition-plane child path (`CollectionView` /
      # `DocumentView`) a caller that reads the described doctype sees the
      # whole configuration, so no row restriction applies.
      def self.list_where_clauses(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        start_idx : Int32 = 1,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : {Array(String), Array(::DB::Any)}
        # Definition-plane children of a readable doctype (B-86 on the nested
        # route): the configuration belongs to the doctype, so a reader of the
        # doctype reads all of it — no scope clause narrows the answer. Checked
        # first so it short-circuits ahead of the system/preview branches.
        return {[] of String, [] of ::DB::Any} if definition_child_readable?(auth_context, authorize_path, authorize_root_id)

        # System bypass — no restriction
        return {[] of String, [] of ::DB::Any} if auth_context.system?

        # Preview principal — domain-scoped. Returns no restriction for
        # in-scope lists, an unsatisfiable clause for out-of-scope queries.
        return PreviewEnforcer.list_where_clauses(db, domain, doc_type, auth_context, start_idx: start_idx) if auth_context.preview?

        # Layer-1 app-grant ceiling (a present-but-unresolvable grant
        # denies) and the role dispatch collapse into one `Gate::Denied`,
        # which narrows to `1=0` here — the fan-out surfaces filter
        # silently; the primary endpoints answer 403 via `list_denied?`.
        gate = EnforcerSupport.dispatch_action("read", domain, doc_type, auth_context, authorize_path)

        metadata = authorize_path.nil? && MetadataGate.metadata_doctype?(domain, doc_type)

        if gate.denied?
          # Structural metadata (B-86): a caller with no read line on the
          # metadata doctype still resolves the rows its grants reach.
          return MetadataGate.list_clause(doc_type, auth_context, start_idx) if metadata
          return {["1=0"], [] of ::DB::Any}
        elsif gate.allowed?
          return {[] of String, [] of ::DB::Any}
        else
          scoped_where_clauses(db, domain, doc_type, auth_context, gate, metadata, start_idx)
        end
      end

      # The `Scoped` branch of `list_where_clauses`: OR-ed scope clauses at the
      # caller-requested placeholder offset, OR-ed again with the metadata
      # clause when the doctype is structural (B-123 monotonic union).
      private def self.scoped_where_clauses(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        gate : EnforcerSupport::GateResult,
        metadata : Bool,
        start_idx : Int32,
      ) : {Array(String), Array(::DB::Any)}
        scope_context, context_results, definition =
          EnforcerSupport.load_scope_inputs(db, domain, doc_type, auth_context)

        # Build OR-ed WHERE clauses from scopes at the caller-requested
        # placeholder offset.
        #
        # `Scoped.permissions` cannot include unrestricted permissions by
        # construction (`AuthContext#can?` returns `All` if any matched
        # permission is unrestricted), so an empty `clauses` here means
        # every scope failed to expand (unknown alias or doctype defn
        # missing) — fail closed.
        clauses, params =
          EnforcerSupport.build_permission_scope_clauses(gate.permissions, scope_context, context_results, definition, start_idx: start_idx)

        # Monotonic union (B-123): a scoped read line on the metadata
        # doctype must never remove a row the metadata gate reaches. OR the
        # scope clause with the metadata clause (flat gate only).
        if metadata
          meta_clauses, meta_params =
            MetadataGate.list_clause(doc_type, auth_context, start_idx + params.size)
          # The metadata gate reaches every row — no restriction.
          return {[] of String, [] of ::DB::Any} if meta_clauses.empty?
          unless meta_clauses == ["1=0"]
            scoped_sql = clauses.empty? ? "1=0" : "(#{clauses.join(" OR ")})"
            return {["(#{scoped_sql} OR #{meta_clauses.first})"], params + meta_params}
          end
        end

        return {["1=0"], [] of ::DB::Any} if clauses.empty?

        {["(#{clauses.join(" OR ")})"], params}
      end

      # True when the caller holds no read permission on the doctype at all
      # (role denial or layer-1 app-grant ceiling) on a flat, non-metadata
      # doctype — the class-level denial the primary list endpoints answer
      # with 403, the same gate state the write side denies with 403. The
      # structural metadata doctypes are excluded: their lists stay
      # governed by the metadata gate (B-86) and never answer 403. Pure
      # permission arithmetic — no database access, no row scope.
      #
      # `authorize_root_id` is the `core.DocType` row id a nested route
      # descends from. When the composition path targets a definition-plane
      # child (`CollectionView` / `DocumentView`), reading the described
      # doctype is enough — the same rule B-86 applies on the flat route.
      def self.list_denied?(
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : Bool
        return false if auth_context.system? || auth_context.preview?
        return false if authorize_path.nil? && MetadataGate.metadata_doctype?(domain, doc_type)
        return false if definition_child_readable?(auth_context, authorize_path, authorize_root_id)

        EnforcerSupport.dispatch_action("read", domain, doc_type, auth_context, authorize_path).denied?
      end

      # True when the caller holds no read permission on the doctype at all —
      # the same gate state that makes the list endpoints answer 403
      # (`list_denied?`) and the single-read gate (`Document::Read`) too.
      # Unlike `list_denied?` this keeps the structural-metadata carve-out
      # (B-86): a caller whose grants reach structural rows reads them
      # through the metadata gate. Field aggregates consult
      # this so a no-grant caller gets the empty-set aggregate instead of
      # per-field 403 / 422 distinctions that would enumerate field names
      # and sensitivity tags.
      #
      # Pure permission arithmetic — no database access, no row scope. A
      # scoped grant is NOT a denial here: a scoped caller holds a grant and
      # keeps the documented field-tag ordering. Preview principals gate
      # through `PreviewEnforcer` (and see every field), so they answer
      # `false`.
      def self.read_denied?(
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : Bool
        return false if auth_context.system? || auth_context.preview?

        # The structural doctypes mirror their list gate (B-86): a caller
        # whose grants reach structural rows holds them for aggregates too.
        if authorize_path.nil? && MetadataGate.metadata_doctype?(domain, doc_type) &&
           MetadataGate.collection_reachable?(doc_type, auth_context)
          return false
        end

        # Definition-plane children of a readable doctype — see `list_denied?`.
        return false if definition_child_readable?(auth_context, authorize_path, authorize_root_id)

        EnforcerSupport.dispatch_action("read", domain, doc_type, auth_context, authorize_path).denied?
      end

      # Enumerates the doctypes the full read gate admits — role permission
      # AND the layer-1 app-grant ceiling — across every live (non-draft)
      # domain. A wildcard-domain line widens the
      # enumeration to every live doctype; concrete lines contribute their
      # targets. Scopes are NOT evaluated here — the per-doctype list gate
      # (`list_where_clauses`) narrows rows at query time. Shared by the
      # cross-doctype read surfaces (`Document::Backrefs`, the MCP
      # `search_documents` tool).
      #
      # A preview principal sees only the doctypes of its bound draft domain
      # (the `core.DocType` rows whose `content->>'domain'` equals it) — the
      # same domain-identity rule `Search::Query.readable?` applies. `can?`
      # raises on a preview principal by contract, so this branch must stay
      # ahead of the permission walk (B-99).
      def self.readable_doctypes(db : DB::Connection, auth_context : AuthContext) : Array({String, String})
        rows = db.query_all(
          <<-SQL,
            SELECT id, content->>'domain' AS domain
            FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          as: {String, String?},
        )
        if auth_context.system?
          return rows.compact_map do |(id, domain)|
            parts = id.split('.', 2)
            parts.size == 2 && domain ? {domain, parts[1]} : nil
          end
        end

        # Preview principal — the bound draft's doctypes only. Fail closed to
        # an empty enumeration when the binding is somehow absent.
        if auth_context.preview?
          preview_domain = auth_context.preview_domain
          return [] of {String, String} if preview_domain.nil?
          return rows.compact_map do |(id, domain)|
            parts = id.split('.', 2)
            next nil unless domain && parts.size == 2 && domain == preview_domain
            {domain, parts[1]}
          end
        end

        rows.compact_map do |(id, domain)|
          next nil unless domain
          parts = id.split('.', 2)
          next nil unless parts.size == 2
          # The full gate — the app-grant ceiling included — so a doctype
          # the caller cannot actually read is skipped here instead of
          # failing (or emptying) the per-doctype gate downstream.
          next nil if EnforcerSupport.dispatch_action("read", domain, parts[1], auth_context).denied?
          {domain, parts[1]}
        end
      end

      # Applies the field-level read mask based on the active role's visible_tags.
      # Delegates to the shared recursive walker (`RBAC::FieldVisibility`):
      # invisible fields are omitted at every nesting level, unknown content
      # keys are omitted for Real principals, and System / Preview see the
      # content raw.
      def self.mask_content(
        content : JSON::Any,
        auth_context : AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        FieldVisibility.mask_content(content, auth_context, definition)
      end

      # Field-level visibility for one field under the given auth context.
      # Delegates to the shared walker (`RBAC::FieldVisibility`), which
      # keeps the read-mask bypasses — system and preview principals see
      # every field, as does a role carrying the wildcard tag — and falls
      # back to the `field_def.tags || ["default"]` tag-subset check for
      # Real principals. Shared by the row read mask, the aggregate
      # field-tag guard, and the write guards: an aggregate returns no
      # rows, so the mask alone cannot protect a tagged field.
      def self.field_visible?(
        auth_context : AuthContext,
        field_def : Doctype::FieldDefinition,
      ) : Bool
        FieldVisibility.field_visible?(auth_context, field_def)
      end

      # The definition-child rule shared by the three read gates: a nested
      # route under `core.DocType` whose composition path targets
      # `CollectionView` / `DocumentView` is readable by anyone who can read
      # the doctype the path descends from. `authorize_root_id` carries that
      # doctype's row id — absent on flat routes and on every other path.
      private def self.definition_child_readable?(
        auth_context : AuthContext,
        authorize_path : Array(String)?,
        authorize_root_id : String?,
      ) : Bool
        path = authorize_path
        root_id = authorize_root_id
        return false if path.nil? || root_id.nil?

        MetadataGate.definition_child_readable?(path, root_id, auth_context)
      end
    end
  end
end
