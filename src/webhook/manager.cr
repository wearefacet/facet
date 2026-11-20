# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "mutex"
require "../event"
require "../jobs/manager"
require "../config"
require "../replication/manager_base"
require "./registry"
require "./handler"
require "./dispatcher"

module Facet
  module Webhook
    # Process-wide owner of the webhook registry, the dedicated
    # `Event::Manager`, and the `Handler` that enqueues `webhook_delivery`
    # jobs from source-mutation events.
    #
    # ## Singleton
    #
    # `self.instance` / `self.instance=` / `self.reset!` mirror
    # `Hooks::Manager`. The `DoctypeCache` Pub/Sub subscriber calls
    # `self.instance.try(&.mark_registry_stale)` on every
    # `fanout:core.Webhook:*` event, so the registry picks up new, changed,
    # and removed webhooks on the next read without a restart. The accessor
    # returns `nil` when no manager is installed (e.g. in test contexts that
    # do not boot the webhook subsystem) — callers use `try` to skip safely.
    #
    # ## Event manager
    #
    # The webhook `Event::Manager` is separate from the general-purpose
    # manager and from hooks/replication, sharing the same Redis config, with
    # `consumer_group_prefix = "cg:webhooks:"`. The `event_manager`
    # constructor argument lets tests inject a stub that does not touch Redis;
    # production leaves it `nil` and a real manager is constructed here.
    #
    # ## Subscription set
    #
    # Webhooks live in `core` but consume the streams of their **source**
    # doctypes — a webhook on `accountancy.Contract` subscribes to the
    # `FACET:RESOURCE:accountancy:Contract` stream. All subscriptions are
    # grouped under the single owning domain `core`, so one consumer group
    # (`cg:webhooks:core`) serves every source stream.
    #
    # The `core` stream subscriber exists from boot, even when the registry
    # loads zero webhooks. `install_channel_providers` creates it through
    # `Event::Manager#ensure_stream_subscriber`, with the channel provider
    # and the channel-add callback installed before the polling fiber
    # starts. The provider re-queries the registry on each stream poll, so
    # a webhook created after boot arms live delivery on the next poll —
    # no restart. The add callback pairs every channel the provider adds
    # at runtime with a dispatch registration. Without it, messages on the
    # new channel are read from the stream and then dropped: the
    # dispatcher only delivers to registered subscriptions.
    #
    # ## Jobs dispatch registration
    #
    # `register_handler` puts the `webhook_delivery → Webhook::Dispatcher`
    # entry into the `Jobs::Manager` handlers map **before**
    # `Jobs::Manager.start` — the worker snapshots the map at start, so the
    # kind must be dispatchable (and call-logged) from the first claim.
    class Manager < Subsystem::ManagerBase
      Log = ::Log.for("facet.webhook.manager")

      # The single owning domain for every subscription: webhooks are
      # `core` documents, so one consumer group consumes all source
      # doctype streams.
      OWNING_DOMAIN = "core"

      singleton_accessors

      getter registry : Registry
      getter event_manager : Facet::Event::Manager

      def initialize(
        config : Facet::Config = Facet::Config.instance,
        # Random per manager — the server boot passes an explicit
        # `Facet::Service.service_id("facet-webhook")`; this default only
        # serves out-of-boot constructions (specs, tools), where each
        # manager must not share a lock/liveness identity with another.
        service_id : String = Random.new.hex(8),
        domain_enabled : String -> Bool = ->(d : String) { Facet::Config.instance.domain_enabled?(d) },
        event_manager : Facet::Event::Manager? = nil,
      )
        @mutex = Mutex.new
        @registry = Registry.new(domain_enabled)
        @event_manager = event_manager || Facet::Event::Manager.new(
          config: config.event,
          service_id: service_id,
          consumer_group_prefix: "cg:webhooks:",
        )
        @handler = Handler.new(@registry)
      end

      # ── Stale tracking ────────────────────────────────────────────────

      # Marks the registry stale without rebuilding. The next registry read
      # (`webhooks_for`, `source_selectors`) triggers a lazy rebuild from the
      # DB. No DB access here — pure invalidation.
      def mark_registry_stale : Nil
        @registry.mark_stale
        Log.debug { "Webhook registry marked stale" }
      end

      # Eager rebuild — used at `start` and by explicit callers with a held
      # connection. The doctype-cache Pub/Sub path uses
      # `mark_registry_stale` instead; this is not the event-driven
      # invalidation path.
      def build(db : DB::Connection) : Nil
        @registry.build(db)
      end

      # Registers the delivery dispatcher into the `Jobs::Manager` map.
      # Must run before `Jobs::Manager.start` — the worker snapshots the
      # map at start, so `webhook_delivery` rows are dispatchable (and
      # call-logged through the dispatcher's own attempt hooks) from the
      # first claim.
      def register_handler(jobs_manager : Facet::Jobs::Manager) : Nil
        jobs_manager.register_handler(Facet::Webhook::Dispatcher::KIND, Facet::Webhook::Dispatcher)
      end

      # ── Subclass contract ──────────────────────────────────────────────

      protected def manager_log : ::Log
        Log
      end

      protected def label : String
        "Webhook manager"
      end

      protected def build_registry(db : DB::Connection) : Nil
        @registry.build(db)
      end

      # Subscribes the handler to every source doctype's stream. All
      # subscriptions carry the owning domain `core`, so they land in the
      # single `cg:webhooks:core` consumer group. Called before
      # `event_manager.start`. Source channels that appear after boot are
      # paired with dispatch registrations inside the channel-add callback.
      protected def register_subscriptions : Nil
        @registry.source_selectors.each do |source_doctype|
          @event_manager.subscribe_resource_stream(OWNING_DOMAIN, source_resource_type(source_doctype)) do |msg|
            @handler.call(msg)
          end
        end
      end

      # Makes sure the owning domain owns a live stream subscriber wired
      # with the channel provider and the channel-add callback. Two boot
      # shapes:
      #
      # - Webhooks present at boot — `event_manager.start` created the
      #   subscriber from the pre-start registrations. `ensure` is a no-op;
      #   the wiring installs on the existing subscriber.
      # - Zero webhooks at boot — no subscriber exists, and
      #   `set_channel_provider` cannot reach one that does not exist.
      #   `ensure_core_subscriber` creates it here; the first polling turn
      #   then picks up the first webhook's source channel. No restart.
      protected def install_channel_providers : Nil
        ensure_core_subscriber
        @event_manager.set_channel_provider(OWNING_DOMAIN, channel_provider_for)
        @event_manager.set_channel_add_callback(OWNING_DOMAIN, channel_add_callback_for)
      end

      # ── Private ──────────────────────────────────────────────────────

      # Registers a dispatch registration for every source channel the
      # registry currently lists, then creates the `core` stream subscriber
      # when `event_manager.start` did not (zero webhooks at boot). The
      # registrations de-duplicate on (domain, channel), so the pre-start
      # set from `register_subscriptions` is never doubled. Later additions
      # are paired inside the channel-add callback.
      private def ensure_core_subscriber : Nil
        channels = source_channels
        channels.each do |channel|
          @event_manager.register_stream_subscription(OWNING_DOMAIN, resource_type_of(channel)) do |msg|
            @handler.call(msg)
          end
        end

        @event_manager.ensure_stream_subscriber(
          OWNING_DOMAIN,
          channels,
          provider: channel_provider_for,
          on_channels_added: channel_add_callback_for,
        )
      end

      # Source channels (base form, `FACET:RESOURCE:{domain}:{doctype}`)
      # the registry currently lists. Mirrors the provider body; kept
      # separate so `ensure_core_subscriber` subscribes the initial set
      # before the subscriber starts.
      private def source_channels : Array(String)
        channels = [] of String
        @registry.source_selectors.each do |source_doctype|
          channels << "FACET:RESOURCE:#{source_resource_type(source_doctype)}"
        end
        channels.uniq!
      end

      # Returns a callable that yields the *current* source-channel set.
      # The stream subscriber consults it on each polling turn to detect
      # registry changes (new/removed source doctypes) without a restart.
      private def channel_provider_for : Proc(Array(String))
        -> { source_channels }
      end

      # Returns a callable invoked with the channels the subscriber adds
      # at runtime. Each addition gets its dispatch registration — without
      # it the messages on the new channel are read and silently dropped.
      private def channel_add_callback_for : Proc(Array(String), Nil)
        ->(added : Array(String)) do
          added.each do |channel|
            @event_manager.register_stream_subscription(OWNING_DOMAIN, resource_type_of(channel)) do |msg|
              @handler.call(msg)
            end
          end
        end
      end

      # Strips the stream-key prefix from a base channel
      # (`FACET:RESOURCE:crm:Person` → `crm:Person`), the resource-type
      # form `register_stream_subscription` expects.
      private def resource_type_of(channel : String) : String
        prefix = "FACET:RESOURCE:"
        channel.starts_with?(prefix) ? channel[prefix.size..] : channel
      end

      # Hold the handler instance reachable past construction (mirrors
      # Hooks::Manager).
      @handler : Handler
    end
  end
end
