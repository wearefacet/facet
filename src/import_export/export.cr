# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "csv"
require "json"
require "opentelemetry"
require "../database"
require "../error"
require "../validation_error"
require "../rbac"
require "../doctype/definition_store"
require "../document/filter_compiler"
require "../document/list"
require "./csv_serializer"

module Facet
  module Document
    # Export service for the document import/export concern: rows in, file out.
    #
    # Streams the live documents of one doctype into a CSV or JSON temp file.
    # A pure read — plain SELECTs over `projections` inside one
    # `REPEATABLE READ, READ ONLY` transaction, so the file is one
    # point-in-time snapshot and memory stays flat at any row count. The run
    # emits zero document events, touches `mutations` not at all, and skips
    # lazy migration: export reads storage as-is (the stale-schema rule), so
    # a "download" is never a writer.
    #
    # Scope SQL from `RBAC::ReadEnforcer.list_where_clauses` AND the user
    # filter grammar from `Document::FilterCompiler` compose into the WHERE
    # clause — export never widens the caller's list view. `mask_content`
    # drops masked fields per row before any cell or JSON value is written.
    #
    # The service layer knows nothing about jobs or routes. The result is a
    # temp file path — the caller reads the bytes from `path`, then deletes
    # the file with `File.delete?(path)`.
    module Export
      # Accepted output formats.
      FORMATS = Set{"csv", "json"}

      # Rows read per keyset query. The transaction stays open across
      # batches, so keep the value generous but bounded.
      BATCH_SIZE = 500

      # The export snapshot contract, passed to `Database.with_transaction`:
      # one read transaction, one point-in-time snapshot, no writes possible
      # at the database level.
      TRANSACTION_ISOLATION = "ISOLATION LEVEL REPEATABLE READ, READ ONLY"

      # Outcome of one export run. The caller owns the temp file.
      record Result,
        path : String,
        format : String,
        row_count : Int64

      # One scanned projection row. `meta` carries `schema_version` and the
      # timestamps feed the JSON `meta` object; the CSV writer ignores all
      # three, but both formats read the same columns.
      private record Row,
        id : String,
        content : JSON::Any,
        meta : JSON::Any,
        created_at : Time,
        updated_at : Time

      # Exports the live documents of one doctype.
      #
      # `format` is `csv` or `json`. `filters` use the same filter grammar as
      # the list action (`Document::FilterCompiler`); they narrow the
      # caller's read scopes, never widen them — a malformed money filter
      # answers `422` with the param named. `batch_size` exists for tests;
      # production callers take the default.
      #
      # `columns` selects the CSV columns (a non-nil selection with a
      # non-csv format answers `422` — the JSON export's full-content shape
      # stays explicit). `sort` is the list operation's sort grammar; it
      # orders the run through `Document::List.build_order_clause`, with the
      # id-order keyset kept whenever the sort reduces to plain `id ASC`. A
      # sort entry the definition cannot serve (unknown field, non-scalar
      # type) answers `422` — it never silently reorders or silently keeps
      # id order (B-158).
      # `timezone` is an IANA zone name for the view CSV's timestamp cells;
      # `nil` keeps the UTC RFC-3339 cells of the full export.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        format : String,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        batch_size : Int32 = BATCH_SIZE,
        columns : Array(String)? = nil,
        sort : Array(String)? = nil,
        timezone : String? = nil,
      ) : Result | Facet::ServiceError
        unless FORMATS.includes?(format)
          return Facet::ServiceError.new(422, "Unknown format: #{format} (supported: #{FORMATS.join(", ")})")
        end

        if columns && format != "csv"
          return Facet::ServiceError.new(422, "Column selection requires the csv format (got: #{format})")
        end

        location : Time::Location? = nil
        if tz = timezone
          begin
            location = Time::Location.load(tz)
          rescue ex
            return Facet::ServiceError.new(422, "Invalid timezone '#{tz}': #{ex.message}")
          end
        end

        Facet::Telemetry.trace("document.export") do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["format"] = format

          definition = Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
          return Facet::ServiceError.new(404, "Unknown doctype: #{domain}.#{doc_type}") if definition.nil?

          # Class-level read denial — 403, matching the list endpoint. An
          # export file that is silently empty would hide the
          # misconfiguration the loud answer surfaces.
          if RBAC::ReadEnforcer.list_denied?(domain, doc_type, auth_context)
            IAM::Helpers.write_layer1_denial(db, auth_context, "read", domain, [doc_type])
            return Facet::ServiceError.new(403, "Forbidden")
          end

          result = run(db, domain, doc_type, format, definition, filters, auth_context, batch_size, columns, sort, location)
          span["row_count"] = result.row_count.to_s if result.is_a?(Result)
          result
        end
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Opens the snapshot transaction, compiles the query, streams the rows
      # into a temp file. On any error the temp file is deleted; on success
      # it stays on disk for the caller. `columns` / `location` shape the
      # CSV view export; `sort` picks the pagination path (`nil` keeps the
      # id-order keyset, any other order walks OFFSET pages).
      private def self.run(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        format : String,
        definition : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
        batch_size : Int32,
        columns : Array(String)?,
        sort : Array(String)?,
        location : Time::Location?,
      ) : Result | Facet::ServiceError
        begin
          where_sql, base_params = build_query(db, domain, doc_type, definition, filters, auth_context)
        rescue ex : Util::FilterClauses::MoneyFilterError
          return Facet::ServiceError.new(422, ex.message.to_s)
        rescue ex : Util::FilterClauses::FilterGrammarError
          # A field the active role cannot see answers 403, matching the list
          # and aggregate gates — never the 422 shape that names the field's
          # type contract (S4). The other refusals answer 422 with the
          # structured detail.
          if ex.reason == "invisible_filter_field"
            return Facet::ServiceError.new(403, ex.message.to_s)
          end
          return Facet::ServiceError.new(422, ex.message.to_s, details: [
            ValidationError.new(field: ex.filter_key, code: ex.reason, message: ex.message.to_s),
          ])
        end

        order_clause = order_clause_for(sort, definition, auth_context)
        return order_clause if order_clause.is_a?(Facet::ServiceError)

        file = File.tempfile("facet-export", ".#{format}")
        begin
          row_count = Database.with_transaction(db, isolation: TRANSACTION_ISOLATION) do
            stream(db, format, file, definition, auth_context, where_sql, base_params, batch_size, columns, order_clause, location)
          end
          file.flush
          Result.new(path: file.path, format: format, row_count: row_count)
        rescue ex
          File.delete?(file.path)
          raise ex
        ensure
          file.close
        end
      end

      # The ORDER BY clause for the sorted path, `nil` when the run keeps
      # the id-order keyset. A sort that reduces to plain `id ASC` —
      # absent, empty, or the bare `id` entry — yields `nil`, so the
      # no-sort case keeps the cheap keyset scan instead of a slower OFFSET
      # walk in the same order. A real sort never reduces to `id ASC` on
      # its own: entries ride with their direction (`id DESC`), and
      # multi-entry sorts keep every expression. An entry the definition
      # cannot serve answers `422` through `build_order_clause` (B-158);
      # the caller surfaces it instead of running in the wrong order.
      private def self.order_clause_for(sort : Array(String)?, definition : Doctype::DoctypeDefinition, auth_context : RBAC::AuthContext) : String? | Facet::ServiceError
        return nil if sort.nil? || sort.empty?
        clause = Document::List.build_order_clause(sort, definition, auth_context)
        return clause if clause.is_a?(Facet::ServiceError)
        clause.gsub(/\s+/, " ").downcase == "id asc" ? nil : clause
      end

      # Compiles the export WHERE clause: doctype identity + live-only, then
      # the caller's RBAC scope clauses, then the user filter grammar — the
      # same composition the list action runs. Clause order fixes placeholder
      # numbering; the clauses AND-compose, so the order does not change
      # semantics.
      private def self.build_query(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        definition : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
      ) : {String, Array(::DB::Any)}
        where_clauses = ["domain = $1", "doc_type = $2", "deleted_at IS NULL"]
        all_params = [domain, doc_type] of ::DB::Any

        scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
          db, domain, doc_type, auth_context, start_idx: all_params.size + 1
        )
        where_clauses.concat(scope_clauses)
        all_params.concat(scope_params)

        filter_clauses, filter_params = FilterCompiler.compile(definition, filters, offset: all_params.size, auth_context: auth_context)
        where_clauses.concat(filter_clauses)
        all_params.concat(filter_params)

        {where_clauses.join(" AND "), all_params}
      end

      # Dispatches to the format writer. The JSON writer ignores the view
      # parameters — its rows are full read-masked content and its `meta`
      # timestamps stay UTC RFC-3339 by contract (the route only ever pairs
      # columns with csv).
      private def self.stream(
        db : DB::Connection,
        format : String,
        file : File,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        where_sql : String,
        base_params : Array(::DB::Any),
        batch_size : Int32,
        columns : Array(String)?,
        order_clause : String?,
        location : Time::Location?,
      ) : Int64
        if format == "csv"
          stream_csv(db, file, definition, auth_context, where_sql, base_params, batch_size, columns, order_clause, location)
        else
          stream_json(db, file, definition, auth_context, where_sql, base_params, batch_size)
        end
      end

      # Reads batches and yields each to the given block until the keyset
      # query comes back empty. Each batch chains on the last id of the
      # previous one, so the global row order is `id` ascending across batch
      # boundaries.
      private def self.each_batch(
        db : DB::Connection,
        where_sql : String,
        base_params : Array(::DB::Any),
        batch_size : Int32,
        & : Array(Row) -> Nil
      ) : Nil
        last_id = ""
        loop do
          rows = read_batch(db, where_sql, base_params, last_id, batch_size)
          break if rows.empty?
          yield rows
          last_id = rows.last.id
        end
      end

      # Keyset scan: `... AND id > $last ORDER BY id LIMIT batch`. The first
      # batch binds an empty string — ids are non-empty ULIDs, so the
      # comparison selects every row.
      private def self.read_batch(
        db : DB::Connection,
        where_sql : String,
        base_params : Array(::DB::Any),
        last_id : String,
        batch_size : Int32,
      ) : Array(Row)
        rows = [] of Row
        params = base_params + [last_id]
        db.query(
          <<-SQL,
            SELECT id, content, meta, created_at, updated_at
            FROM projections
            WHERE #{where_sql} AND id > $#{base_params.size + 1}
            ORDER BY id ASC
            LIMIT #{batch_size}
          SQL


          args: params
        ) do |rs|
          rs.each do
            rows << row_from(rs)
          end
        end
        rows
      end

      # OFFSET batching for the sorted path: walks the same snapshot in the
      # caller's order, one page of `batch_size` at a time. The trailing
      # `id ASC` in the ORDER BY is the deterministic tiebreaker, and the
      # whole export runs inside one REPEATABLE READ transaction — the
      # snapshot is stable, so pages never overlap or skip rows.
      private def self.each_batch_offset(
        db : DB::Connection,
        where_sql : String,
        base_params : Array(::DB::Any),
        order_clause : String,
        batch_size : Int32,
        & : Array(Row) -> Nil
      ) : Nil
        offset = 0
        loop do
          rows = read_batch_offset(db, where_sql, base_params, order_clause, offset, batch_size)
          break if rows.empty?
          yield rows
          offset += batch_size
        end
      end

      private def self.read_batch_offset(
        db : DB::Connection,
        where_sql : String,
        base_params : Array(::DB::Any),
        order_clause : String,
        offset : Int32,
        batch_size : Int32,
      ) : Array(Row)
        rows = [] of Row
        db.query(
          <<-SQL,
            SELECT id, content, meta, created_at, updated_at
            FROM projections
            WHERE #{where_sql}
            ORDER BY #{order_clause}, id ASC
            LIMIT #{batch_size} OFFSET #{offset}
          SQL


          args: base_params
        ) do |rs|
          rs.each do
            rows << row_from(rs)
          end
        end
        rows
      end

      # One projection row off a positioned result set — the column order
      # is fixed by both read paths' SELECT.
      private def self.row_from(rs) : Row
        Row.new(
          id: rs.read(String),
          content: rs.read(JSON::Any),
          meta: rs.read(JSON::Any),
          created_at: rs.read(Time),
          updated_at: rs.read(Time),
        )
      end

      # Streams every row through the CSV codec. Without a column
      # selection the header comes from the definition and the pagination
      # stays the id-order keyset; a selection switches to the view row
      # codec and — under a user sort — the OFFSET batching, both inside
      # the same snapshot transaction. An empty doctype writes the header
      # and nothing else.
      private def self.stream_csv(
        db : DB::Connection,
        file : File,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        where_sql : String,
        base_params : Array(::DB::Any),
        batch_size : Int32,
        columns : Array(String)?,
        order_clause : String?,
        location : Time::Location?,
      ) : Int64
        csv = CSV::Builder.new(file)
        if columns
          csv.row(Facet::ImportExport::CsvSerializer.header(definition, columns))
        else
          csv.row(Facet::ImportExport::CsvSerializer.header(definition, auth_context))
        end
        row_count = 0_i64
        if order_clause
          each_batch_offset(db, where_sql, base_params, order_clause, batch_size) do |rows|
            rows.each do |row|
              csv.row(encode_csv_row(row, definition, auth_context, columns, location))
            end
            row_count += rows.size
          end
        else
          each_batch(db, where_sql, base_params, batch_size) do |rows|
            rows.each do |row|
              csv.row(encode_csv_row(row, definition, auth_context, columns, location))
            end
            row_count += rows.size
          end
        end
        row_count
      end

      # One CSV data row: the view codec under a column selection, the
      # full-doctype codec without one. Both take the read-masked content.
      private def self.encode_csv_row(
        row : Row,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        columns : Array(String)?,
        location : Time::Location?,
      ) : Array(String)
        content = masked_content(row, auth_context, definition)
        if columns
          Facet::ImportExport::CsvSerializer.encode_view_row(
            row.id, content, row.created_at, row.updated_at, definition, columns, location,
          )
        else
          Facet::ImportExport::CsvSerializer.encode_row(row.id, content, definition, auth_context)
        end
      end

      # Streams every row as `{"id", "content", "meta"}`. `content` is the
      # read-masked stored content; `meta` is export-only context — the row's
      # own timestamps and `meta.schema_version`, so a consumer can see when
      # a row is stale relative to the definition. An empty doctype writes
      # `[]`.
      private def self.stream_json(
        db : DB::Connection,
        file : File,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        where_sql : String,
        base_params : Array(::DB::Any),
        batch_size : Int32,
      ) : Int64
        json = JSON::Builder.new(file)
        json.start_document
        row_count = 0_i64
        json.array do
          each_batch(db, where_sql, base_params, batch_size) do |rows|
            rows.each do |row|
              write_json_row(json, row, auth_context, definition)
              row_count += 1
            end
          end
        end
        json.end_document
        json.flush
        row_count
      end

      # The stored `meta.schema_version` of a row, 1 when absent.
      private def self.write_json_row(
        json : JSON::Builder,
        row : Row,
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : Nil
        json.object do
          json.field("id", row.id)
          json.field("content") { masked_content(row, auth_context, definition).to_json(json) }
          json.field("meta") do
            json.object do
              json.field("created_at", row.created_at.to_rfc3339)
              json.field("updated_at", row.updated_at.to_rfc3339)
              json.field("schema_version", schema_version_of(row.meta))
            end
          end
        end
      end

      # The stored `meta.schema_version` of a row, 1 when absent. A value
      # below the definition's current version marks a stale row — export
      # does not migrate it, it reports it.
      private def self.schema_version_of(meta : JSON::Any) : Int32
        sv = meta.as_h?.try(&.["schema_version"]?)
        sv.try(&.as_i?) || 1
      end

      private def self.masked_content(
        row : Row,
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        RBAC::ReadEnforcer.mask_content(row.content, auth_context, definition)
      end
    end
  end
end
