# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "redis"

module Facet
  module Event
    # Event name published when a notification is created. Past tense,
    # like `created` / `updated` / `deleted`.
    NOTIFIED = "notified"

    # The four job-lifecycle event names of the import/export concern.
    # Past tense, like the mutation events. They publish on the source
    # doctype's stream, and they are **opt-in for webhooks**: a binding
    # fires only when its `events` list names the event explicitly — a
    # match-all webhook never signed up for job lifecycle noise (the same
    # rule the `notified` event follows).
    EXPORT_COMPLETED = "export_completed"
    EXPORT_FAILED    = "export_failed"
    IMPORT_COMPLETED = "import_completed"
    IMPORT_FAILED    = "import_failed"

    # The four job-lifecycle event names of the portable-domain concern.
    # Same contract as the document import/export events: past tense,
    # published on the `core.Domain` stream with the job id as the
    # document id, opt-in for webhooks.
    DOMAIN_EXPORT_COMPLETED = "domain_export_completed"
    DOMAIN_EXPORT_FAILED    = "domain_export_failed"
    DOMAIN_IMPORT_COMPLETED = "domain_import_completed"
    DOMAIN_IMPORT_FAILED    = "domain_import_failed"

    JOB_LIFECYCLE_EVENTS = Set{EXPORT_COMPLETED, EXPORT_FAILED, IMPORT_COMPLETED, IMPORT_FAILED,
                               DOMAIN_EXPORT_COMPLETED, DOMAIN_EXPORT_FAILED,
                               DOMAIN_IMPORT_COMPLETED, DOMAIN_IMPORT_FAILED}
    # The aggregate child-change event. Published keyed to the **parent**
    # document (headers doc_type/doc_id = parent; payload top-level `id` =
    # parent id — the webhook/hook source-resolution contract) whenever an
    # owned child is created, updated, or deleted. The payload is an
    # envelope `{id, action, child, parent}`, not a document body. It is
    # **opt-in for webhooks** like `notified`: a binding fires only when
    # its `events` list names it — a match-all webhook never signed up for
    # aggregate child frames.
    CHILD_CHANGED = "child_changed"

    # ── Standard mutation + repair event names ──────────────────────

    # The event name published for each standard document mutation.
    # `Document::Create`, `Document::Update`, and `Document::Delete` publish
    # them, and `Cron::WebhookReconcile.derive_event_name` maps the mutation
    # action to the same constants — the webhook authoring vocabulary below
    # reads them, so the list cannot drift from the derivation.
    CREATED = "created"
    UPDATED = "updated"
    DELETED = "deleted"

    # The event names published when a lazy migration replays a document
    # (`migrated`) and when a rollback restores or re-deletes history
    # (`rolled_back`). Both ride the source doctype's stream like the
    # mutation verbs, and `Cron::WebhookReconcile.derive_event_name` derives
    # them from the `snapshot` mutation rows.
    MIGRATED    = "migrated"
    ROLLED_BACK = "rolled_back"

    # The closed event-name vocabulary a `core.Webhook` `events` list may
    # name at authoring time (B-152). The seed's Lua hooks check every
    # entry against this list through the `util.webhook_event_names`
    # binding and reject an unknown name with 422 — a name outside the list
    # would create a binding that silently never fires. Named-action event
    # names are dynamic per doctype and are not part of this list.
    WEBHOOK_EVENT_NAMES = [CREATED, UPDATED, DELETED, MIGRATED, ROLLED_BACK,
                           NOTIFIED, CHILD_CHANGED] + JOB_LIFECYCLE_EVENTS.to_a

    # True when the name is one of the opt-in event classes: the private
    # notification event, the aggregate child-change event, and the four
    # job-lifecycle events. This decides the webhook **binding filter**
    # (`Webhook::Handler.binding_matches?` — a binding fires solely when
    # its `events` list names the event) and the hook payload pass-through
    # (`Hooks::Handler` delivers opt-in payloads verbatim; document events
    # get the live body). Replay does not branch here; it
    # re-runs the `Webhook::AuthCheck` gate against the original source.
    def self.opt_in_event?(event_name : String) : Bool
      event_name == NOTIFIED || event_name == CHILD_CHANGED || JOB_LIFECYCLE_EVENTS.includes?(event_name)
    end

    # True when the event's subject is a background job, not a projection
    # row — the id names a `background_jobs` row, so a projection-read
    # gate cannot apply and the doctype-definition gate replaces it.
    def self.job_lifecycle_event?(event_name : String) : Bool
      JOB_LIFECYCLE_EVENTS.includes?(event_name)
    end

    # The per-account fanout channel for notification events. The account
    # id is part of the channel name, so a WebSocket client reaches only
    # its own channel — the subscription path never names an account.
    def self.notifications_fanout_channel(account_id : String) : String
      "fanout:notifications:#{account_id}"
    end
  end
end

require "./event/config"
require "./event/message"
require "./event/manager"
require "./event/in_process_manager"
require "./event/publisher"
require "./event/loss"
require "./event/consumer_health"
require "./event/subscriber/base"
require "./event/subscriber/stream"
require "./event/subscriber/fanout"
require "./event/subscriber/doctype_cache"
require "./event/subscriber/app_cache"
require "./event/subscriber/role_cache"
