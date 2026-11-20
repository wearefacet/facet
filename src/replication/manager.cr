# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../event"
require "../config"
require "./manager_base"
require "./registry"
require "./handler"

module Facet
  module Replication
    # Coordinator for the replication subsystem.
    #
    # Owns:
    # - the replication `Event::Manager` instance (separate from the
    #   general-purpose one, but sharing the same Redis config) with
    #   `consumer_group_prefix = "cg:repl:"`,
    # - the `Registry` of replication bindings,
    # - the `Handler` that processes source events.
    #
    # `main.cr` constructs one `Replication::Manager`, calls `start` after the
    # HTTP server boots, and `stop` on shutdown. The `DoctypeCache` Pub/Sub
    # subscriber calls `mark_registry_stale` whenever a `core.DocType` mutation
    # lands — the next reader-driven `ensure_fresh` rebuilds lazily.
    #
    # # ## Singleton
    #
    # `self.instance` / `self.instance=` mirror `Websocket::Manager`. The
    # `DoctypeCache` Pub/Sub subscriber calls
    # `self.instance.try(&.mark_registry_stale)` on every `core.DocType`
    # fanout event so the registry picks up new/removed/changed replication
    # edges on the next read without a server restart. The accessor returns
    # `nil` when no manager is installed (e.g. in test contexts that don't
    # boot the replication subsystem) — callers use `try` to skip safely.
    #
    # # ## Subscription set
    #
    # Subscriptions are computed from the registry's `consumer_domains` and
    # `source_doctypes` maps. For every (consuming_domain, source_doctype)
    # pair, a no-filter `subscribe_resource_stream` registration is added.
    # The `Event::Manager` groups these by consuming domain and creates one
    # `cg:repl:{consuming_domain}` stream subscriber subscribed to all
    # source channels.
    #
    # ## Runtime channel regeneration
    #
    # Each per-domain stream subscriber is given a `channel_provider` that
    # returns the current source-channel set for that consuming domain. On
    # every polling turn the subscriber re-fetches it; if the set differs
    # (new source doctype appeared, or one went away after a schema
    # change), it diffs and applies the change without restarting. Each
    # added channel is also paired with a dispatch registration — the
    # dispatcher only delivers messages to registered subscriptions, so a
    # channel added without one would be read from the stream and silently
    # dropped.
    #
    # ## Subscriber sync
    #
    # A consuming domain that did not exist at boot has no stream subscriber
    # at all, and no provider can be installed on a subscriber that does not
    # exist. A supervised sync fiber wakes every `SUBSCRIBER_SYNC_INTERVAL`,
    # reads the registry's consumer domains (a read rebuilds it lazily when
    # stale), and creates the missing subscriber with its provider and add
    # callback. The subscriber is created with `group_start_id = "0"`, so a
    # late subscriber replays the retained stream and converges.
    class Manager < Subsystem::ManagerBase
      Log = ::Log.for("facet.replication.manager")

      # How often the sync fiber looks for consumer domains that gained
      # bindings after boot. Source-channel additions for domains that
      # already own a subscriber do not wait for this interval — the
      # subscriber's channel provider refreshes on every polling turn.
      SUBSCRIBER_SYNC_INTERVAL = 5.seconds

      singleton_accessors

      getter registry : Registry
      getter event_manager : Facet::Event::Manager

      @sync_stop_channel : Channel(Nil)? = nil

      def initialize(
        config : Facet::Config,
        service_id : String,
        domain_enabled : String -> Bool = ->(d : String) { Facet::Config.instance.domain_enabled?(d) },
      )
        @mutex = Mutex.new
        @registry = Registry.new(domain_enabled)
        # `group_start_id: "0"` — a replication consumer group created after
        # boot replays the retained stream, so a new binding converges from
        # history instead of missing every event emitted before its group
        # existed. Existing groups are unaffected (`BUSYGROUP` is ignored).
        # The handler is convergent (it diffs the source's current projection
        # value), so a replay converges replicas instead of duplicating
        # writes; reentrant replay events are skipped by the existing gate.
        @event_manager = Facet::Event::Manager.new(
          config: config.event,
          service_id: service_id,
          consumer_group_prefix: "cg:repl:",
          group_start_id: "0",
        )
        @handler = Handler.new(@registry)
      end

      # ── Stale tracking ────────────────────────────────────────────────

      # Marks the registry stale without rebuilding. Called by the
      # `DoctypeCache` Pub/Sub subscriber on every `core.DocType` fanout event.
      # The next registry read (`bindings_for`, `source_doctypes`,
      # `consumer_domains`) triggers a lazy rebuild from the DB. No DB access
      # here — pure invalidation, mirroring `DefinitionStore.invalidate`.
      # Coalesces a flock of events into a single on-read rebuild.
      def mark_registry_stale : Nil
        @registry.mark_stale
        Log.debug { "Replication registry marked stale" }
      end

      # Rebuilds the registry from the DB and refreshes every per-domain
      # stream subscriber's subscription set via the channel provider.
      # Eager rebuild — used at `start` and by explicit callers with a held
      # connection. The doctype-cache Pub/Sub path uses `mark_registry_stale`
      # instead; `refresh` is not the event-driven invalidation path.
      def refresh(db : DB::Connection) : Nil
        @mutex.synchronize do
          return unless started?
          @registry.build(db)

          # Re-install wiring to capture new consumer domains as well.
          @registry.consumer_domains.each do |consuming_domain|
            install_domain_wiring(consuming_domain)
          end

          Log.debug { "Replication registry refreshed" }
        end
      end

      # ── Subclass contract ──────────────────────────────────────────────

      protected def manager_log : ::Log
        Log
      end

      protected def label : String
        "Replication manager"
      end

      protected def build_registry(db : DB::Connection) : Nil
        @registry.build(db)
      end

      # Subscribes the handler to every (consuming_domain, source_doctype)
      # pair in the registry. Called before `event_manager.start`.
      protected def register_subscriptions : Nil
        consumer_to_sources = {} of String => Set(String)

        @registry.source_doctypes.each do |source_doctype|
          bindings = @registry.bindings_for(source_doctype)
          bindings.each do |binding|
            (consumer_to_sources[binding.consumer_domain] ||= Set(String).new) << source_doctype
          end
        end

        consumer_to_sources.each do |consuming_domain, sources|
          sources.each do |source_doctype|
            # Channel format: FACET:RESOURCE:{source_domain}:{source_doctype}
            source_resource = source_resource_type(source_doctype)
            @event_manager.subscribe_resource_stream(consuming_domain, source_resource) do |msg|
              @handler.call(msg)
            end
          end
        end
      end

      # ── Subscriber sync ────────────────────────────────────────────

      # Starts the supervised sync fiber. A consuming domain that gains its
      # first binding after boot has no stream subscriber — nothing else
      # creates one, so the sync loop does.
      protected def start_extras : Nil
        @sync_stop_channel = Channel(Nil).new
        Util::FiberSupervisor.supervise("Replication Subscriber Sync") { sync_loop }
      end

      # Stops the sync fiber before the event manager drains (the base-class
      # stop ordering).
      protected def stop_extras : Nil
        @sync_stop_channel.try(&.close)
      end

      # Wakes on `SUBSCRIBER_SYNC_INTERVAL`, reads the registry's consumer
      # domains (the read rebuilds the registry lazily when stale), and
      # creates the stream subscriber + wiring for any domain that lacks it.
      # Idempotent: existing subscribers keep their wiring, registrations are
      # de-duplicated.
      private def sync_loop : Nil
        stop_channel = @sync_stop_channel
        return unless stop_channel

        loop do
          sync_consumer_subscribers
          select
          when stop_channel.receive?
            break
          when timeout(SUBSCRIBER_SYNC_INTERVAL)
            # next tick
          end
        end
      end

      private def sync_consumer_subscribers : Nil
        return unless started?

        @registry.consumer_domains.each do |consuming_domain|
          # `stop` clears the subscriber map after this loop may have read it;
          # the per-domain check keeps a tick that raced the stop sequence
          # from creating a subscriber nobody will ever stop.
          return unless started?
          ensure_consumer_subscriber(consuming_domain)
        end
      rescue e : Exception
        Log.warn { "Replication subscriber sync failed: #{e.class}: #{e.message}" }
      end

      # Makes sure `consuming_domain` owns a stream subscriber with its
      # provider and add callback, and that every source channel the registry
      # currently lists for it has a dispatch registration. A no-op for a
      # domain wired at boot; the missing piece for a domain that gained its
      # first binding after boot.
      private def ensure_consumer_subscriber(consuming_domain : String) : Nil
        channels = source_channels_for(consuming_domain)

        # Dispatch registrations for the channels the subscriber starts with.
        # Later additions are paired inside the add callback.
        channels.each do |channel|
          @event_manager.register_stream_subscription(consuming_domain, resource_type_of(channel)) do |msg|
            @handler.call(msg)
          end
        end

        @event_manager.ensure_stream_subscriber(
          consuming_domain,
          channels,
          provider: channel_provider_for(consuming_domain),
          on_channels_added: channel_add_callback_for(consuming_domain),
        )
        install_domain_wiring(consuming_domain)
      end

      # After start, install the per-domain channel providers so each
      # stream subscriber picks up future subscription-set changes (driven
      # by `refresh`) without restart, and pair every runtime-added channel
      # with a dispatch registration.
      protected def install_channel_providers : Nil
        @registry.consumer_domains.each do |consuming_domain|
          install_domain_wiring(consuming_domain)
        end
      end

      private def install_domain_wiring(consuming_domain : String) : Nil
        @event_manager.set_channel_provider(consuming_domain, channel_provider_for(consuming_domain))
        @event_manager.set_channel_add_callback(consuming_domain, channel_add_callback_for(consuming_domain))
      end

      # Source channels (base form, `FACET:RESOURCE:{domain}:{doctype}`) the
      # registry currently lists for `consuming_domain`. Mirrors the provider
      # body; kept separate so `ensure_consumer_subscriber` can subscribe the
      # initial set before the subscriber starts.
      private def source_channels_for(consuming_domain : String) : Array(String)
        channels = [] of String
        @registry.source_doctypes.each do |source_doctype|
          bindings = @registry.bindings_for(source_doctype)
          next unless bindings.any? { |b| b.consumer_domain == consuming_domain }

          channels << "FACET:RESOURCE:#{source_resource_type(source_doctype)}"
        end
        channels.uniq!
      end

      # ── Private ──────────────────────────────────────────────────────

      # Returns a callable that yields the *current* source-channel set
      # for `consuming_domain`. The stream subscriber consults it on each
      # polling turn to detect schema changes (new/removed source doctypes).
      private def channel_provider_for(consuming_domain : String) : Proc(Array(String))
        -> do
          source_channels_for(consuming_domain)
        end
      end

      # Returns a callable invoked with the channels the subscriber adds at
      # runtime. Each addition gets its dispatch registration — without it
      # the messages on the new channel are read and silently dropped.
      private def channel_add_callback_for(consuming_domain : String) : Proc(Array(String), Nil)
        ->(added : Array(String)) do
          added.each do |channel|
            @event_manager.register_stream_subscription(consuming_domain, resource_type_of(channel)) do |msg|
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
    end
  end
end
