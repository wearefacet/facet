# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../util/filter_set"
require "../util/time_helper"
require "../rbac"
require "../doctype/definition_store"
require "../error"
require "./redact"

module Facet
  module Audit
    # Service for querying the mutations table directly.
    #
    # Unlike document CRUD services which operate on `projections`, this
    # service reads from the append-only `mutations` table. It supports
    # filtering by the fields in `FILTERABLE_FIELDS` — domain, doctype,
    # document ID, action, actioner_id, app, channel, cause kind, cause
    # trace, and the emitted_at range. `call` validates the filter map:
    # an unknown field or an unsupported operator answers 422, never a
    # silent unfiltered result.
    #
    # This is a **read-only** view — no mutations are created here.
    module List
      # A single row from the `mutations` table, with the provenance and
      # cause read from the typed columns. `app` carries the `app.App`
      # projection id when the mutation was made through an app token or an
      # app-owned API key; `nil` otherwise. `channel` is the authentication
      # surface (`session | oauth_app | app_api_key | api_key | mcp |
      # internal`). The `cause_*` fields describe the direct trigger — one
      # hop per row; `cause_parent` links to the causing mutation and
      # `cause_trace` groups the whole causal cluster. `display_name` is the
      # target document's label, read from the projection row — populated in
      # aggregate mode only (plain mode leaves it nil; tombstones keep their
      # label because the prune never clears it).
      record MutationRecord,
        domain : String,
        doc_type : String,
        id : String,
        doc_id : String,
        idx : Int32,
        action : String,
        actioner_id : String,
        arguments : JSON::Any,
        channel : String,
        app : String?,
        api_key : String?,
        acting_role : String?,
        cause_kind : String,
        cause_name : String?,
        cause_event : String?,
        cause_source : String?,
        cause_parent : String?,
        cause_trace : String,
        emitted_at : Time,
        display_name : String?,
        # Out-of-band redaction metadata: the content paths whose values
        # were removed from `arguments` for this caller (each path is the
        # same array-of-segments form the diff paths use). Empty when the
        # row is unredacted. Never markers inside the content.
        redacted : Array(Array(String)) = [] of Array(String) do
        # Returns a copy with the redacted arguments and paths — the raw
        # row is never mutated in place.
        def with_arguments(arguments : JSON::Any, redacted : Array(Array(String))) : self
          self.class.new(
            domain, doc_type, id, doc_id, idx, action, actioner_id,
            arguments, channel, app, api_key, acting_role,
            cause_kind, cause_name, cause_event, cause_source,
            cause_parent, cause_trace, emitted_at, display_name, redacted,
          )
        end
      end

      record Result,
        items : Array(MutationRecord),
        total : Int64,
        # True only when the count hit the shared cap, so `total` is a
        # floor rather than the exact number of matching rows.
        more : Bool = false

      # The WHERE / ORDER BY / FROM shape of one list call, shared by the
      # count query and the page read. `aggregate` selects the joined,
      # label-reading row query.
      private record QueryShape,
        where : String,
        order : String,
        from : String,
        params : Array(::DB::Any),
        aggregate : Bool

      # The filter vocabulary the column builder serves, with the operator
      # suffix each field accepts. This is the documented grammar of
      # `doc/backend/audit.md` → Filterable fields: the doc pins (`domain`,
      # `doc_type`, `doc_id`) accept `eq` only, the six attribution fields
      # accept `eq` / `ne`, and `emitted_at` accepts `gte` / `lte`. `call`
      # validates the filter map against this grammar before it builds any
      # SQL: an unknown field answers 422 naming this list, and a served
      # field with a suffix outside its set answers 422 naming the allowed
      # set (B-145 — the document list's B-20 contract). A silent no-op
      # would read as "the whole log matched" on a forensics surface.
      FILTERABLE_FIELDS    = ["domain", "doc_type", "doc_id", "action", "actioner_id", "app", "channel", "kind", "trace", "emitted_at"]
      PIN_OPERATORS        = ["eq"]
      EQUALITY_OPERATORS   = ["eq", "ne"]
      EMITTED_AT_OPERATORS = ["gte", "lte"]

      # Lists mutations from the global audit log.
      #
      # All filter parameters are optional — when nil, no filtering is
      # applied for that dimension.
      #
      # Requires an `auth_context` for RBAC authorization.
      # - Global audit (`doc_id` absent): requires system bypass or wildcard
      #   `*.*` `read` permission. `domain` / `doc_type` narrow as filters.
      #   An app-scoped identity (an `app_grant` attached) is denied before
      #   the role check: a grant always names one concrete domain, so it
      #   can never cover the cross-domain view. Denied → 403.
      # - Document-history (`doc_id` present with `domain` / `doc_type`):
      #   enforces `ReadEnforcer.authorized?`. Denied → 404 (non-disclosing).
      #
      # `include_children` switches on the aggregate history: the parent's
      # timeline merges the readable child rows of every doctype named in
      # the parent definition's `children` map (D3). The parent gate stays
      # as-is; each child doctype is additionally filtered by its own
      # `list_where_clauses` scope (the two-rule model), so the feed never
      # shows a child row the nested child list would not show. Only takes
      # effect when all three doc pins are present — anything else falls
      # back to the plain parent-only query.
      #
      # The filter map is validated before any SQL builds: an unknown
      # field or an unsupported operator answers 422 (see
      # `validate_filters`).
      def self.call(
        db : DB::Connection,
        domain : String? = nil,
        doc_type : String? = nil,
        doc_id : String? = nil,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        sort : Array(String) = ["-emitted_at"],
        page : Int32 = 1,
        items_per_page : Int32 = 100,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        include_children : Bool = false,
      ) : Result | Facet::ServiceError
        # 0. Authorize the audit read
        auth_error = authorize(auth_context, db, domain, doc_type, doc_id)
        return auth_error if auth_error

        # Validate the filter map before any SQL builds: a wrong key or an
        # unsupported operator answers 422, never a silent unfiltered
        # result (B-145).
        filter_error = validate_filters(filters)
        return filter_error if filter_error

        offset = (page - 1) * items_per_page
        limit = items_per_page

        q = if include_children && domain && doc_type && doc_id
              build_aggregate_query(db, domain, doc_type, doc_id, filters, auth_context, sort)
            else
              build_plain_query(domain, doc_type, doc_id, filters, sort)
            end

        # Count matching mutations, capped: read `COUNT_CAP + 1` rows so the
        # caller learns the real count up to the cap instead of paying for a
        # full scan. The aggregate WHERE carries the parent branch and every
        # child branch, so parent and child rows each count exactly once (C3).
        total = db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM #{q.from} WHERE #{q.where} ORDER BY #{q.order} LIMIT #{HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
            ) AS sub
          SQL


          args: q.params,
          as: Int64
        )

        items = read_page(db, q.where, q.order, offset, limit, q.params, q.aggregate)

        # 1. Redact the arguments for the caller: invisible field values
        #    leave the arguments, their content paths land in `redacted`.
        #    Definitions cache per (domain, doc_type) within the page.
        items = Redact.apply(items, auth_context, db)

        # `total` is the real count from `offset`, truncated at the cap;
        # `more` is true only when the cap was hit.
        Result.new(items: items, total: total, more: total > HTTP::Responders::COUNT_CAP)
      end

      # ── Filter validation ───────────────────────────────────────────

      # Validates the filter map against the served grammar. Returns the
      # 422 for the first offending key, or nil when every key is served.
      # The message shapes mirror the document list's filter contract
      # (`Document::FilterCompiler.validate_filters!`): an unknown field
      # names the filterable set; a served field with an unsupported
      # operator names the allowed set. A bare key (no `__`) carries no
      # suffix — it rides the eq form. A known key with a malformed value
      # stays lenient, like the document list's scalar filters.
      private def self.validate_filters(filters : Hash(String, JSON::Any)) : Facet::ServiceError?
        filters.each do |key, _value|
          field, _op = Util::FilterSet.parse_filter_key(key)

          unless FILTERABLE_FIELDS.includes?(field)
            return filter_grammar_error(key, "unknown_filter_field",
              "Unknown filter field '#{field}' (filterable: #{FILTERABLE_FIELDS.join(", ")})")
          end

          next unless key.includes?("__")
          op_suffix = key.split("__", 2)[1]
          allowed = case field
                    when "emitted_at"                   then EMITTED_AT_OPERATORS
                    when "domain", "doc_type", "doc_id" then PIN_OPERATORS
                    else                                     EQUALITY_OPERATORS
                    end
          unless allowed.includes?(op_suffix)
            return filter_grammar_error(key, "unsupported_filter_operator",
              "Filter operator '#{op_suffix}' is not served for field '#{field}' (allowed: #{allowed.sort.join(", ")})")
          end
        end

        nil
      end

      # Builds the 422 in the document list's shape: the message carries
      # the human text; the structured detail carries the filter key and
      # the reason code.
      private def self.filter_grammar_error(key : String, reason : String, message : String) : Facet::ServiceError
        Facet::ServiceError.new(422, message,
          details: [Facet::ValidationError.new(field: key, code: reason, message: message)])
      end

      # ── Query shape ─────────────────────────────────────────────────

      # Builds the WHERE / ORDER BY / FROM of one list call.
      #
      # Plain mode (no aggregate): the pinned doc filters plus the column
      # filters, unqualified, against the bare `mutations` table — the exact
      # shape the list always served.
      #
      # Aggregate mode (`include_children` with all three doc pins): the
      # mutations table is aliased to `m` and every clause carries the `m.`
      # qualifier (the row query LEFT JOINs `projections` for labels, so
      # unqualified `domain` / `doc_type` / `id` would be ambiguous). The
      # WHERE becomes the parent branch OR one branch per readable child
      # doctype; the merge order is `emitted_at` plus the mutation-id
      # tiebreak (D9). Returns `{where, order, from, params, aggregate}`.
      private def self.build_plain_query(
        domain : String?,
        doc_type : String?,
        doc_id : String?,
        filters : Hash(String, JSON::Any),
        sort : Array(String),
      ) : QueryShape
        pin_clauses, params, param_idx = build_pin_clauses(domain, doc_type, doc_id, "")

        # Column filters (action, actioner_id, emitted_at range, …). They
        # are direct columns on `mutations`, not JSONB fields inside a
        # `content` column, so they are built manually rather than through
        # FilterSet (which assumes content->>'field').
        filter_clauses, params, _idx = build_filter_clauses(filters, params, param_idx, "")

        QueryShape.new(
          where: build_where_sql(pin_clauses + filter_clauses),
          order: build_order_sql(sort),
          from: "mutations",
          params: params,
          aggregate: false,
        )
      end

      private def self.build_aggregate_query(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        filters : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
        sort : Array(String),
      ) : QueryShape
        pin_clauses, params, param_idx = build_pin_clauses(domain, doc_type, doc_id, "m.")
        filter_clauses, params, param_idx = build_filter_clauses(filters, params, param_idx, "m.")

        child_branches, params = build_child_branches(
          db, domain, doc_type, doc_id, auth_context, filter_clauses, params, param_idx,
        )
        parent_branch = "(#{(pin_clauses + filter_clauses).join(" AND ")})"
        where_sql = ([parent_branch] + child_branches).join(" OR ")

        QueryShape.new(
          where: where_sql,
          order: aggregate_order_sql(sort),
          from: "mutations m",
          params: params,
          aggregate: true,
        )
      end

      # Builds the pinned doc-identity clauses (domain / doc_type / doc_id)
      # with their bound parameters. Returns `{clauses, params, next_idx}`.
      private def self.build_pin_clauses(
        domain : String?,
        doc_type : String?,
        doc_id : String?,
        qual : String,
      ) : {Array(String), Array(::DB::Any), Int32}
        clauses = [] of String
        params = [] of ::DB::Any
        idx = 0

        if d = domain
          idx += 1
          clauses << "#{qual}domain = $#{idx}"
          params << d
        end

        if dt = doc_type
          idx += 1
          clauses << "#{qual}doc_type = $#{idx}"
          params << dt
        end

        if di = doc_id
          idx += 1
          clauses << "#{qual}doc_id = $#{idx}"
          params << di
        end

        {clauses, params, idx}
      end

      # Builds the column-filter clauses. Returns `{clauses, params, next_idx}`.
      private def self.build_filter_clauses(
        filters : Hash(String, JSON::Any),
        params : Array(::DB::Any),
        param_idx : Int32,
        qual : String,
      ) : {Array(String), Array(::DB::Any), Int32}
        clauses = [] of String
        idx = param_idx

        filters.each do |key, value|
          build_column_filter(key, value, idx, qual).each do |clause, param|
            clauses << clause
            params << param
            idx += 1
          end
        end

        {clauses, params, idx}
      end

      # ── Aggregate branches ──────────────────────────────────────────

      # Builds the per-child-doctype OR branches of the aggregate WHERE.
      #
      # One branch per child doctype named in the parent definition's
      # `children` map (D3 — `member_of` is not required). Readable child
      # ids are pre-resolved with the child doctype's own scope clauses, so
      # a branch exists only when the caller can read at least one child of
      # that doctype; a denied or empty resolution contributes no branch
      # (rows absent, never a 403).
      #
      # Branch shape (the shared filter placeholders are re-referenced, not
      # re-bound):
      #   (m.domain = $1 AND m.doc_type = $a AND m.parent_doc_id = $b
      #    AND m.doc_id IN ($c, ...) AND <filter clauses>)
      #
      # Returns `{branches, params}` — params is the caller's array with
      # the branch parameters appended in placeholder order.
      private def self.build_child_branches(
        db : DB::Connection,
        domain : String,
        parent_doc_type : String,
        parent_doc_id : String,
        auth_context : RBAC::AuthContext,
        filter_clauses : Array(String),
        params : Array(::DB::Any),
        param_idx : Int32,
      ) : {Array(String), Array(::DB::Any)}
        branches = [] of String
        idx = param_idx

        aggregate_child_doctypes(db, domain, parent_doc_type).each do |child_doc_type|
          child_ids = readable_child_ids(db, domain, child_doc_type, parent_doc_id, auth_context)
          next if child_ids.empty?

          # The aggregate branch pins all three doc ids, so the domain
          # placeholder is $1 (first clause build order).
          idx += 1
          doc_type_ph = "$#{idx}"
          params << child_doc_type
          idx += 1
          parent_ph = "$#{idx}"
          params << parent_doc_id

          id_placeholders = child_ids.map do |child_id|
            idx += 1
            params << child_id
            "$#{idx}"
          end

          branch = String.build do |sql|
            sql << "(m.domain = $1 AND m.doc_type = #{doc_type_ph}"
            sql << " AND m.parent_doc_id = #{parent_ph}"
            sql << " AND m.doc_id IN (#{id_placeholders.join(", ")})"
            unless filter_clauses.empty?
              sql << " AND #{filter_clauses.join(" AND ")}"
            end
            sql << ")"
          end
          branches << branch
        end

        {branches, params}
      end

      # The child doctype set of the aggregate feed: every entry in the
      # parent definition's `children` map, deduplicated (two relationship
      # names may target one doctype). A missing child definition needs no
      # special case — its pre-resolution resolves no ids, so no branch
      # forms.
      private def self.aggregate_child_doctypes(
        db : DB::Connection,
        domain : String,
        parent_doc_type : String,
      ) : Array(String)
        defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{parent_doc_type}")
        return [] of String unless defn

        doctypes = [] of String
        defn.children.each_value do |child|
          doctypes << child.doctype unless doctypes.includes?(child.doctype)
        end
        doctypes
      end

      # Pre-resolves the readable child ids of one child doctype under one
      # parent. The scope clauses come from the child doctype's own
      # `list_where_clauses` — the same clauses the nested child list
      # applies — composed behind the pinned domain / doc_type / parent_id
      # params (start_idx 4). They compile against `projections` unqualified
      # (this query has no join), and a denied check arrives as `1=0`, which
      # resolves no ids.
      #
      # No tombstone filter on purpose: a delete tombstone keeps its
      # payload until the retention prune clears it, so the feed keeps
      # showing the child's mutation rows; after the prune the scope can no
      # longer match (fail-closed), while an unrestricted grant still
      # resolves the id from `meta` alone.
      private def self.readable_child_ids(
        db : DB::Connection,
        domain : String,
        child_doc_type : String,
        parent_doc_id : String,
        auth_context : RBAC::AuthContext,
      ) : Array(String)
        scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
          db, domain, child_doc_type, auth_context, start_idx: 4)

        where = "domain = $1 AND doc_type = $2 AND meta->>'parent_id' = $3"
        scope_clauses.each do |clause|
          where += " AND (#{clause})"
        end

        params = [domain, child_doc_type, parent_doc_id] of ::DB::Any
        params.concat(scope_params)

        db.query_all(
          "SELECT id FROM projections WHERE #{where}",
          args: params,
          as: String,
        )
      end

      # The aggregate merge order (D9): the caller's `emitted_at` direction
      # (DESC unless explicitly ASC), then the mutation-id tiebreak for rows
      # that share a millisecond. `idx` is per-document and must not join
      # the merge sort.
      private def self.aggregate_order_sql(sort : Array(String)) : String
        dir = sort.includes?("emitted_at") ? "ASC" : "DESC"
        "m.emitted_at #{dir}, m.id DESC"
      end

      # ── Page read ───────────────────────────────────────────────────

      # Fetches one page of mutation rows. The provenance and cause fields
      # are typed columns, so the audit log surfaces which app, auth
      # channel, and trigger produced each mutation with no JSONB extraction.
      #
      # Aggregate mode LEFT JOINs the target projection row (PK lookup) to
      # label every row — parent and child alike — with its document's
      # `display_name` (D6). Plain mode keeps the bare `mutations` query and
      # leaves the label nil.
      private def self.read_page(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        offset : Int32,
        limit : Int32,
        params : Array(::DB::Any),
        aggregate : Bool,
      ) : Array(MutationRecord)
        select_sql = if aggregate
                       <<-SQL
                         SELECT m.domain, m.doc_type, m.id, m.doc_id, m.idx, m.action, m.actioner_id,
                                m.arguments, m.channel, m.app, m.api_key, m.acting_role,
                                m.cause_kind, m.cause_name, m.cause_event, m.cause_source,
                                m.cause_parent, m.cause_trace, m.emitted_at, p.display_name
                         FROM mutations m
                         LEFT JOIN projections p
                           ON p.domain = m.domain AND p.doc_type = m.doc_type AND p.id = m.doc_id
                         WHERE #{where_sql}
                         ORDER BY #{order_sql}
                         LIMIT #{limit} OFFSET #{offset}
                       SQL
                     else
                       <<-SQL
                         SELECT domain, doc_type, id, doc_id, idx, action, actioner_id,
                                arguments, channel, app, api_key, acting_role,
                                cause_kind, cause_name, cause_event, cause_source,
                                cause_parent, cause_trace, emitted_at
                         FROM mutations
                         WHERE #{where_sql}
                         ORDER BY #{order_sql}
                         LIMIT #{limit} OFFSET #{offset}
                       SQL
                     end

        items = [] of MutationRecord
        rs = db.query(select_sql, args: params)
        rs.each do
          items << MutationRecord.new(
            domain: rs.read(String),
            doc_type: rs.read(String),
            id: rs.read(String),
            doc_id: rs.read(String),
            idx: rs.read(Int32),
            action: rs.read(String),
            actioner_id: rs.read(String),
            arguments: rs.read(JSON::Any),
            channel: rs.read(String),
            app: rs.read(String?),
            api_key: rs.read(String?),
            acting_role: rs.read(String?),
            cause_kind: rs.read(String),
            cause_name: rs.read(String?),
            cause_event: rs.read(String?),
            cause_source: rs.read(String?),
            cause_parent: rs.read(String?),
            cause_trace: rs.read(String),
            emitted_at: rs.read(Time),
            display_name: aggregate ? rs.read(String?) : nil,
          )
        end
        rs.close
        items
      end

      # Maps an audit filter field name to its SQL left-hand expression.
      # `action`, `actioner_id`, `domain`, `doc_type`, `doc_id`, `app`,
      # `channel`, `cause_kind`, and `cause_trace` are all columns on
      # `mutations`.
      private def self.field_for_filter(field : String) : String
        case field
        when "kind"  then "cause_kind"
        when "trace" then "cause_trace"
        else              field
        end
      end

      # Builds the WHERE clause fragments for one direct mutation column
      # filter. `qual` prefixes the column (`m.` in aggregate mode, where the
      # row query joins `projections` and bare names would be ambiguous).
      # `validate_filters` has already rejected every field and operator
      # this builder does not serve, so each group below compiles only its
      # documented grammar; an out-of-grammar operator still answers no
      # clause (defense in depth for a direct call).
      # Returns the clause/parameter pairs the filter compiles to — empty
      # when the filter is not applicable.
      private def self.build_column_filter(key : String, value : JSON::Any, param_idx : Int32, qual : String = "") : Array({String, ::DB::Any})
        field, op = Util::FilterSet.parse_filter_key(key)

        case field
        when "doc_type"
          build_doc_type_filter(op, value, param_idx, qual)
        when "domain", "doc_id"
          build_string_column_filter(field, op, value, param_idx, qual, allow_ne: false)
        when "action", "actioner_id", "app", "channel", "kind", "trace"
          build_string_column_filter(field, op, value, param_idx, qual, allow_ne: true)
        when "emitted_at"
          build_emitted_at_filter(op, value, param_idx, qual)
        else
          [] of {String, ::DB::Any}
        end
      end

      # Builds the equality (and, where served, inequality) clause for one
      # direct string column. The doc pins (`domain`, `doc_id`) serve `eq`
      # only; the attribution columns also serve `ne` (IS DISTINCT FROM — a
      # NULL column never matches either way, and `app__ne` keeps the
      # unattributed rows).
      private def self.build_string_column_filter(
        field : String,
        op : String,
        value : JSON::Any,
        param_idx : Int32,
        qual : String,
        allow_ne : Bool,
      ) : Array({String, ::DB::Any})
        raw = value.raw
        return [] of {String, ::DB::Any} unless raw.is_a?(String)
        return [] of {String, ::DB::Any} unless op == "eq" || (op == "ne" && allow_ne)

        column = "#{qual}#{field_for_filter(field)}"
        clause = op == "eq" ? "#{column} = $#{param_idx + 1}" : "#{column} IS DISTINCT FROM $#{param_idx + 1}"
        [{clause, raw}] of {String, ::DB::Any}
      end

      # Builds the doctype clause. The stored column is bare, so a qualified
      # value (`crm.Invoice` — the form the audit page's picker serves)
      # filters domain and doctype in one conjunct: two clauses, two params.
      # Doctype and domain names never contain a dot, so the first dot splits
      # the qualified form unambiguously. A bare value keeps matching the
      # column alone, across every domain. Serves `eq` only (a pin field).
      private def self.build_doc_type_filter(
        op : String,
        value : JSON::Any,
        param_idx : Int32,
        qual : String,
      ) : Array({String, ::DB::Any})
        raw = value.raw
        return [] of {String, ::DB::Any} unless raw.is_a?(String)
        return [] of {String, ::DB::Any} unless op == "eq"

        dot = raw.index('.')
        unless dot
          return [{"#{qual}doc_type = $#{param_idx + 1}", raw}] of {String, ::DB::Any}
        end

        [
          {"#{qual}domain = $#{param_idx + 1}", raw[0...dot]},
          {"#{qual}doc_type = $#{param_idx + 2}", raw[(dot + 1)..]},
        ] of {String, ::DB::Any}
      end

      # Builds the emitted_at range clause. The ISO-8601 input normalizes
      # to UTC RFC-3339 before binding so a caller-supplied timezone
      # offset is honored — the column is tz-naive and stores UTC, so a
      # bare `text::timestamp` cast would silently drop the offset. An
      # unparseable value answers no clause (the value contract stays
      # lenient, like the document list's scalar filters).
      private def self.build_emitted_at_filter(
        op : String,
        value : JSON::Any,
        param_idx : Int32,
        qual : String,
      ) : Array({String, ::DB::Any})
        raw = value.raw
        return [] of {String, ::DB::Any} unless raw.is_a?(String)
        normalized = Util::TimeHelper.to_utc_rfc3339(raw)
        return [] of {String, ::DB::Any} unless normalized
        clause = case op
                 when "gte" then "#{qual}emitted_at >= $#{param_idx + 1}"
                 when "lte" then "#{qual}emitted_at <= $#{param_idx + 1}"
                 else            nil
                 end
        return [] of {String, ::DB::Any} unless clause
        [{clause, normalized}] of {String, ::DB::Any}
      end

      # ── Authorization ───────────────────────────────────────────────

      # Authorizes the audit list call based on scope.
      # Returns `Error` (403/404) or `nil` (allowed).
      #
      # `doc_id` present → document mode: enforce read permission on the
      # target — 403 when the caller holds no read grant on the doctype at
      # all, the non-disclosing 404 when a grant holder cannot see the
      # target. `doc_id` absent → global
      # mode: requires wildcard `*.*` `read`; `domain` / `doc_type` act as
      # filters, never as gates — a caller that holds the wildcard read
      # may ask "what changed in domain X" in one call. An app-scoped
      # identity is denied the global mode before the role check (the
      # Layer-1 ceiling): a grant always names one concrete domain, so it
      # can never cover the cross-domain view, and a domain filter would
      # still return rows of doctypes the grant does not name.
      private def self.authorize(
        auth_context : RBAC::AuthContext,
        db : DB::Connection,
        domain : String?,
        doc_type : String?,
        doc_id : String?,
      ) : Facet::ServiceError?
        return nil if auth_context.system?

        if doc_id
          # Document-history scope — enforce read permission on the target.
          # A nil domain or doc_type beside a doc_id is a degenerate call
          # (the tool layer requires all three); fail closed as 404.
          unless domain && doc_type
            return Facet::ServiceError.new(404, "Document #{doc_id} not found")
          end
          # No read grant on the doctype at all — the class-level denial
          # the write side answers with 403.
          if RBAC::ReadEnforcer.read_denied?(domain, doc_type, auth_context)
            return Facet::ServiceError.new(403, "Forbidden")
          end
          unless RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)
            return Facet::ServiceError.new(404, "Document #{doc_id} not found")
          end
        else
          # Global audit log (with optional domain/doc_type filters) —
          # requires wildcard read permission.
          #
          # Layer-1 app-grant ceiling, before the role check: an
          # app-scoped identity is denied the global mode outright. A
          # grant always names one concrete domain (the `*.*` target is
          # rejected at parse), so no grant can cover the cross-domain
          # view, and a domain filter would still return rows of
          # doctypes the grant does not name. The document-history
          # branch above enforces the grant at concrete coordinates
          # through the ReadEnforcer.
          unless auth_context.app_grant.nil?
            return Facet::ServiceError.new(403, "Forbidden")
          end
          result = auth_context.can?("read", "*.*")
          if result.is_a?(RBAC::CanResult::Denied)
            return Facet::ServiceError.new(403, "Forbidden")
          end
          # Both `All` and `Scoped` pass: any wildcard-read access grants
          # the privileged global audit view. App-scoped callers never
          # reach here — the ceiling denied them above.
        end

        nil
      end

      # Builds the WHERE clause from a list of conditions.
      private def self.build_where_sql(clauses : Array(String)) : String
        clauses.empty? ? "TRUE" : clauses.join(" AND ")
      end

      # Builds the ORDER BY clause from sort directives.
      private def self.build_order_sql(sort : Array(String)) : String
        clauses = sort.compact_map do |field|
          dir = field.starts_with?("-") ? "DESC" : "ASC"
          col = field.starts_with?("-") ? field[1..] : field

          case col
          when "emitted_at" then "emitted_at #{dir}"
          when "idx"        then "idx #{dir}"
          when "id"         then "id #{dir}"
          else                   nil
          end
        end

        clauses.empty? ? "emitted_at DESC" : clauses.join(", ")
      end
    end
  end
end
