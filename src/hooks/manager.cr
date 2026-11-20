# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../event"
require "../config"
require "../replication/manager_base"
require "./registry"
require "./handler"
require "./scheduler"

module Facet
  module Hooks
    # Coordinator for the hooks subsystem.
    #
    # Owns:
    # - the hooks `Event::Manager` instance (separate from both the
    #   general-purpose manager and the replication manager, sharing the
    #   same Redis config) with `consumer_group_prefix = "cg:hooks:"`,
    # - the `Registry` of `event` hook bindings,
    # - the `Handler` that processes source events,
    # - the `Scheduler` that fires `schedule` hooks on a cron cadence.
    #
    # `main.cr` constructs one `Hooks::Manager`, calls `start` after the
    # HTTP server boots, and `stop` on shutdown. The `DoctypeCache` Pub/Sub
    # subscriber calls `mark_registry_stale` whenever a `core.Domain`
    # mutation lands — the next reader-driven `ensure_fresh` rebuilds
    # lazily.
    #
    # ## Singleton
    #
    # `self.instance` / `self.instance=` mirror `Replication::Manager`. The
    # `DoctypeCache` Pub/Sub subscriber calls
    # `self.instance.try(&.mark_registry_stale)` on every `core.Domain`
    # fanout event so the registry picks up new/removed/changed hooks on
    # the next read without a server restart. The accessor returns `nil`
    # when no manager is installed (e.g. in test contexts that don't boot
    # the hooks subsystem) — callers use `try` to skip safely.
    #
    # ## Subscription set
    #
    # Subscriptions are computed from the registry's `source_selectors`:
    # for every source selector, a no-filter
    # `subscribe_resource_stream` registration is added. The `Event::Manager`
    # groups these by owning domain (the domain whose projection declares
    # the hook) and creates one `cg:hooks:{owning_domain}` stream
    # subscriber subscribed to all source channels. See `Hooks::Registry`
    # doc for the source-selector key shape.
    #
    # The `Scheduler` re-reads `Registry#schedule_hooks` on each poll, so it
    # picks up new/removed/changed schedule hooks through the same lazy
    # rebuild path — no separate invalidation path is needed.
    #
    # ## Subscriber sync
    #
    # An owning domain that had no hooks at boot has no stream subscriber,
    # and `set_channel_provider` cannot reach one that does not exist. A
    # supervised sync fiber wakes every `SUBSCRIBER_SYNC_INTERVAL`, reads
    # the registry's owning domains (a read rebuilds it lazily when stale),
    # and creates the missing subscriber with its provider and add callback.
    # The subscriber is built with the manager's `group_start_id` (`$`), so
    # it sees only events published from its creation onward — hooks keep
    # the no-replay stance (a replay would re-fire automations).
    #
    # OpenTelemetry spans are opened inside `Hooks::Executor#run_event` /
    # `#run_schedule` (one span per hook fire, tagged `hooks.domain` /
    # `hooks.id` / `hooks.kind` / `hooks.origin` / `hooks.actor_id`). The
    # manager itself is not spanned — it only owns lifecycle.
    class Manager < Subsystem::ManagerBase
      Log = ::Log.for("facet.hooks.manager")

      # How often the sync fiber looks for owning domains that gained their
      # first hook after boot. Source-channel additions for domains that
      # already own a subscriber do not wait for this interval — the
      # subscriber's channel provider refreshes on every polling turn.
      SUBSCRIBER_SYNC_INTERVAL = 5.seconds

      singleton_accessors

      getter registry : Registry
      getter event_manager : Facet::Event::Manager
      getter scheduler : Scheduler

      @sync_stop_channel : Channel(Nil)? = nil

      def initialize(
        config : Facet::Config,
        service_id : String,
        domain_enabled : String -> Bool = ->(d : String) { Facet::Config.instance.domain_enabled?(d) },
        event_manager : Facet::Event::Manager? = nil,
        subscriber_sync_interval : Time::Span = SUBSCRIBER_SYNC_INTERVAL,
      )
        @mutex = Mutex.new
        hooks_cfg = config.hooks
        @registry = Registry.new(domain_enabled)
        # `event_manager` injection lets tests substitute a stub that does
        # not touch Redis; production leaves it `nil` and a real manager
        # is constructed here.
        @event_manager = event_manager || Facet::Event::Manager.new(
          config: config.event,
          service_id: service_id,
          consumer_group_prefix: "cg:hooks:",
        )
        @handler = Handler.new(@registry)
        @scheduler = Scheduler.new(
          registry: @registry,
          redis_url: config.event.url,
          service_id: service_id,
          poll_interval_s: hooks_cfg.scheduler_poll_interval_s,
          lease_ttl_s: hooks_cfg.lease_ttl_s,
        )
        @subscriber_sync_interval = subscriber_sync_interval
      end

      # ── Stale tracking ────────────────────────────────────────────────

      # Marks the registry stale without rebuilding. Called by the
      # `DoctypeCache` Pub/Sub subscriber on every `core.Domain` fanout event.
      # The next registry read (`hooks_for`, `source_selectors`)
      # triggers a lazy rebuild from the DB. No DB access here — pure
      # invalidation, mirroring `Replication::Manager#mark_registry_stale`.
      def mark_registry_stale : Nil
        @registry.mark_stale
        Log.debug { "Hooks registry marked stale" }
      end

      # Eager rebuild — used at `start` and by explicit callers with a held
      # connection. The doctype-cache Pub/Sub path uses
      # `mark_registry_stale` instead; this is not the event-driven
      # invalidation path.
      def build(db : DB::Connection) : Nil
        @registry.build(db)
      end

      # ── Subclass contract ──────────────────────────────────────────────

      protected def manager_log : ::Log
        Log
      end

      protected def label : String
        "Hooks manager"
      end

      protected def build_registry(db : DB::Connection) : Nil
        @registry.build(db)
      end

      # Subscribes the handler to every (owning_domain, source_doctype)
      # pair in the registry. Called before `event_manager.start`.
      protected def register_subscriptions : Nil
        owner_to_sources = {} of String => Set(String)

        @registry.source_selectors.each do |source_doctype|
          hooks = @registry.hooks_for(source_doctype)
          hooks.each do |hook|
            next if hook.owning_domain.nil?
            (owner_to_sources[hook.owning_domain.as(String)] ||= Set(String).new) << source_resource_type(source_doctype)
          end
        end

        owner_to_sources.each do |owning_domain, sources|
          sources.each do |resource_type|
            @event_manager.subscribe_resource_stream(owning_domain, resource_type) do |msg|
              @handler.call(msg)
            end
          end
        end
      end

      # The scheduler and the subscriber-sync fiber are start/stop extras of
      # the hooks subsystem: they start after the event manager and stop
      # before it (template contract).
      protected def start_extras : Nil
        @scheduler.start
        @sync_stop_channel = Channel(Nil).new
        Util::FiberSupervisor.supervise("Hooks Subscriber Sync") { sync_loop }
      end

      protected def stop_extras : Nil
        @sync_stop_channel.try(&.close)
        @scheduler.stop
      end

      # ── Subscriber sync ─────────────────────────────────────────────

      # Wakes on `subscriber_sync_interval`, reads the registry's owning
      # domains (the read rebuilds the registry lazily when stale), and
      # creates the stream subscriber + wiring for any domain that lacks
      # one. Idempotent: existing subscribers keep their wiring,
      # registrations are de-duplicated.
      private def sync_loop : Nil
        stop_channel = @sync_stop_channel
        return unless stop_channel

        loop do
          sync_owning_domain_subscribers
          select
          when stop_channel.receive?
            break
          when timeout(@subscriber_sync_interval)
            # next tick
          end
        end
      end

      private def sync_owning_domain_subscribers : Nil
        return unless started?

        owning_domains.each do |owning_domain|
          # `stop` clears the subscriber map after this loop may have read
          # it; the per-domain check keeps a tick that raced the stop
          # sequence from creating a subscriber nobody will ever stop.
          return unless started?
          ensure_owning_domain_subscriber(owning_domain)
        end
      rescue e : Exception
        Log.warn { "Hooks subscriber sync failed: #{e.class}: #{e.message}" }
      end

      # Makes sure `owning_domain` owns a stream subscriber with its
      # provider and add callback, and that every source channel the
      # registry currently lists for it has a dispatch registration. A
      # no-op for a domain wired at boot; the missing piece for a domain
      # that gained its first hook after boot.
      private def ensure_owning_domain_subscriber(owning_domain : String) : Nil
        channels = source_channels_for(owning_domain)

        # Dispatch registrations for the channels the subscriber starts
        # with. Boot-time registrations are de-duplicated by the
        # (domain, channel) pair; later additions are paired inside the
        # add callback.
        channels.each do |channel|
          @event_manager.register_stream_subscription(owning_domain, resource_type_of(channel)) do |msg|
            @handler.call(msg)
          end
        end

        @event_manager.ensure_stream_subscriber(
          owning_domain,
          channels,
          provider: channel_provider_for(owning_domain),
          on_channels_added: channel_add_callback_for(owning_domain),
        )
        install_domain_wiring(owning_domain)
      end

      # After start, install the per-owning-domain channel providers and
      # add callbacks so each stream subscriber picks up future
      # subscription-set changes (driven by `refresh`) without restart.
      protected def install_channel_providers : Nil
        owning_domains.each do |owning_domain|
          install_domain_wiring(owning_domain)
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # Returns the distinct set of owning domains across all indexed
      # hooks. Used at `start` to install channel providers per domain.
      private def owning_domains : Array(String)
        seen = Set(String).new
        @registry.source_selectors.each do |source_doctype|
          @registry.hooks_for(source_doctype).each do |hook|
            next if hook.owning_domain.nil?
            seen << hook.owning_domain.as(String)
          end
        end
        seen.to_a
      end

      # Returns a callable that yields the *current* source-channel set
      # for `owning_domain`. The stream subscriber consults it on each
      # polling turn to detect registry changes (new/removed source
      # doctypes) without a restart.
      private def channel_provider_for(owning_domain : String) : Proc(Array(String))
        -> { source_channels_for(owning_domain) }
      end

      # Installs the channel provider and the channel-add callback on the
      # stream subscriber for `owning_domain` (a no-op when the domain has
      # no subscriber yet — the sync fiber creates it).
      private def install_domain_wiring(owning_domain : String) : Nil
        @event_manager.set_channel_provider(owning_domain, channel_provider_for(owning_domain))
        @event_manager.set_channel_add_callback(owning_domain, channel_add_callback_for(owning_domain))
      end

      # Source channels (base form, `FACET:RESOURCE:{domain}:{doctype}`) the
      # registry currently lists for `owning_domain`. Mirrors the provider
      # body; kept separate so `ensure_owning_domain_subscriber` can
      # subscribe the initial set before the subscriber starts.
      private def source_channels_for(owning_domain : String) : Array(String)
        channels = [] of String
        @registry.source_selectors.each do |source_doctype|
          hooks = @registry.hooks_for(source_doctype)
          next unless hooks.any?(&.owning_domain.==(owning_domain))
          channels << "FACET:RESOURCE:#{source_resource_type(source_doctype)}"
        end
        channels.uniq!
      end

      # Returns a callable invoked with the channels the subscriber adds at
      # runtime. Each addition gets its dispatch registration — without it
      # the messages on the new channel are read from the stream and then
      # silently dropped.
      private def channel_add_callback_for(owning_domain : String) : Proc(Array(String), Nil)
        ->(added : Array(String)) do
          added.each do |channel|
            @event_manager.register_stream_subscription(owning_domain, resource_type_of(channel)) do |msg|
              @handler.call(msg)
            end
          end
        end
      end

      # Strips the stream-key prefix from a base channel
      # (`FACET:RESOURCE:crm:Person` → `crm:Person`), the resource-type form
      # `register_stream_subscription` expects.
      private def resource_type_of(channel : String) : String
        prefix = "FACET:RESOURCE:"
        channel.starts_with?(prefix) ? channel[prefix.size..] : channel
      end

      # Hold the handler instance reachable past construction (mirrors
      # replication's shape).
      @handler : Handler
      @subscriber_sync_interval : Time::Span
    end
  end
end
