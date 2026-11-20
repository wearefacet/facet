# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../rbac"
require "../error"
require "./store"

module Facet
  module Artifact
    # Read-only operator listing of the artifact store — the data behind
    # `GET /Api/Artifacts`, `GET /Api/Artifacts/:id/grants` and
    # `GET /Api/Artifacts/:id/references` (see `doc/backend/artifact.md`
    # → Admin surface).
    #
    # Artifacts are transversal: an `artifacts` row belongs to no domain, so
    # this surface spans every domain in the system. Authorization mirrors
    # the managed-index status surface (`Index::List`) and the global audit
    # log: the caller must hold a non-denied permission for the operator
    # action — `read` on `*.*`. Scoped results pass (deny-only-`Denied`):
    # scopes resolve against doctype definitions, and artifacts are not
    # RBAC doctype targets. `Denied` answers `403`.
    #
    # This is a **read-only** service. Revocation is a write and stays in
    # `Grants.revoke` (system, `publish_artifact` on the owner document, or
    # the `revoke *.*` operator action).
    module Admin
      # One row of the artifact listing — content facts, the original
      # uploader, plus the three child-table counts the operator page shows.
      record ArtifactRow,
        id : String,
        filename : String,
        mime_type : String,
        size : Int64,
        signature_sha256 : String,
        deleted_at : Time?,
        created_at : Time,
        uploaded_by : String?,
        owner_count : Int64,
        grant_count : Int64,
        reference_count : Int64

      # One `artifact_grants` row as listed for a single artifact.
      record GrantRow,
        id : String,
        artifact_id : String,
        owner_id : String,
        kind : String,
        expires_at : Time?,
        epoch : Int32,
        created_by : String,
        created_at : Time

      # One `artifact_references` row joined with the referencing
      # document's projection. `doc_type` and `display_name` are `nil`
      # when the projection row is gone (prune races — the reference
      # rows are cleared on delete, so a miss is transient).
      record ReferenceRow,
        domain : String,
        doc_type : String?,
        resource_id : String,
        display_name : String?,
        resource_field : String,
        last_reference_at : Time

      # Service result: one page of rows plus the uncapped total.
      record Result,
        items : Array(ArtifactRow),
        total : Int64

      record GrantsResult,
        items : Array(GrantRow),
        total : Int64

      record ReferencesResult,
        items : Array(ReferenceRow),
        total : Int64

      # Safety valve for the per-artifact sub-listings — a metadata view or
      # a download-gateway click mints an ephemeral grant, so a hot artifact
      # can carry thousands of rows. The endpoint returns the newest rows up
      # to the cap and reports `more` on the meta.
      SUB_LIST_CAP = 500

      # Whitelist of columns that may appear in the ORDER BY clause.
      SORTABLE_COLUMNS = Set{"filename", "mime_type", "size", "created_at", "deleted_at"}

      # ── Artifact listing ─────────────────────────────────────────────

      # Lists the artifact store. See module docs for the authorization rule.
      #
      # Filters use the platform `field__op` grammar; supported fields:
      # `id` (`match`), `filename` (`match`), `mime_type` (`eq` / `match`),
      # `deleted` (`eq` — `"true"` / `"false"`; when absent only live rows
      # list, matching every other artifact reader).
      def self.list(
        db : DB::Connection,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        sort : Array(String) = ["-created_at"],
        page : Int32 = 1,
        items_per_page : Int32 = 100,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
      ) : Result | Facet::ServiceError
        result = auth_context.can?("read", "*.*")
        return error(403, "Forbidden") if result.is_a?(RBAC::CanResult::Denied)

        where_sql, params = build_where(filters)
        order_sql = build_order_sql(sort)
        offset = (page - 1) * items_per_page

        # Capped count from the page offset: the caller learns the real
        # number of matching artifacts up to the shared cap.
        total = db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM artifacts a WHERE #{where_sql} ORDER BY #{order_sql} LIMIT #{HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
            ) AS sub
          SQL


          args: params,
          as: Int64,
        )

        rows = read_page(db, where_sql, order_sql, offset, items_per_page, params)

        Result.new(items: rows, total: total)
      end

      # ── Per-artifact sub-listings ────────────────────────────────────

      # Lists every grant minted against the artifact, newest first, capped
      # at `SUB_LIST_CAP`. 404 when the artifact row does not exist. The
      # grants of a tombstoned artifact still list (they verify as dead —
      # `verify` rejects on `deleted_at` — and the operator page shows the
      # tombstone badge next to them).
      def self.grants(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        artifact_id : String,
      ) : GrantsResult | Facet::ServiceError
        result = auth_context.can?("read", "*.*")
        return error(403, "Forbidden") if result.is_a?(RBAC::CanResult::Denied)
        return error(404, "Artifact not found") unless artifact_exists?(db, artifact_id)

        total = db.query_one(
          "SELECT COUNT(*) FROM artifact_grants WHERE artifact_id = $1",
          artifact_id,
          as: Int64,
        )

        rows = [] of GrantRow
        db.query(
          <<-SQL,
            SELECT id, artifact_id, owner_id, kind, expires_at, epoch, created_by, created_at
            FROM artifact_grants
            WHERE artifact_id = $1
            ORDER BY created_at DESC, id DESC
            LIMIT $2
          SQL
          artifact_id,
          SUB_LIST_CAP,
        ) do |rs|
          rs.each do
            rows << GrantRow.new(
              id: rs.read(String),
              artifact_id: rs.read(String),
              owner_id: rs.read(String),
              kind: rs.read(String),
              expires_at: rs.read(Time?),
              epoch: rs.read(Int32),
              created_by: rs.read(String),
              created_at: rs.read(Time),
            )
          end
        end

        GrantsResult.new(items: rows, total: total)
      end

      # Lists the `artifact_references` rows for the artifact — the
      # "where is this file used" listing — joined with the referencing
      # document's projection for `doc_type` + `display_name`. Newest
      # reference first, capped at `SUB_LIST_CAP`.
      def self.references(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        artifact_id : String,
      ) : ReferencesResult | Facet::ServiceError
        result = auth_context.can?("read", "*.*")
        return error(403, "Forbidden") if result.is_a?(RBAC::CanResult::Denied)
        return error(404, "Artifact not found") unless artifact_exists?(db, artifact_id)

        total = db.query_one(
          "SELECT COUNT(*) FROM artifact_references WHERE artifact_id = $1",
          artifact_id,
          as: Int64,
        )

        rows = [] of ReferenceRow
        db.query(
          <<-SQL,
            SELECT r.domain, p.doc_type, r.resource_id, p.display_name,
                   r.resource_field, r.last_reference_at
            FROM artifact_references r
            LEFT JOIN LATERAL (
              SELECT doc_type, display_name
              FROM projections
              WHERE domain = r.domain AND id = r.resource_id
              ORDER BY updated_at DESC
              LIMIT 1
            ) p ON true
            WHERE r.artifact_id = $1
            ORDER BY r.last_reference_at DESC, r.resource_id DESC
            LIMIT $2
          SQL
          artifact_id,
          SUB_LIST_CAP,
        ) do |rs|
          rs.each do
            rows << ReferenceRow.new(
              domain: rs.read(String),
              doc_type: rs.read(String?),
              resource_id: rs.read(String),
              display_name: rs.read(String?),
              resource_field: rs.read(String),
              last_reference_at: rs.read(Time),
            )
          end
        end

        ReferencesResult.new(items: rows, total: total)
      end

      # ── Internals ────────────────────────────────────────────────────

      private def self.error(status : Int32, message : String) : Facet::ServiceError
        Facet::ServiceError.new(status, message)
      end

      private def self.artifact_exists?(db : DB::Connection, id : String) : Bool
        !db.query_one?("SELECT 1 FROM artifacts WHERE id = $1", id, as: Int32).nil?
      end

      # Builds the WHERE clause. Filter keys that do not map to a supported
      # column contribute nothing — the page shows the unfiltered list
      # rather than failing (same contract as `Index::List`). The default
      # is live-only; an applicable `deleted__eq` clause REPLACES it —
      # ANDing both would contradict every request away.
      private def self.build_where(filters : Hash(String, JSON::Any)) : {String, Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any
        deleted_clause : String? = nil

        filters.each do |key, value|
          field, op = key.split("__", 2)
          clause, param = column_filter(field, op, value, params.size)
          next unless clause
          if field == "deleted"
            deleted_clause = clause
          else
            clauses << clause
            params << param if param
          end
        end

        clauses.unshift(deleted_clause || "deleted_at IS NULL")
        {clauses.join(" AND "), params}
      end

      # Builds one filter clause for an `artifacts` column.
      # Returns `{nil, nil}` when the filter key is not applicable.
      private def self.column_filter(field : String, op : String, value : JSON::Any, param_idx : Int32) : {String?, ::DB::Any?}
        case field
        when "id"        then text_filter("id", op, value, param_idx)
        when "filename"  then text_filter("filename", op, value, param_idx)
        when "mime_type" then text_filter("mime_type", op, value, param_idx)
        when "deleted"   then deleted_filter(op, value)
        else                  {nil, nil}
        end
      end

      # Builds the `eq` / `match` clause for one text column.
      private def self.text_filter(column : String, op : String, value : JSON::Any, param_idx : Int32) : {String?, ::DB::Any?}
        raw = value.raw
        return {nil, nil} unless raw.is_a?(String)
        case op
        when "eq"    then {"#{column} = $#{param_idx + 1}", raw}
        when "match" then {"#{column} ILIKE $#{param_idx + 1}", "%#{raw}%"}
        else              {nil, nil}
        end
      end

      # Builds the `deleted__eq` clause. The clause text is a fixed
      # fragment, never request input — no bound parameter, so the caller
      # skips `params <<` for it.
      private def self.deleted_filter(op : String, value : JSON::Any) : {String?, ::DB::Any?}
        return {nil, nil} unless op == "eq"
        case bool_value(value)
        when true  then {"deleted_at IS NOT NULL", nil}
        when false then {"deleted_at IS NULL", nil}
        else            {nil, nil}
        end
      end

      # Parses the `deleted__eq` flag. Only a JSON `true` or the string
      # "true" selects tombstones (same grammar as `ListRequest`'s flag);
      # `false` / `"false"` is the explicit live-only request, anything
      # else contributes no clause (the default already covers live-only).
      private def self.bool_value(value : JSON::Any) : Bool?
        case raw = value.raw
        when Bool then raw
        when String
          return true if raw == "true"
          return false if raw == "false"
          nil
        else
          nil
        end
      end

      # Fetches one page of rows under the caller's WHERE / ORDER BY shape.
      # Each row aggregates its three child-table counts: owners
      # (`artifact_owners_lookup_idx` leads with artifact_id), references
      # (the `artifact_references` primary key leads with artifact_id) and
      # live grants (permanent rows, or ephemeral rows not yet expired —
      # `artifact_grants_artifact_idx` leads with artifact_id). The uploader
      # is the `created_by` of the earliest owner row — the original upload;
      # later rows are copies, re-attaches and shares. A system upload
      # leaves no owner row, so the column is null. The ULID tiebreak on
      # `id` keeps same-timestamp rows in creation order.
      private def self.read_page(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        offset : Int32,
        limit : Int32,
        params : Array(::DB::Any),
      ) : Array(ArtifactRow)
        rows = [] of ArtifactRow
        db.query(
          <<-SQL,
            SELECT a.id, a.filename, a.mime_type, a.size, a.signature_sha256,
                   a.deleted_at, a.created_at,
                   (SELECT o.created_by FROM artifact_owners o
                    WHERE o.artifact_id = a.id
                    ORDER BY o.created_at ASC, o.id ASC
                    LIMIT 1),
                   (SELECT COUNT(*) FROM artifact_owners o WHERE o.artifact_id = a.id),
                   (SELECT COUNT(*) FROM artifact_grants g
                    WHERE g.artifact_id = a.id
                      AND (g.kind = 'permanent' OR g.expires_at > now())),
                   (SELECT COUNT(*) FROM artifact_references r WHERE r.artifact_id = a.id)
            FROM artifacts a
            WHERE #{where_sql}
            ORDER BY #{order_sql}
            LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}
          SQL


          args: params + [limit, offset],
        ) do |rs|
          rs.each do
            rows << ArtifactRow.new(
              id: rs.read(String),
              filename: rs.read(String),
              mime_type: rs.read(String),
              size: rs.read(Int64),
              signature_sha256: rs.read(String),
              deleted_at: rs.read(Time?),
              created_at: rs.read(Time),
              uploaded_by: rs.read(String?),
              owner_count: rs.read(Int64),
              grant_count: rs.read(Int64),
              reference_count: rs.read(Int64),
            )
          end
        end
        rows
      end

      # Builds the ORDER BY clause from sort directives. Only whitelisted
      # columns survive; the tiebreak is `id` so same-timestamp rows keep a
      # stable order. Defaults to `created_at DESC` when nothing matches.
      private def self.build_order_sql(sort : Array(String)) : String
        clauses = sort.compact_map do |field|
          dir = field.starts_with?("-") ? "DESC" : "ASC"
          col = field.starts_with?("-") ? field[1..] : field

          next nil unless SORTABLE_COLUMNS.includes?(col)
          "a.#{col} #{dir}"
        end

        clauses.empty? ? "a.created_at DESC, a.id DESC" : clauses.join(", ") + ", a.id DESC"
      end
    end
  end
end
