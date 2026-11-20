# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../../database"
require "../../rbac"
require "../../util/projections"
require "../../artifact/store"
require "../../artifact/uploader"
require "../../jobs/handler"
require "../../import_export/caller_context"
require "../../import_export/job_outcome"
require "./archive"
require "./import"

module Facet
  module Domain
    module Portable
      # Background handler for one domain import.
      #
      # Kind `domain_import`. A job runs once (`max_attempts: 1`): any
      # in-process failure is terminal, the caller fixes the input and
      # submits again. The lease sweep is the crash detector — the row
      # enqueues with the queue's long lease horizon
      # (`jobs.long_lease_ttl_s`).
      #
      # The payload carries coordinates and one artifact id only —
      # `{bundle_artifact_id, into, merge, account_id, role_id?, app_id?,
      # api_key_id?}` — never bundle content. The caller's authorization
      # context rebuilds at execution time (`ImportExport::CallerContext`)
      # and the write gate re-runs against the resolved target: update
      # permission on the existing `core.Domain` document for a merge,
      # create permission for a fresh import.
      #
      # Terminal outcome, in order: the stored bundle bytes spool to a
      # temp file, `Archive.read` parses the container (zip or tarball),
      # a bundle carrying document data refuses (the HTTP surface is
      # definition-only), `Portable::Import.call` applies the whole
      # bundle in one transaction, and the job result records the import
      # counters. The completion notification goes to the requesting
      # account and the `domain_import_completed` /
      # `domain_import_failed` event publishes on the `core.Domain`
      # stream. An expected failure (unreadable bundle, document-data
      # section, denied gate, version-gate rejection, `409` conflict)
      # returns a `Failed` result carrying the `expected` marker;
      # a crash-class failure (vanished artifact, database error)
      # raises `Jobs::JobError` or propagates.
      class ImportJob < Jobs::Handler
        KIND = "domain_import"

        # A job runs once — no automatic retry, per the import/export design.
        def self.default_max_attempts : Int32
          1
        end

        # The completion events are opt-in for webhooks: a binding fires
        # only when its `events` list names the event. A match-all
        # webhook never receives them.
        EVENT_COMPLETED = ::Facet::Event::DOMAIN_IMPORT_COMPLETED
        EVENT_FAILED    = ::Facet::Event::DOMAIN_IMPORT_FAILED

        Log = ::Log.for("facet.domain.portable.import_job")

        # The result marker an expected failure carries. The wait-mode
        # response maps it to a `422`; a failure without the marker is a
        # crash-class failure and answers `500`.
        EXPECTED_RESULT = JSON.parse({"expected" => true}.to_json)

        # One expected failure: a deterministic user-facing rejection.
        # The transaction rolled back — nothing was imported.
        record ExpectedFailure, message : String

        # Executes one claimed import row. Expected failures return a
        # `Failed` result. An unexpected exception propagates and the
        # worker turns it into a `Failed` result (the handler contract).
        def execute(job : Jobs::Job) : Jobs::Handler::Result
          payload = Payload.from_json(job.payload.to_json)

          Database.with_db(:read_write) do |db|
            auth_context = rebuild_context(db, payload)

            bundle_path = spool_bundle(db, payload)
            outcome = apply_bundle(db, payload, auth_context, bundle_path)
            File.delete?(bundle_path)

            case outcome
            in Import::Result
              emit_success(db, payload, job.id, outcome)
              Jobs::Handler::Result.new(
                status: Jobs::Handler::Kind::Succeeded,
                result: result_json(outcome),
              )
            in ExpectedFailure
              emit_failure(db, payload, job.id, outcome)
              Jobs::Handler::Result.new(
                status: Jobs::Handler::Kind::Failed,
                error: outcome.message,
                result: EXPECTED_RESULT,
              )
            end
          end
        end

        # ── Payload ──────────────────────────────────────────────────────

        # The enqueue payload. The bundle artifact is an ownerless row the
        # enqueue route staged. `into` renames the target domain (the
        # bundle's `source_domain` when nil); `merge` selects the upsert
        # branch instead of the fresh-create branch.
        class Payload
          include JSON::Serializable

          getter bundle_artifact_id : String
          getter source_domain : String
          getter into : String?
          getter? merge : Bool
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

        # The write gate re-runs at execution time against the resolved
        # target: update permission on the existing `core.Domain`
        # document for a merge onto a live domain, create permission for
        # a fresh import (also the gate a refused `409` target answers
        # under — the same order the enqueue route holds).
        private def denied_write_message(
          db : DB::Connection,
          auth_context : RBAC::AuthContext,
          target : String,
          merge_onto_existing : Bool,
        ) : String?
          authorized = if merge_onto_existing
                         RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", target, auth_context)
                       else
                         RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth_context)
                       end
          authorized ? nil : "Not authorized to import into domain '#{target}'"
        end

        # ── Bundle application ───────────────────────────────────────────

        # One expected-failure assembly step: read the bundle, gate, then
        # apply. Every rejection here is deterministic — the caller can
        # fix the input and submit again.
        private def apply_bundle(
          db : DB::Connection,
          payload : Payload,
          auth_context : RBAC::AuthContext,
          bundle_path : String,
        ) : Import::Result | ExpectedFailure
          bundle = read_bundle(bundle_path)
          return bundle if bundle.is_a?(ExpectedFailure)

          unless bundle.documents.empty?
            return ExpectedFailure.new(
              "Bundle carries document data — import over HTTP is definition-only"
            )
          end

          target = payload.into || bundle.source_domain
          target_exists = Util::Projections.exists?(db, "core", "Domain", target)
          gate_message = denied_write_message(db, auth_context, target, target_exists && payload.merge?)
          return ExpectedFailure.new(gate_message) if gate_message

          result = Import.call(db, bundle, merge: payload.merge?, into: payload.into)
          case result
          in Facet::ServiceError
            ExpectedFailure.new(result.message)
          in Import::Result
            result
          end
        end

        private def read_bundle(bundle_path : String) : Archive::Bundle | ExpectedFailure
          begin
            Archive.read(bundle_path)
          rescue ex : Archive::Error
            ExpectedFailure.new("Unreadable bundle: #{ex.message}")
          end
        end

        # ── Artifact reads ───────────────────────────────────────────────

        # Spools the stored bundle bytes to a fresh temp file. The
        # extension-less name lets `Archive.read` sniff the container by
        # magic bytes — the enqueue route accepts both zip and tarball.
        # A missing or pruned artifact is a crash-class defect (the
        # grace window outlives the job's queue wait by far).
        private def spool_bundle(db : DB::Connection, payload : Payload) : String
          artifact = Artifact::Store.find_artifact(db, payload.bundle_artifact_id)
          raise Jobs::JobError.new("Import bundle artifact #{payload.bundle_artifact_id} is gone") if artifact.nil? || artifact.deleted_at

          path = File.tempname("facet-domain-import")
          io = Artifact::Uploader.open(artifact.path)
          begin
            File.open(path, "wb") do |f|
              IO.copy(io, f)
            end
          ensure
            io.close
          end
          path
        end

        # ── Outcome assembly ─────────────────────────────────────────────

        # The job result the status route surfaces on success: the
        # import counters. `documents_created` stays 0 — a bundle with a
        # documents section refuses before any write.
        private def result_json(outcome : Import::Result) : JSON::Any
          JSON.parse({
            "domain"                   => outcome.domain,
            "created"                  => outcome.created,
            "doctypes_created"         => outcome.doctypes_created,
            "doctypes_updated"         => outcome.doctypes_updated,
            "doctypes_unchanged"       => outcome.doctypes_unchanged,
            "document_views_created"   => outcome.document_views_created,
            "document_views_updated"   => outcome.document_views_updated,
            "document_views_deleted"   => outcome.document_views_deleted,
            "collection_views_created" => outcome.collection_views_created,
            "collection_views_updated" => outcome.collection_views_updated,
            "documents_created"        => outcome.documents_created,
          }.to_json)
        end

        # ── Event + notification ─────────────────────────────────────────

        # The event publishes on the `core.Domain` stream; the
        # notification points at the target domain's own document
        # (`core.Domain`, id = the domain name). On a failed import the
        # document may not exist — the row keeps the dangling pointer
        # (no document existence check on insert), the click simply
        # does not resolve.
        private def emit_success(
          db : DB::Connection,
          payload : Payload,
          job_id : String,
          outcome : Import::Result,
        ) : Nil
          detail = detail_hash(payload, job_id, outcome.domain)
          detail["created"] = JSON::Any.new(outcome.created)
          detail["doctypes_created"] = JSON::Any.new(outcome.doctypes_created)
          detail["doctypes_updated"] = JSON::Any.new(outcome.doctypes_updated)
          detail["doctypes_unchanged"] = JSON::Any.new(outcome.doctypes_unchanged)

          ImportExport::JobOutcome.emit(
            db,
            domain: "core",
            doc_type: "Domain",
            account_id: payload.account_id,
            job_id: job_id,
            event_name: EVENT_COMPLETED,
            payload_key: "domain_import",
            detail: detail,
            notification: {
              title: "Domain import ready",
              body:  "#{outcome.domain} — #{outcome.doctypes_created} created, " \
                    "#{outcome.doctypes_updated} updated, #{outcome.doctypes_unchanged} unchanged",
              data: JSON.parse({
                "job_id"  => job_id,
                "domain"  => outcome.domain,
                "created" => outcome.created,
                "status"  => "/Api/core/Domain/import_export/#{job_id}",
              }.to_json),
            },
            notification_doc_type: "Domain",
            notification_doc_id: outcome.domain,
          )
        end

        private def emit_failure(
          db : DB::Connection,
          payload : Payload,
          job_id : String,
          failure : ExpectedFailure,
        ) : Nil
          target = failure_target(payload)
          detail = detail_hash(payload, job_id, target)
          detail["error"] = JSON::Any.new(failure.message)

          ImportExport::JobOutcome.emit(
            db,
            domain: "core",
            doc_type: "Domain",
            account_id: payload.account_id,
            job_id: job_id,
            event_name: EVENT_FAILED,
            payload_key: "domain_import",
            detail: detail,
            notification: {
              title: "Domain import failed",
              body:  "Nothing was imported — fix the problem and submit the bundle again: #{failure.message}",
              data:  JSON.parse({
                "job_id" => job_id,
                "domain" => target,
                "error"  => failure.message,
                "status" => "/Api/core/Domain/import_export/#{job_id}",
              }.to_json),
            },
            notification_doc_type: "Domain",
            notification_doc_id: target,
          )
        end

        # The domain name the failure notification points at: the `into`
        # rename when present, else the bundle's `source_domain` — what
        # the caller asked to land, even when nothing did.
        private def failure_target(payload : Payload) : String
          payload.into || payload.source_domain
        end

        private def detail_hash(payload : Payload, job_id : String, domain : String) : Hash(String, JSON::Any)
          {
            "id"     => JSON::Any.new(job_id),
            "domain" => JSON::Any.new(domain),
            "merge"  => JSON::Any.new(payload.merge?),
          } of String => JSON::Any
        end
      end
    end
  end
end
