# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "csv"
require "json"
require "opentelemetry"
require "../config"
require "../database"
require "../error"
require "../rbac"
require "../event/publisher"
require "../doctype/definition_store"
require "../mutation/client"
require "../document/money_currency_check"
require "./csv_serializer"

module Facet
  module Document
    # Import service for the document import/export concern: file rows in,
    # documents out. The transactional core of the import side.
    #
    # Decodes the rows of one CSV or JSON file and upserts them by the
    # manifest ids inside one `Database.with_transaction` — the whole file
    # lands or nothing does. The first failing row aborts the transaction:
    # zero rows persist, and the failure report names that row.
    #
    # Per row, by manifest id (the id fix-up point — the manifest resolved
    # absent file ids to generated ULIDs at enqueue time):
    #
    # - live non-deleted id → `Document::Update.call` (the full update path:
    #   validation, Lua update hook, computed fields, `updated` event);
    # - tombstoned id → `skipped` — import never resurrects a deleted
    #   document, the same rule the delete-rollback gate enforces;
    # - absent id → `Document::Create.create_from_parsed` (the full create
    #   path: validation, Lua create hook, computed fields, `created` event).
    #
    # Both write paths run with the per-row RBAC of the caller's auth
    # context and `actioner_id: "import"` — audit and hooks can tell a bulk
    # import from a hand edit. An upsert import therefore needs create AND
    # update permission on the doctype; the first row the caller may not
    # write fails the file, loud and terminal.
    #
    # A row whose content equals the stored content takes the update path
    # and counts as updated — `Document::Update` turns an empty diff into a
    # no-op (no new mutation), which is what makes a re-execution after a
    # crash absorb what the first attempt already committed.
    #
    # After the commit: one `Event::Publisher.flush` — every `created` /
    # `updated` event of the file goes out in one burst. Nothing publishes
    # before the commit.
    #
    # The service layer knows nothing about jobs, artifacts, or routes: it
    # takes the file text, the manifest ids, and a connection.
    module Import
      # The per-row mutation actor, constant for the whole file. Differs
      # from the portable-domain import's `system:import` — this is the
      # user-triggered bulk import, not a domain bundle apply.
      ACTIONER_ID = "import"

      # Accepted input formats.
      FORMATS = Set{"csv", "json"}

      # The upsert report the caller surfaces on success.
      record Result,
        row_count : Int32,
        created : Int32,
        updated : Int32,
        skipped : Int32

      # The first failing row. `field` is `nil` for failures no single
      # field owns (an RBAC denial, a Lua script rejection).
      record RowFailure,
        row : Int32,
        field : String?,
        message : String

      # Raised inside the write transaction on the first failing row so the
      # ROLLBACK runs — returning the failure normally would commit the
      # rows already persisted. Caught one frame outside the transaction.
      class Failure < ::Exception
        getter report : RowFailure

        def initialize(@report : RowFailure)
          super("row #{@report.row}: #{@report.message}")
        end
      end

      # Raised on a structurally unusable input that no single row owns and
      # the route's synchronous parse should have rejected — a defect or a
      # race, never a data problem the caller fixes by editing row N. The
      # handler converts this to a crash-class failure.
      class MalformedInput < ::Exception
      end

      private enum RowOutcome
        Create
        Update
        Skip
      end

      # Imports the rows of one file.
      #
      # `file_text` is the raw CSV or JSON upload; `ids` is the manifest —
      # one document id per data row, positionally paired; `supplied` is the
      # parallel provenance array (true when the file row carried the id
      # itself). `definition` is the live doctype definition. `auth_context`
      # is the requesting caller's execution-time context; every row writes
      # under its own RBAC (`WriteEnforcer`) inside the services.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        definition : Doctype::DoctypeDefinition,
        format : String,
        file_text : String,
        ids : Array(String),
        supplied : Array(Bool),
        auth_context : RBAC::AuthContext,
      ) : Result | RowFailure
        unless FORMATS.includes?(format)
          raise MalformedInput.new("Unknown format: #{format}")
        end

        # Row-count guard (B-272) — before any decode and before the
        # transaction opens. The whole file applies as one transaction, so
        # an unbounded file could pin a WAL-sized write and exhaust the
        # database volume from one API call. The manifest ids pair
        # positionally with the data rows, so `ids.size` is the row count
        # the file carries (the service itself fails loud on a mismatch
        # below). A refusal is a caller-fixable failure — the `RowFailure`
        # shape, row 0 because no single row owns it, zero rows written.
        limit = Config.instance.import_export.max_import_rows
        if ids.size > limit
          return RowFailure.new(
            row: 0,
            field: nil,
            message: "the file carries #{ids.size} rows; the configured import limit is #{limit} rows (import_export.max_import_rows)",
          )
        end

        Facet::Telemetry.trace("document.import") do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type

          # A decode failure raised during parsing is a row failure — the
          # transaction has not opened yet, so nothing rolls back.
          rows = begin
            parse_rows(format, file_text, definition)
          rescue ex : Failure
            return ex.report
          end
          if rows.size != ids.size
            raise MalformedInput.new("File carries #{rows.size} rows but the manifest lists #{ids.size} ids")
          end
          unless supplied.size == ids.size
            raise MalformedInput.new("Manifest pairs #{ids.size} ids with #{supplied.size} supplied flags")
          end
          span["row_count"] = rows.size.to_s

          created = 0
          updated = 0
          skipped = 0

          begin
            Database.with_transaction(db) do
              rows.each_with_index do |row, i|
                outcome = apply_row(db, domain, doc_type, definition, row, ids[i], supplied[i]?, auth_context)
                if outcome.is_a?(RowFailure)
                  # The first failing row aborts the transaction — zero rows
                  # persist. Stamp the 1-based data-row number the decode
                  # stage cannot know.
                  raise Failure.new(RowFailure.new(row: i + 1, field: outcome.field, message: outcome.message))
                end
                case outcome
                when RowOutcome::Create then created += 1
                when RowOutcome::Update then updated += 1
                when RowOutcome::Skip   then skipped += 1
                end
              end
            end
          rescue ex : Failure
            # Zero rows persisted, so nothing the rows buffered may ride a
            # later flush on this (worker) fiber — discard the burst.
            Event::Publisher.discard
            return ex.report
          end

          # The commit landed. Every created/updated event of the file goes
          # out in one burst — nothing published before this point.
          Event::Publisher.flush

          span["created"] = created.to_s
          span["updated"] = updated.to_s
          span["skipped"] = skipped.to_s
          Result.new(row_count: rows.size, created: created, updated: updated, skipped: skipped)
        end
      end

      # ── Row decoding ─────────────────────────────────────────────────

      # One decoded row: the content the write path will receive, already
      # free of server-managed fields. The id rides separately (`ids`, the
      # manifest's positional pairing).
      private record ParsedRow, content : JSON::Any

      # Parses and decodes every data row up front, before the transaction
      # opens. A cell-level decode failure (`RowError` — money grammar,
      # boolean text, broken JSON in a cell, wrong cell count) fails the
      # row here, before anything writes. Row numbers are 1-based over the
      # data rows; a `Failure` aborts before the transaction opens.
      private def self.parse_rows(format : String, file_text : String, definition : Doctype::DoctypeDefinition) : Array(ParsedRow)
        if format == "csv"
          parse_csv_rows(file_text, definition)
        else
          parse_json_rows(file_text, definition)
        end
      end

      private def self.parse_csv_rows(file_text : String, definition : Doctype::DoctypeDefinition) : Array(ParsedRow)
        parsed = CSV.parse(file_text)
        raise MalformedInput.new("CSV file carries no header row") if parsed.empty?

        headers = parsed[0]
        rows = [] of ParsedRow
        parsed.each_with_index do |cells, i|
          next if i.zero?
          decoded = Facet::ImportExport::CsvSerializer.decode_row(headers, cells, definition)
          rows << ParsedRow.new(content: JSON::Any.new(decoded[:content]))
        rescue ex : Facet::ImportExport::CsvSerializer::RowError
          raise Failure.new(RowFailure.new(row: i, field: ex.field, message: ex.message.to_s))
        end
        rows
      end

      private def self.parse_json_rows(file_text : String, definition : Doctype::DoctypeDefinition) : Array(ParsedRow)
        parsed = JSON.parse(file_text)
        array = parsed.as_a?
        raise MalformedInput.new("JSON file must be an array of rows") if array.nil?

        rows = [] of ParsedRow
        array.each_with_index do |element, i|
          obj = element.as_h?
          raise Failure.new(RowFailure.new(row: i + 1, field: nil, message: "row must be a JSON object")) if obj.nil?
          raw_content = obj["content"]?
          raise Failure.new(RowFailure.new(row: i + 1, field: nil, message: "row carries no content object")) if raw_content.nil?
          content = Facet::ImportExport::CsvSerializer.strip_server_managed(raw_content, definition)
          rows << ParsedRow.new(content: JSON::Any.new(content))
        end
        rows
      end

      # ── Upsert by manifest id ────────────────────────────────────────

      # Applies one row by its manifest id: update when a live document
      # with that id exists, skip when it is tombstoned, create when absent.
      # Returns the path taken, or the `RowFailure` of the first row the
      # write path rejected.
      private def self.apply_row(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        definition : Doctype::DoctypeDefinition,
        row : ParsedRow,
        id : String,
        supplied_id : Bool?,
        auth_context : RBAC::AuthContext,
      ) : RowOutcome | RowFailure
        deleted = db.query_one?(
          "SELECT deleted_at IS NOT NULL FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
          domain, doc_type, id,
          as: Bool,
        )

        if deleted.nil? # no row at all — create with the manifest id
          return write_create(db, domain, doc_type, definition, row, id, supplied_id, auth_context)
        end
        return RowOutcome::Skip if deleted # tombstoned — import never resurrects

        write_update(db, domain, doc_type, row, id, auth_context)
      end

      private def self.write_create(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        definition : Doctype::DoctypeDefinition,
        row : ParsedRow,
        id : String,
        supplied_id : Bool?,
        auth_context : RBAC::AuthContext,
      ) : RowOutcome | RowFailure
        # genonly guard: a doctype whose identifier is system-generated
        # never materializes a caller-supplied id as a new document.
        # Id-less rows import with the manifest's generated id (a crash
        # re-submission stays idempotent); an id that names an existing
        # document takes the update path and generates nothing.
        if supplied_id && definition.identifier.try(&.genonly?)
          return RowFailure.new(
            row: 0,
            field: "id",
            message: "The doctype's identifier is system-generated (genonly) — an import row cannot create a document with a caller-supplied id; omit the id column or target an existing id to update",
          )
        end

        # Import-mode currency check: a stored-but-deactivated ticker still
        # imports (the decode path only requires the ticker to be
        # registered). A hand edit on the normal write paths keeps the full
        # active-only rule — see `MoneyCurrencyCheck::Mode`.
        result = Document::Create.create_from_parsed(
          db, domain, doc_type, row.content, auth_context, ACTIONER_ID, doc_id: id,
          currency_check_mode: MoneyCurrencyCheck::Mode::Import)
        case result
        in Facet::ServiceError
          row_failure(result)
        in Document::Create::Result
          RowOutcome::Create
        end
      end

      private def self.write_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        row : ParsedRow,
        id : String,
        auth_context : RBAC::AuthContext,
      ) : RowOutcome | RowFailure
        result = Document::Update.call(
          db, domain, doc_type, id,
          row.content.to_json,
          auth_context, actioner_id: ACTIONER_ID,
          currency_check_mode: MoneyCurrencyCheck::Mode::Import)
        case result
        in Facet::ServiceError
          row_failure(result)
        in Document::Update::Result
          RowOutcome::Update
        end
      end

      # Collapses a write-path `ServiceError` into the failure report: the
      # first structured validation detail names the field, when one
      # exists. An RBAC denial or a script rejection has no field — the
      # service-level message stands alone. The caller stamps the 1-based
      # row number (the write path cannot know it).
      private def self.row_failure(error : Facet::ServiceError) : RowFailure
        first = error.details.try(&.first?)
        if first
          RowFailure.new(row: 0, field: first.field, message: first.message)
        else
          RowFailure.new(row: 0, field: nil, message: error.message)
        end
      end
    end
  end
end
