# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../../database"
require "../../rbac"
require "../../jobs/handler"
require "../../import_export/artifacts"
require "../../import_export/caller_context"
require "../../import_export/job_outcome"
require "./archive"
require "./export"

module Facet
  module Domain
    module Portable
      # Background handler for one domain export.
      #
      # Kind `domain_export`. A job runs once (`max_attempts: 1`): any
      # in-process failure is terminal, the caller fixes the input and
      # submits again. The lease sweep is the crash detector — the row
      # enqueues with the queue's long lease horizon
      # (`jobs.long_lease_ttl_s`).
      #
      # The payload carries coordinates only: `{domain, account_id,
      # role_id?, app_id?, api_key_id?}`. The caller's authorization
      # context rebuilds at execution time (`ImportExport::CallerContext`)
      # and the read gate re-runs — an authorization change between
      # enqueue and execution applies.
      #
      # Terminal outcome, in order: the caller's read gate on the
      # `core.Domain` document re-runs, the export service builds the
      # in-memory bundle (definition-only — the HTTP surface never
      # captures document data), `Archive.write` produces the zip, the
      # bytes store as an ownerless artifact, the temp file is deleted,
      # and the job result records `{artifact_id, doctype_count,
      # document_view_count, collection_view_count, format}`. The
      # completion notification goes to the requesting account and the
      # `domain_export_completed` event publishes on the `core.Domain`
      # stream. An expected failure (draft domain, vanished domain,
      # denied gate) returns a `Failed` result carrying the
      # `expected` marker and emits `domain_export_failed`.
      class ExportJob < Jobs::Handler
        KIND = "domain_export"

        # A job runs once — no automatic retry, per the import/export design.
        def self.default_max_attempts : Int32
          1
        end

        # The completion events are opt-in for webhooks: a binding fires
        # only when its `events` list names the event. A match-all
        # webhook never receives them.
        EVENT_COMPLETED = ::Facet::Event::DOMAIN_EXPORT_COMPLETED
        EVENT_FAILED    = ::Facet::Event::DOMAIN_EXPORT_FAILED

        Log = ::Log.for("facet.domain.portable.export_job")

        MIME_TYPE = "application/zip"

        # The result marker an expected failure carries. The wait-mode
        # response maps it to a `422`; a failure without the marker is a
        # crash-class failure and answers `500`.
        EXPECTED_RESULT = JSON.parse({"expected" => true}.to_json)

        # Executes one claimed export row. Expected failures return a
        # `Failed` result. An unexpected exception propagates and the
        # worker turns it into a `Failed` result (the handler contract).
        def execute(job : Jobs::Job) : Jobs::Handler::Result
          payload = Payload.from_json(job.payload.to_json)

          Database.with_db(:read_write) do |db|
            auth_context = rebuild_context(db, payload)

            gate_message = denied_read_message(db, payload, auth_context)
            if gate_message
              emit_failure(db, payload, job.id, gate_message)
              next Jobs::Handler::Result.new(
                status: Jobs::Handler::Kind::Failed,
                error: gate_message,
                result: EXPECTED_RESULT,
              )
            end

            outcome = Export.call(db, payload.domain)
            case outcome
            in Facet::ServiceError
              emit_failure(db, payload, job.id, outcome.message)
              Jobs::Handler::Result.new(
                status: Jobs::Handler::Kind::Failed,
                error: outcome.message,
                result: EXPECTED_RESULT,
              )
            in Export::Result
              exported = outcome
              zip_path = write_zip(exported.bundle, payload.domain)
              begin
                put = ImportExport::Artifacts.put(
                  db, File.open(zip_path, "rb"), export_filename(payload), MIME_TYPE,
                  auth_context,
                )
              ensure
                File.delete?(zip_path)
              end

              emit_success(db, payload, job.id, exported, put)
              Jobs::Handler::Result.new(
                status: Jobs::Handler::Kind::Succeeded,
                result: result_json(payload, exported, put),
              )
            end
          end
        end

        # ── Payload ──────────────────────────────────────────────────────

        # The enqueue payload: coordinates and identity references only.
        # `role_id` is the enqueuer's active role; the handler re-reads
        # the role, app, and grant projections at execution time.
        class Payload
          include JSON::Serializable

          getter domain : String
          getter account_id : String
          getter role_id : String?
          getter app_id : String?
          getter api_key_id : String?
        end

        # ── Execution-time context and gate ─────────────────────────────

        private def rebuild_context(db : DB::Connection, payload : Payload) : RBAC::AuthContext
          ImportExport::CallerContext.rebuild(db, ImportExport::CallerContext::Caller.new(
            account_id: payload.account_id,
            role_id: payload.role_id,
            app_id: payload.app_id,
            api_key_id: payload.api_key_id,
          ))
        end

        # The read gate re-runs at execution time: the caller must still
        # read the `core.Domain` document. The message names the domain —
        # the caller supplied it, so nothing leaks.
        private def denied_read_message(
          db : DB::Connection,
          payload : Payload,
          auth_context : RBAC::AuthContext,
        ) : String?
          return nil if RBAC::ReadEnforcer.authorized?(db, "core", "Domain", payload.domain, auth_context)
          "Not authorized to export domain '#{payload.domain}'"
        end

        # ── Bundle packaging ─────────────────────────────────────────────

        # Writes the bundle as a zip at a fresh temp path. `Archive.write`
        # dispatches on the `.zip` extension.
        private def write_zip(bundle : Archive::Bundle, domain : String) : String
          path = File.tempname("facet-domain-export", ".zip")
          Archive.write(bundle, path)
          path
        end

        private def export_filename(payload : Payload) : String
          "#{payload.domain}.facet-domain.zip"
        end

        # The job result the status route surfaces: the artifact
        # coordinates of the finished export.
        private def result_json(
          payload : Payload,
          exported : Export::Result,
          put : ImportExport::Artifacts::Put,
        ) : JSON::Any
          JSON.parse({
            "artifact_id"           => put.artifact_id,
            "doctype_count"         => exported.doctype_count,
            "document_view_count"   => exported.document_view_count,
            "collection_view_count" => exported.collection_view_count,
            "format"                => "zip",
          }.to_json)
        end

        # ── Event + notification ─────────────────────────────────────────

        # The event publishes on the `core.Domain` stream; the
        # notification points at the exported domain's own document
        # (`core.Domain`, id = the domain name).
        private def emit_success(
          db : DB::Connection,
          payload : Payload,
          job_id : String,
          exported : Export::Result,
          put : ImportExport::Artifacts::Put,
        ) : Nil
          detail = detail_hash(payload, job_id)
          detail["doctype_count"] = JSON::Any.new(exported.doctype_count)
          detail["document_view_count"] = JSON::Any.new(exported.document_view_count)
          detail["collection_view_count"] = JSON::Any.new(exported.collection_view_count)
          detail["artifact_id"] = JSON::Any.new(put.artifact_id)

          ImportExport::JobOutcome.emit(
            db,
            domain: "core",
            doc_type: "Domain",
            account_id: payload.account_id,
            job_id: job_id,
            event_name: EVENT_COMPLETED,
            payload_key: "domain_export",
            detail: detail,
            notification: {
              title: "Domain export ready",
              body:  "#{export_filename(payload)} — #{exported.doctype_count} doctypes",
              data:  JSON.parse({
                "job_id"        => job_id,
                "domain"        => payload.domain,
                "doctype_count" => JSON::Any.new(exported.doctype_count),
                "artifact_id"   => put.artifact_id,
                "download"      => "/Api/core/Domain/import_export/#{job_id}/download",
              }.to_json),
            },
            notification_doc_type: "Domain",
            notification_doc_id: payload.domain,
          )
        end

        # Failure outcome event + notification. Nothing was stored.
        private def emit_failure(
          db : DB::Connection,
          payload : Payload,
          job_id : String,
          error : String,
        ) : Nil
          detail = detail_hash(payload, job_id)
          detail["error"] = JSON::Any.new(error)

          ImportExport::JobOutcome.emit(
            db,
            domain: "core",
            doc_type: "Domain",
            account_id: payload.account_id,
            job_id: job_id,
            event_name: EVENT_FAILED,
            payload_key: "domain_export",
            detail: detail,
            notification: {
              title: "Domain export failed",
              body:  "Fix the problem and submit the export again: #{error}",
              data:  JSON.parse({
                "job_id" => job_id,
                "domain" => payload.domain,
                "error"  => error,
              }.to_json),
            },
            notification_doc_type: "Domain",
            notification_doc_id: payload.domain,
          )
        end

        private def detail_hash(payload : Payload, job_id : String) : Hash(String, JSON::Any)
          {
            "id"     => JSON::Any.new(job_id),
            "domain" => JSON::Any.new(payload.domain),
          } of String => JSON::Any
        end
      end
    end
  end
end
