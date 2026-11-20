# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"
require "../rbac"
require "../util/filter_set"

module Facet
  module Index
    # Read-only listing of the `doctype_indexes` table — the data behind
    # `GET /Api/Indexes`, the operator surface that tracks managed index
    # status (pending / active / error / dropped).
    #
    # This is a **read-only** service — it never touches DDL and never
    # spawns fibers. All mutations to the table belong to `Index::Manager`.
    #
    # Authorization mirrors the global audit log (`Audit::List`): the
    # caller must hold wildcard `read` permission (`*.*`). Scoped or `All`
    # both pass; `Denied` answers `403`.
    module List
      # One row of `doctype_indexes`.
      record Row,
        id : String,
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        index_name : String,
        status : String,
        error_message : String?,
        created_at : Time,
        updated_at : Time

      # Service result: one page of rows plus the uncapped total.
      record Result,
        items : Array(Row),
        total : Int64,
        # True only when the count hit the shared cap, so `total` is a
        # floor rather than the exact number of matching rows.
        more : Bool = false

      # Whitelist of columns that may appear in the ORDER BY clause.
      SORTABLE_COLUMNS = Set{"domain", "doc_type", "field_name", "index_type", "status", "created_at", "updated_at"}

      # The filter grammar the list serves (`filters[field__op]=value`):
      # four columns, each with `eq`, `ne`, `match`. `call` validates the
      # filter map against this grammar before it builds any SQL — an
      # unknown field answers 422 naming this list, and a served field
      # with a suffix outside the set answers 422 naming the allowed set
      # (the `Audit::List` B-145 contract). A silent no-op would read as
      # "the whole table matched" on an operator surface. A bare key (no
      # `__`) carries no suffix — it rides the `eq` form.
      FILTERABLE_FIELDS = ["domain", "doc_type", "status", "field_name"]
      FILTER_OPERATORS  = ["eq", "ne", "match"]

      # Calls the list service. See module docs for the authorization rule.
      #
      # Filters use the platform `field__op` grammar; supported fields:
      # `domain`, `doc_type`, `status`, `field_name` (`eq` / `ne` / `match`;
      # `ne` is answered with `IS DISTINCT FROM` so NULLs survive). The
      # filter map is validated before any SQL builds: an unknown field or
      # an unsupported operator answers 422, never a silent unfiltered
      # result (see `validate_filters`). A bare key (no `__`) rides the
      # `eq` form.
      def self.call(
        db : DB::Connection,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        sort : Array(String) = ["-updated_at"],
        page : Int32 = 1,
        items_per_page : Int32 = 100,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
      ) : Result | Facet::ServiceError
        # Authorize: wildcard read only — the operator surface.
        result = auth_context.can?("read", "*.*")
        return error(403, "Forbidden") if result.is_a?(RBAC::CanResult::Denied)

        # Validate the filter map before any SQL builds: a wrong key or an
        # unsupported operator answers 422, never a silent unfiltered
        # result (the `Audit::List` B-145 contract).
        filter_error = validate_filters(filters)
        return filter_error if filter_error

        where_sql, params = build_where(filters)
        order_sql = build_order_sql(sort)
        offset = (page - 1) * items_per_page

        # Capped count: read `COUNT_CAP + 1` rows so the caller learns the
        # real count up to the cap instead of paying for a full scan.
        total = db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM doctype_indexes WHERE #{where_sql} ORDER BY #{order_sql} LIMIT #{HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
            ) AS sub
          SQL


          args: params,
          as: Int64,
        )

        rows = read_page(db, where_sql, order_sql, offset, items_per_page, params)

        # `total` is the real count from `offset`, truncated at the cap;
        # `more` is true only when the cap was hit.
        Result.new(items: rows, total: total, more: total > HTTP::Responders::COUNT_CAP)
      end

      # ── Internals ─────────────────────────────────────────────────────

      private def self.error(status : Int32, message : String) : Facet::ServiceError
        Facet::ServiceError.new(status, message)
      end

      # Validates the filter map against the served grammar. Returns the
      # 422 for the first offending key, or nil when every key is served.
      # The message shapes mirror the audit list's filter contract
      # (`Audit::List.validate_filters`): an unknown field names the
      # filterable set; a served field with an unsupported operator names
      # the allowed set. A known key with a malformed value stays lenient,
      # like the document list's scalar filters.
      private def self.validate_filters(filters : Hash(String, JSON::Any)) : Facet::ServiceError?
        filters.each do |key, _value|
          field, _op = Util::FilterSet.parse_filter_key(key)

          unless FILTERABLE_FIELDS.includes?(field)
            return filter_grammar_error(key, "unknown_filter_field",
              "Unknown filter field '#{field}' (filterable: #{FILTERABLE_FIELDS.join(", ")})")
          end

          next unless key.includes?("__")
          op_suffix = key.split("__", 2)[1]
          unless FILTER_OPERATORS.includes?(op_suffix)
            return filter_grammar_error(key, "unsupported_filter_operator",
              "Filter operator '#{op_suffix}' is not served for field '#{field}' (allowed: #{FILTER_OPERATORS.sort.join(", ")})")
          end
        end

        nil
      end

      # Builds the 422 in the audit list's shape: the message carries the
      # human text; the structured detail carries the filter key and the
      # reason code.
      private def self.filter_grammar_error(key : String, reason : String, message : String) : Facet::ServiceError
        Facet::ServiceError.new(422, message,
          details: [Facet::ValidationError.new(field: key, code: reason, message: message)])
      end

      # Builds the WHERE clause. `validate_filters` has already answered
      # `422` for every key outside the served grammar, so each key here
      # maps to a column clause; a non-string value on a served field
      # stays lenient (no clause), like the audit list's malformed-value
      # contract.
      private def self.build_where(filters : Hash(String, JSON::Any)) : {String, Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        filters.each do |key, value|
          field, op = Util::FilterSet.parse_filter_key(key)
          clause, param = column_filter(field, op, value, params.size)
          if clause && param
            clauses << clause
            params << param
          end
        end

        {clauses.empty? ? "TRUE" : clauses.join(" AND "), params}
      end

      # Builds one filter clause for a `doctype_indexes` column.
      # Returns `{nil, nil}` only for a non-string value on a served
      # field — a known key with a malformed value stays lenient.
      private def self.column_filter(field : String, op : String, value : JSON::Any, param_idx : Int32) : {String?, ::DB::Any?}
        case field
        when "domain", "doc_type", "status", "field_name"
          raw = value.raw
          return {nil, nil} unless raw.is_a?(String)
          clause = case op
                   when "eq"    then "#{field} = $#{param_idx + 1}"
                   when "ne"    then "#{field} IS DISTINCT FROM $#{param_idx + 1}"
                   when "match" then "#{field} ILIKE $#{param_idx + 1}"
                   else              nil
                   end
          param = op == "match" ? "%#{raw}%" : raw
          {clause, param}
        else
          {nil, nil}
        end
      end

      # Fetches one page of rows under the caller's WHERE / ORDER BY shape.
      private def self.read_page(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        offset : Int32,
        limit : Int32,
        params : Array(::DB::Any),
      ) : Array(Row)
        rows = [] of Row
        db.query(
          "SELECT id, domain, doc_type, field_name, index_type, index_name, status, error_message, created_at, updated_at " \
          "FROM doctype_indexes WHERE #{where_sql} ORDER BY #{order_sql} LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}",
          args: params + [limit, offset],
        ) do |rs|
          rs.each do
            rows << Row.new(
              id: rs.read(String),
              domain: rs.read(String),
              doc_type: rs.read(String),
              field_name: rs.read(String),
              index_type: rs.read(String),
              index_name: rs.read(String),
              status: rs.read(String),
              error_message: rs.read(String?),
              created_at: rs.read(Time),
              updated_at: rs.read(Time),
            )
          end
        end
        rows
      end

      # Builds the ORDER BY clause from sort directives. Only whitelisted
      # columns survive; the tiebreak is `id` so same-timestamp rows keep a
      # stable order. Defaults to `updated_at DESC` when nothing matches.
      private def self.build_order_sql(sort : Array(String)) : String
        clauses = sort.compact_map do |field|
          dir = field.starts_with?("-") ? "DESC" : "ASC"
          col = field.starts_with?("-") ? field[1..] : field

          next nil unless SORTABLE_COLUMNS.includes?(col)
          "#{col} #{dir}"
        end

        clauses.empty? ? "updated_at DESC, id DESC" : clauses.join(", ") + ", id DESC"
      end
    end
  end
end
