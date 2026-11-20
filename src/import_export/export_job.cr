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
require "./export"
require "./artifacts"
require "./caller_context"
require "./job_outcome"

module Facet
  module Document
    # Background handler for one document export.
    #
    # Kind `document_export`. A job runs once (`max_attempts: 1`): any
    # in-process failure is terminal, the caller fixes the input and
    # submits again. The lease sweep is the crash detector — the row
    # enqueues with the queue's long lease horizon
    # (`jobs.long_lease_ttl_s`) so a dead worker's row recovers within
    # the hour instead of being requeued mid-run by the 60 s default.
    #
    # The payload carries coordinates only: `{domain, doc_type, format,
    # account_id, role_id?, app_id?, api_key_id?, filters}`. Both the
    # caller's scopes and the stored filter params recompile at execution
    # time — a role or definition change between enqueue and execution
    # changes the export, exactly as it changes a list request.
    #
    # Terminal outcome, in order: the export streams to a temp file
    # (`Document::Export`), the bytes store as an ownerless artifact, the
    # temp file is deleted, the job result records `{artifact_id,
    # row_count, format}`, the completion notification goes to the
    # requesting account, and the `export_completed` event publishes on
    # the source doctype's stream. An expected failure returns a
    # `Failed` result carrying the error and emits `export_failed`; nothing
    # was stored.
    class ExportJob < Jobs::Handler
      KIND = "document_export"

      # A job runs once — no automatic retry, per the import/export design.
      def self.default_max_attempts : Int32
        1
      end

      # The completion events are opt-in for webhooks: a binding fires only
      # when its `events` list names the event. A match-all webhook never
      # receives them. The names live on `Facet::Event` beside the other
      # opt-in classes.
      EVENT_COMPLETED = ::Facet::Event::EXPORT_COMPLETED
      EVENT_FAILED    = ::Facet::Event::EXPORT_FAILED

      Log = ::Log.for("facet.import_export.export_job")

      # Executes one claimed export row. Expected failures return a
      # `Failed` result. An unexpected exception propagates and the worker
      # turns it into a `Failed` result (the handler contract).
      def execute(job : Jobs::Job) : Jobs::Handler::Result
        payload = Payload.from_json(job.payload.to_json)

        Database.with_db(:read_write) do |db|
          # Job entry hydration: the stored filters recompile at execution
          # time, and money filter values validate tickers against the
          # in-process registry.
          Currency::Registry.ensure_fresh(db)

          auth_context = rebuild_context(db, payload)

          outcome = Document::Export.call(db, payload.domain, payload.doc_type, payload.format,
            filters: payload.filters, auth_context: auth_context,
            columns: payload.columns, sort: payload.sort, timezone: payload.timezone,
          )
          case outcome
          in Facet::ServiceError
            emit_failure(db, payload, job.id, outcome.message)
            Jobs::Handler::Result.new(status: Jobs::Handler::Kind::Failed, error: outcome.message)
          in Document::Export::Result
            exported = outcome
            begin
              put = ImportExport::Artifacts.put(db, File.open(exported.path, "rb"), export_filename(payload), mime_type(payload.format), auth_context)
            ensure
              File.delete?(exported.path)
            end

            emit_success(db, payload, job.id, exported, put)
            Jobs::Handler::Result.new(status: Jobs::Handler::Kind::Succeeded, result: result_json(payload, exported, put))
          end
        end
      end

      # ── Payload ──────────────────────────────────────────────────────

      # The enqueue payload. `filters` carries the raw user filter hash —
      # the same grammar the list action accepts; the route validates it
      # at enqueue time, and the export service compiles it again at
      # execution time.
      #
      # `columns` / `sort` / `timezone` are the view-export extension: their
      # presence marks the run as a table-view export (`{domain}.{doctype}
      # .view.csv`, the "View export ready" notification). The route
      # validates all three before enqueue; the service re-validates the
      # timezone (a load failure fails the job loud).
      class Payload
        include JSON::Serializable

        getter domain : String
        getter doc_type : String
        getter format : String
        getter account_id : String
        getter role_id : String?
        getter app_id : String?
        getter api_key_id : String?
        getter filters : Hash(String, JSON::Any)
        getter columns : Array(String)?
        getter sort : Array(String)?
        getter timezone : String?

        # A payload carrying `columns` is a view export — the filename and
        # the notification derive from the marker, so the status/download
        # paths can tell the file apart without a second job kind.
        def view_export? : Bool
          !columns.nil?
        end
      end

      # ── Execution-time context ───────────────────────────────────────

      # Rebuilds the caller's `AuthContext` when the job runs — live role,
      # app, and grant reads shared with the import handler through
      # `ImportExport::CallerContext`.
      private def rebuild_context(db : DB::Connection, payload : Payload) : RBAC::AuthContext
        ImportExport::CallerContext.rebuild(db, ImportExport::CallerContext::Caller.new(
          account_id: payload.account_id,
          role_id: payload.role_id,
          app_id: payload.app_id,
          api_key_id: payload.api_key_id,
        ))
      end

      # ── Outcome assembly ─────────────────────────────────────────────

      # The job result the status route surfaces: the artifact
      # coordinates of the finished export.
      private def result_json(payload : Payload, exported : Document::Export::Result, put : ImportExport::Artifacts::Put) : JSON::Any
        JSON.parse({
          "artifact_id" => put.artifact_id,
          "row_count"   => exported.row_count,
          "format"      => payload.format,
        }.to_json)
      end

      # Formats the artifact filename: `crm.Company.csv` for the full
      # doctype export, `crm.Company.view.csv` for a view export (a
      # payload carrying `columns`).
      private def export_filename(payload : Payload) : String
        marker = payload.view_export? ? ".view" : ""
        "#{payload.domain}.#{payload.doc_type}#{marker}.#{payload.format}"
      end

      private def mime_type(format : String) : String
        format == "csv" ? "text/csv" : "application/json"
      end

      # ── Event + notification ──────────────────────

      # Success outcome event + notification. `row_count` rides the event
      # payload; the notification body states the row count.
      private def emit_success(
        db : DB::Connection,
        payload : Payload,
        job_id : String,
        exported : Document::Export::Result,
        put : ImportExport::Artifacts::Put,
      ) : Nil
        detail = ImportExport::JobOutcome.detail_hash(payload.domain, payload.doc_type, payload.format, job_id)
        detail["row_count"] = JSON::Any.new(exported.row_count)
        detail["artifact_id"] = JSON::Any.new(put.artifact_id)

        ImportExport::JobOutcome.emit(
          db,
          domain: payload.domain,
          doc_type: payload.doc_type,
          account_id: payload.account_id,
          job_id: job_id,
          event_name: EVENT_COMPLETED,
          payload_key: "export",
          detail: detail,
          notification: {
            title: payload.view_export? ? "View export ready" : "Export ready",
            body:  "#{export_filename(payload)} — #{exported.row_count} rows",
            data:  JSON.parse({
              "job_id"      => job_id,
              "format"      => payload.format,
              "row_count"   => JSON::Any.new(exported.row_count),
              "artifact_id" => put.artifact_id,
              "download"    => "/Api/#{payload.domain}/#{payload.doc_type}/import_export/#{job_id}/download",
            }.to_json),
          },
        )
      end

      # Failure outcome event + notification. `row_count` is absent —
      # nothing was written.
      private def emit_failure(db : DB::Connection, payload : Payload, job_id : String, error : String) : Nil
        detail = ImportExport::JobOutcome.detail_hash(payload.domain, payload.doc_type, payload.format, job_id)
        detail["error"] = JSON::Any.new(error)

        ImportExport::JobOutcome.emit(
          db,
          domain: payload.domain,
          doc_type: payload.doc_type,
          account_id: payload.account_id,
          job_id: job_id,
          event_name: EVENT_FAILED,
          payload_key: "export",
          detail: detail,
          notification: {
            title: "Export failed",
            body:  "Fix the problem and submit the export again: #{error}",
            data:  JSON.parse({
              "job_id"    => job_id,
              "format"    => payload.format,
              "row_count" => nil,
              "error"     => error,
            }.to_json),
          },
        )
      end
    end
  end
end
