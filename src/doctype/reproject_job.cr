# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../database"
require "../jobs/handler"
require "../error"
require "./reproject"

module Facet
  module Doctype
    # Background handler for one doctype re-projection run.
    #
    # Kind `doctype_reproject`. A job runs once (`max_attempts: 1`): the
    # operator fixes the input and submits again. The row enqueues with the
    # queue's long lease horizon (`jobs.long_lease_ttl_s`), so a dead
    # worker's row recovers through the lease sweep instead of being
    # requeued mid-run by the 60 s default. Re-running is safe either way —
    # `Reproject`'s optimistic state check skips already re-projected rows.
    #
    # The payload carries coordinates and the requester's identity for the
    # jobs-table display: `{domain, doc_type, account_id, role_id?}`. The
    # enqueue route runs the authorization gate; execution acts as the
    # system actioner (`system:reproject`) and does not re-run gates.
    #
    # The in-server worker count is a fixed small constant. `Reproject`'s
    # producer and worker fibers each check out their own pooled
    # connection, and the server pool is shared with HTTP traffic — the
    # CLI remains the high-throughput path for large corpora.
    class ReprojectJob < Jobs::Handler
      KIND = "doctype_reproject"

      # Producer + workers checkouts. Held inside the server pool, next to
      # HTTP traffic — two workers keep the footprint at four connections.
      SERVER_WORKERS     = 2
      SERVER_BATCH_SIZE  = Reproject::DEFAULT_BATCH_SIZE
      SERVER_CHANNEL_CAP = Reproject::DEFAULT_CHANNEL_CAP

      # A job runs once — no automatic retry, per the import/export design.
      def self.default_max_attempts : Int32
        1
      end

      Log = ::Log.for("facet.doctype.reproject_job")

      # Executes one claimed re-projection row. A `ServiceError` from the
      # service (unknown doctype, malformed id) is an expected failure; an
      # unexpected exception propagates and the worker turns it into a
      # `Failed` result (the handler contract).
      def execute(job : Jobs::Job) : Jobs::Handler::Result
        payload = Payload.from_json(job.payload.to_json)
        qualified = "#{payload.domain}.#{payload.doc_type}"

        Database.with_db(:read_write) do |db|
          result = Reproject.call(
            db, qualified,
            batch_size: SERVER_BATCH_SIZE,
            workers: SERVER_WORKERS,
            channel_cap: SERVER_CHANNEL_CAP,
          ) { |_r| }

          case result
          in Facet::ServiceError
            Jobs::Handler::Result.new(
              status: Jobs::Handler::Kind::Failed,
              error: result.message,
            )
          in Reproject::Result
            stats = result.stats
            Jobs::Handler::Result.new(
              status: Jobs::Handler::Kind::Succeeded,
              result: JSON.parse({
                "total"      => result.total,
                "processed"  => stats.processed.get,
                "superseded" => stats.superseded.get,
                "skipped"    => stats.skipped.get,
                "failed"     => stats.failed.get,
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
