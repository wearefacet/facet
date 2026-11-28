# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../database"
require "../jobs/manager"
require "../jobs/queries"
require "../util/script_helpers"
require "./export_job"
require "./import_job"

module Facet
  module ImportExport
    # Job enqueue for the import/export routes. When the jobs manager
    # runs, this module enqueues through it. Without a manager, it inserts
    # the job row directly (enqueue-only mode). Both job kinds enqueue
    # with the queue's long lease horizon: any import or export outlives
    # the worker's short default.
    module JobQueue
      # Enqueues through the jobs manager when the subsystem is up (the
      # manager inserts the row and wakes the running worker when one
      # exists) and falls back to a direct row insert in enqueue-only
      # mode — in test contexts without a manager the job row must still
      # exist, because the status route reads it. `max_attempts: 1` for
      # both kinds: a job runs once, the caller fixes the input and
      # submits again.
      def self.enqueue_job(kind : String, payload : JSON::Any) : String
        lease_ttl_s = Config.instance.jobs.long_lease_ttl_s
        max_attempts = kind == Document::ImportJob::KIND ? Document::ImportJob.default_max_attempts : Document::ExportJob.default_max_attempts

        if mgr = Jobs::Manager.instance
          mgr.enqueue(kind, payload,
            max_attempts: max_attempts,
            backoff: [] of Int32,
            lease_ttl_s: lease_ttl_s,
            max_concurrent: Document::ImportJob.max_concurrent,
          )
        else
          Database.with_db(:read_write) do |db|
            id = Util::ScriptHelpers.ulid
            Jobs::Queries.insert(
              db, id, kind, payload,
              max_attempts: max_attempts,
              backoff: [] of Int32,
              lease_ttl_s: lease_ttl_s,
            )
            id
          end
        end
      end
    end
  end
end
