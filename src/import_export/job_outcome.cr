# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "../database"
require "../event/publisher"
require "../notifications/queue"

module Facet
  module ImportExport
    # Shared outcome plumbing for the export/import background handlers.
    #
    # A terminal job publishes one completion event on the source doctype's
    # stream plus one notification to the requesting account:
    #
    # - The event carries `{id, export|import: detail}` — the payload key
    #   (`export` / `import`) is the caller's parameter. `actioner_id` is
    #   the requesting account id; there is no `mutation_id` — a job is not
    #   a mutation. A fanout writes an explicit empty channel list: the
    #   event id is a job id, not a document id, and every document watcher
    #   would drop the frame at its RBAC check anyway. The notification is
    #   the human surface and webhooks the machine one.
    # - The notification is low-quality data (a lost notification is
    #   acceptable; losing an export is not), so a missing account or a
    #   failed insert logs and drops instead of failing the job — the same
    #   contract `Queue.drain` gives the Lua producer.
    #
    # The flush runs after the outcome is assembled; a crash in between
    # loses the event, and the re-execution emits fresh ones (accepted
    # crash-window semantics).
    module JobOutcome
      Log = ::Log.for("facet.import_export.job_outcome")

      # Publishes the completion event and notifies the requesting account.
      #
      # * `payload_key` — `"export"` or `"import"`, the detail key in the
      #   event content (also the source of the notification-drop log label).
      # * `detail` — the outcome detail merged under `payload_key`.
      # * `notification` — a `{title, body, data}` named tuple; `data` is
      #   the notification's rich payload (JSON-safe values, nil allowed).
      # * `notification_doc_type` / `notification_doc_id` — override the
      #   document the notification points at. The default target is the
      #   source doctype's own projection (`core.DocType`, id
      #   `{domain}.{doc_type}`); the portable-domain jobs point at the
      #   `core.Domain` registration instead (doc_type `"Domain"`, id =
      #   the domain name). The target always lives in the `core` domain.
      def self.emit(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        account_id : String,
        job_id : String,
        event_name : String,
        payload_key : String,
        detail : Hash(String, JSON::Any),
        notification : {title: String, body: String, data: JSON::Any},
        notification_doc_type : String? = nil,
        notification_doc_id : String? = nil,
      ) : Nil
        content = {
          "id"        => JSON::Any.new(job_id),
          payload_key => JSON::Any.new(detail),
        } of String => JSON::Any

        Event::Publisher.enqueue(
          domain: domain,
          doc_type: doc_type,
          doc_id: job_id,
          event: event_name,
          actioner_id: account_id,
          payload: content,
          fanout_channels: [] of String,
        )

        notify(db, domain, doc_type, account_id, job_id, event_name, payload_key, notification,
          notification_doc_type, notification_doc_id)

        Event::Publisher.flush
      end

      # The event payload base: coordinates + the job id. Callers overwrite
      # or extend the outcome detail on top.
      def self.detail_hash(domain : String, doc_type : String, format : String, job_id : String) : Hash(String, JSON::Any)
        {
          "id"       => JSON::Any.new(job_id),
          "domain"   => JSON::Any.new(domain),
          "doc_type" => JSON::Any.new(doc_type),
          "format"   => JSON::Any.new(format),
        } of String => JSON::Any
      end

      # One notification to the requesting account. `Notification::Queue`
      # validates synchronously (field shapes, `doc_ref`, account
      # existence); any rejection is a config or data defect, never worth
      # failing a completed job — it logs and drops.
      #
      # The click target resolves at drain time against `core` + the
      # target doctype — the source doctype's own projection
      # (`core.DocType`, id `{domain}.{doc_type}`) by default, or the
      # domain registration (`core.Domain`, id = the domain name) when the
      # caller overrides the doctype. The row inserts with no document
      # existence check — a target that does not exist stays a dangling
      # pointer (the click 404s in the UI), never a job failure.
      private def self.notify(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        account_id : String,
        job_id : String,
        kind : String,
        payload_key : String,
        notification : {title: String, body: String, data: JSON::Any},
        doc_ref_doctype : String?,
        doc_ref_id : String?,
      ) : Nil
        pending = [] of Notification::Pending
        Notification::Queue.enqueue(
          pending, db, account_id, kind, notification[:title],
          body: notification[:body],
          data: notification[:data],
        )
        Notification::Queue.drain(db, pending, "core", doc_ref_doctype || "DocType",
          doc_ref_id || "#{domain}.#{doc_type}")
      rescue ex : Exception
        Log.warn { "#{payload_key.capitalize} notification for job #{job_id} dropped: #{ex.message}" }
      end
    end
  end
end
