# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "db"
require "../event"

module Facet
  # Shared lifecycle scaffold for the three event-driven subsystem managers:
  # `Replication::Manager`, `Hooks::Manager`, and `Webhook::Manager`. Each
  # owns a dedicated `Event::Manager` (its own consumer-group prefix), a
  # registry rebuilt from the database, and a handler that processes source
  # events. The base owns the mutex, the started flag, and the start/stop
  # template — including the load-bearing ordering: subscriptions register
  # BEFORE the event manager starts, and the runtime channel providers
  # install AFTER it.
  module Subsystem
    abstract class ManagerBase
      # Declares the process-wide singleton accessors on the including
      # class. Crystal class variables are shared down the inheritance
      # chain, so the base cannot hold `@@instance` itself — each manager
      # type expands its own.
      macro singleton_accessors
        @@instance : {{ @type }}?

        def self.instance : {{ @type }}?
          @@instance
        end

        def self.instance=(mgr : {{ @type }}?) : Nil
          @@instance = mgr
        end

        def self.reset! : Nil
          @@instance = nil
        end
      end

      getter? started : Bool = false

      # Default-initialized here so every subclass constructor satisfies the
      # nilable check; subclasses re-assign the same value in their own
      # `initialize`.
      @mutex : Mutex = Mutex.new

      # Builds the registry from the database, registers subscriptions,
      # starts the event manager, runs the subclass extras, and installs the
      # runtime channel providers. Idempotent — a no-op once started.
      #
      # Ordering is load-bearing: subscriptions must register before
      # `event_manager.start` (the subscribe-before-start rule each manager
      # documents), and the channel providers must install after it.
      def start(db : DB::Connection) : Nil
        @mutex.synchronize do
          return if started?

          build_registry(db)
          register_subscriptions

          event_manager.start
          start_extras

          install_channel_providers

          @started = true
          manager_log.info { "#{label} started" }
        end
      end

      # Signals the event manager to exit. Subclass extras stop first —
      # the hooks scheduler must stop before the event manager drains.
      # Idempotent.
      def stop : Nil
        @mutex.synchronize do
          return unless started?
          stop_extras
          event_manager.stop
          @started = false
          manager_log.info { "#{label} stopped" }
        end
      end

      # ── Subclass contract ────────────────────────────────────────────

      # The subsystem logger and display name feed the lifecycle log lines;
      # the remaining methods are the template steps each manager fills in.
      # Visibility matches the subclass implementations (the `event_manager`
      # getter is public — specs read `event_manager.started?`).
      protected abstract def manager_log : ::Log

      # Human-readable subsystem name for the lifecycle log lines.
      protected abstract def label : String

      abstract def event_manager : Facet::Event::Manager

      # Reads the registry's rows from the database (one eager rebuild).
      protected abstract def build_registry(db : DB::Connection) : Nil

      # Registers the handler on every source stream. Called before
      # `event_manager.start`.
      protected abstract def register_subscriptions : Nil

      # Installs the per-domain (or single-domain) channel providers so
      # each stream subscriber picks up subscription-set changes without a
      # restart. Called after `event_manager.start`.
      protected abstract def install_channel_providers : Nil

      # Per-class extras inside the template. The default is a no-op;
      # `Hooks::Manager` starts/stops its cron scheduler here.
      protected def start_extras : Nil
      end

      protected def stop_extras : Nil
      end

      # Converts a qualified source doctype ("identity.Person") into the
      # resource_type segment used by the event system ("identity:Person"),
      # which becomes the stream key `FACET:RESOURCE:identity:Person`. The
      # rule is identical for the three subsystems.
      protected def source_resource_type(source_doctype : String) : String
        parts = source_doctype.split('.', 2)
        if parts.size == 2
          "#{parts[0]}:#{parts[1]}"
        else
          source_doctype
        end
      end
    end
  end
end
