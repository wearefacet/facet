# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../database"
require "../jobs/handler"
require "../error"
require "./ahead_migration"

module Facet
  module Doctype
    # Background handler for one ahead-migration run.
    #
    # Kind `doctype_migrate_ahead`. A job runs once (`max_attempts: 1`):
    # the operator fixes the input and submits again. The row enqueues with
    # the queue's long lease horizon (`jobs.long_lease_ttl_s`), so a dead
    # worker's row recovers through the lease sweep instead of being
    # requeued mid-run by the 60 s default. Re-running is safe either way —
    # `AheadMigration` skips rows a concurrent write already migrated, and
    # rows that failed once are picked up again by the next run.
    #
    # The payload carries coordinates and the requester's identity for the
    # jobs-table display: `{domain, doc_type, account_id, role_id?}`. The
    # enqueue route runs the authorization gate; execution acts as the
    # system and does not re-run gates.
    class AheadMigrationJob < Jobs::Handler
      KIND = "doctype_migrate_ahead"

      # A job runs once — no automatic retry, per the import/export design.
      def self.default_max_attempts : Int32
        1
      end

      Log = ::Log.for("facet.doctype.ahead_migration_job")

      # Executes one claimed ahead-migration row. A `ServiceError` from the
      # service (unknown doctype, malformed id) is an expected failure; an
      # unexpected exception propagates and the worker turns it into a
      # `Failed` result (the handler contract).
      def execute(job : Jobs::Job) : Jobs::Handler::Result
        payload = Payload.from_json(job.payload.to_json)
        qualified = "#{payload.domain}.#{payload.doc_type}"

        Database.with_db do |db|
          result = AheadMigration.call(db, qualified)

          case result
          in Facet::ServiceError
            Jobs::Handler::Result.new(
              status: Jobs::Handler::Kind::Failed,
              error: result.message,
            )
          in AheadMigration::Result
            stats = result.stats
            Jobs::Handler::Result.new(
              status: Jobs::Handler::Kind::Succeeded,
              result: JSON.parse({
                "total"      => result.total,
                "migrated"   => stats.migrated,
                "superseded" => stats.superseded,
                "skipped"    => stats.skipped,
                "failed"     => stats.failed,
                "batches"    => stats.batches,
                "failed_ids" => stats.failed_ids.first(20),
              }.to_json)
            )
          end
        end
      end

      # The enqueue payload: coordinates and identity references only.
      class Payload
        include JSON::Serializable

        getter domain : String
        getter doc_type : String
        getter account_id : String
        getter role_id : String?
      end
    end
  end
end
