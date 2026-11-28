# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../database"
require "../config"
require "../util/script_helpers"
require "../jobs/handler"
require "../jobs/queries"
require "../event/publisher"
require "../iam/helpers"
require "../doctype/definition_store"
require "../currency"
require "./import"
require "./artifacts"
require "./caller_context"
require "./job_outcome"

module Facet
  module Document
    # Background handler for one document import.
    #
    # Kind `document_import`. A job runs once (`max_attempts: 1`): any
    # in-process failure is terminal, the caller fixes the input and
    # submits again. The lease sweep is the crash detector — the row
    # enqueues with the queue's long lease horizon
    # (`jobs.long_lease_ttl_s`), and the import service's upsert rule makes
    # a re-execution after a crash idempotent (the manifest fixes every
    # row's id at enqueue time).
    #
    # The payload carries coordinates and artifact ids only — never row
    # content: `{domain, doc_type, format, account_id, file_artifact_id,
    # manifest_artifact_id, role_id?, app_id?, api_key_id?}`. The caller's
    # scopes recompile at execution time, and every row writes under its
    # own RBAC (`WriteEnforcer`) with `actioner_id: "import"`.
    #
    # Terminal outcome, in order: the stored file bytes and manifest load,
    # `Document::Import` runs the whole file in one transaction (zero rows
    # persist on the first failing row), the job result records
    # `{row_count, created, updated, skipped}` on success or the failing
    # row's `{row, field, message}` on an expected failure, the completion
    # notification goes to the requesting account, and the
    # `import_completed` / `import_failed` event publishes on the source
    # doctype's stream.
    class ImportJob < Jobs::Handler
      KIND = "document_import"

      # A job runs once — no automatic retry, per the import/export design.
      def self.default_max_attempts : Int32
        1
      end

      # One import decodes a whole file and buffers one event per row, so
      # concurrent imports are the dominant term of the process footprint:
      # four default-size (100 k-row) files took an instance from 24 MB to
      # 11 GB. Two imports at once keep the peak bounded while still using
      # both sides of the write path. The cap rides the enqueue; a worker
      # honours it from its next start.
      def self.max_concurrent : Int32?
        2
      end

      # Executes one claimed import row.
      # The completion events are opt-in for webhooks: a binding fires only
      # when its `events` list names the event. A match-all webhook never
      # receives them. The names live on `Facet::Event` beside the other
      # opt-in classes.
      EVENT_COMPLETED = ::Facet::Event::IMPORT_COMPLETED
      EVENT_FAILED    = ::Facet::Event::IMPORT_FAILED

      Log = ::Log.for("facet.import_export.import_job")

      # Executes one claimed import row. Expected failures (a failing row)
      # return a `Failed` result and emit `import_failed`. A crash-class
      # failure (missing artifacts, unknown doctype, a database error)
      # raises `Jobs::JobError` / propagates — the worker turns it into a
      # terminal `Failed` result via the handler contract, and the
      # transaction's rollback already removed every row.
      def execute(job : Jobs::Job) : Jobs::Handler::Result
        payload = Payload.from_json(job.payload.to_json)

        Database.with_db(:read_write) do |db|
          # Job entry hydration: rows decode money tickers against the
          # in-process registry (CSV money cells parse via
          # `MoneyFilterValue`, which requires the ticker to be registered).
          Currency::Registry.ensure_fresh(db)

          definition = Doctype::DefinitionStore.fetch(db, "#{payload.domain}.#{payload.doc_type}")
          if definition.nil?
            raise Jobs::JobError.new("Unknown doctype: #{payload.domain}.#{payload.doc_type}")
          end

          auth_context = ImportExport::CallerContext.rebuild(db, ImportExport::CallerContext::Caller.new(
            account_id: payload.account_id,
            role_id: payload.role_id,
            app_id: payload.app_id,
            api_key_id: payload.api_key_id,
          ))

          file_text = read_artifact_text(db, payload.file_artifact_id)
          manifest = read_manifest(db, payload.manifest_artifact_id)

          outcome = Document::Import.call(db, payload.domain, payload.doc_type, definition,
            payload.format, file_text, manifest.ids, manifest.supplied, auth_context)

          result = case outcome
                   in Document::Import::Result
                     emit_success(db, payload, job.id, outcome)
                     Jobs::Handler::Result.new(status: Jobs::Handler::Kind::Succeeded, result: result_json(outcome))
                   in Document::Import::RowFailure
                     emit_failure(db, payload, job.id, outcome)
                     Jobs::Handler::Result.new(
                       status: Jobs::Handler::Kind::Failed,
                       # Row 0 marks a file-level refusal (the row-count guard) —
                       # no single row owns it, so the message stands alone.
                       error: outcome.row.zero? ? outcome.message : "row #{outcome.row}: #{outcome.message}",
                       result: failure_json(outcome),
                     )
                   end

          # An import is the one job that can transiently allocate a whole
          # file's worth of decoded rows and buffered events. The GC keeps the
          # high-water mark (the process RSS never returns the freed pages on
          # its own), so without a nudge every import job ratchets the resident
          # set up and never lets it back down. One collect per job — not per
          # row — settles the high-water mark once the working set is gone.
          GC.collect

          result
        end
      end

      # ── Payload ──────────────────────────────────────────────────────

      # The enqueue payload. Both artifact ids are ownerless artifact rows
      # the enqueue route staged: the raw uploaded file and the positional
      # row→id manifest.
      class Payload
        include JSON::Serializable

        getter domain : String
        getter doc_type : String
        getter format : String
        getter account_id : String
        getter file_artifact_id : String
        getter manifest_artifact_id : String
        getter role_id : String?
        getter app_id : String?
        getter api_key_id : String?
      end

      # ── Artifact reads ──────────────────────────────────────────────

      # The positional row→id manifest with provenance, as read from the
      # manifest artifact.
      record Manifest, ids : Array(String), supplied : Array(Bool)

      # The stored file bytes as text. Both import formats are text; a
      # missing or pruned artifact is a crash-class defect (the grace
      # window outlives the job's queue wait by far).
      private def read_artifact_text(db : DB::Connection, artifact_id : String) : String
        artifact = Artifact::Store.find_artifact(db, artifact_id)
        raise Jobs::JobError.new("Import file artifact #{artifact_id} is gone") if artifact.nil? || artifact.deleted_at

        io = Artifact::Uploader.open(artifact.path)
        begin
          io.gets_to_end
        ensure
          io.close
        end
      end

      # The manifest JSON: `{"ids": [...], "supplied": [...]}` — one document
      # id per data row, positionally paired, with the provenance flag that
      # says whether the file row carried the id itself or the id was
      # generated at enqueue time. Each id must be a non-empty string; each
      # flag must be a boolean.
      private def read_manifest(db : DB::Connection, artifact_id : String) : Manifest
        text = read_artifact_text(db, artifact_id)
        parsed = JSON.parse(text)

        ids_raw = parsed["ids"]?
        unless arr = ids_raw.try(&.as_a?)
          raise Jobs::JobError.new("Import manifest carries no ids array")
        end
        ids = arr.map do |v|
          id = v.as_s?
          raise Jobs::JobError.new("Import manifest carries a non-string id") if id.nil? || id.empty?
          id
        end

        supplied_raw = parsed["supplied"]?
        unless arr = supplied_raw.try(&.as_a?)
          raise Jobs::JobError.new("Import manifest carries no supplied array")
        end
        supplied = arr.map do |v|
          flag = v.as_bool?
          raise Jobs::JobError.new("Import manifest carries a non-boolean supplied flag") if flag.nil?
          flag
        end

        raise Jobs::JobError.new("Import manifest pairs #{ids.size} ids with #{supplied.size} supplied flags") unless ids.size == supplied.size

        Manifest.new(ids, supplied)
      rescue ex : JSON::ParseException
        raise Jobs::JobError.new("Import manifest is not valid JSON: #{ex.message}")
      end

      # ── Outcome assembly ─────────────────────────────────────────────

      # The job result the status route surfaces on success: the upsert
      # report. An import has no result file — the failing row's report on
      # a failure is one row, not a list.
      private def result_json(outcome : Document::Import::Result) : JSON::Any
        JSON.parse({
          "row_count" => outcome.row_count,
          "created"   => outcome.created,
          "updated"   => outcome.updated,
          "skipped"   => outcome.skipped,
        }.to_json)
      end

      private def failure_json(outcome : Document::Import::RowFailure) : JSON::Any
        JSON.parse({
          "row"     => outcome.row,
          "field"   => outcome.field,
          "message" => outcome.message,
        }.to_json)
      end

      # The text form of the failure report for the notification body: the
      # row prefix only when a single row owns the failure — a file-level
      # refusal (row 0, the row-count guard) carries its message alone.
      private def failure_detail(outcome : Document::Import::RowFailure) : String
        outcome.row.zero? ? outcome.message : "row #{outcome.row}: #{outcome.message}"
      end

      # ── Event + notification ──────────────────────

      # Success outcome event + notification. The report rides the event
      # payload; the notification body states the counts.
      private def emit_success(
        db : DB::Connection,
        payload : Payload,
        job_id : String,
        outcome : Document::Import::Result,
      ) : Nil
        detail = ImportExport::JobOutcome.detail_hash(payload.domain, payload.doc_type, payload.format, job_id)
        detail["row_count"] = JSON::Any.new(outcome.row_count)
        detail["created"] = JSON::Any.new(outcome.created)
        detail["updated"] = JSON::Any.new(outcome.updated)
        detail["skipped"] = JSON::Any.new(outcome.skipped)

        ImportExport::JobOutcome.emit(
          db,
          domain: payload.domain,
          doc_type: payload.doc_type,
          account_id: payload.account_id,
          job_id: job_id,
          event_name: EVENT_COMPLETED,
          payload_key: "import",
          detail: detail,
          notification: {
            title: "Import ready",
            body:  "#{payload.domain}.#{payload.doc_type} — #{outcome.created} created, " \
                  "#{outcome.updated} updated, #{outcome.skipped} skipped",
            data: JSON.parse({
              "job_id"    => job_id,
              "format"    => payload.format,
              "row_count" => JSON::Any.new(outcome.row_count),
              "status"    => "/Api/#{payload.domain}/#{payload.doc_type}/import_export/#{job_id}",
            }.to_json),
          },
        )
      end

      # Failure outcome event + notification. The report carries the
      # failing row's coordinates; the notification body states the
      # recovery: nothing was imported — fix the row and submit the file
      # again.
      private def emit_failure(
        db : DB::Connection,
        payload : Payload,
        job_id : String,
        outcome : Document::Import::RowFailure,
      ) : Nil
        detail = ImportExport::JobOutcome.detail_hash(payload.domain, payload.doc_type, payload.format, job_id)
        detail["error"] = JSON.parse(failure_json(outcome).to_json)

        recovery = outcome.row.zero? ? "fix the file and submit it again" \
                                        : "fix the failing row and submit the file again"
        ImportExport::JobOutcome.emit(
          db,
          domain: payload.domain,
          doc_type: payload.doc_type,
          account_id: payload.account_id,
          job_id: job_id,
          event_name: EVENT_FAILED,
          payload_key: "import",
          detail: detail,
          notification: {
            title: "Import failed",
            body:  "Nothing was imported — #{recovery}: #{failure_detail(outcome)}",
            data:  JSON.parse({
              "job_id"    => job_id,
              "format"    => payload.format,
              "row_count" => nil,
              "error"     => failure_json(outcome),
              "status"    => "/Api/#{payload.domain}/#{payload.doc_type}/import_export/#{job_id}",
            }.to_json),
          },
        )
      end
    end
  end
end
