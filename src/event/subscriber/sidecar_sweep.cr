# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "../message"
require "../../database"
require "../../doctype/definition_store"
require "../../document/delete"
require "../../rbac"
require "../../util/sidecars"

module Facet
  module Event
    module Subscriber
      # Event-driven orphan sweep for sidecar records.
      #
      # Soft-deletes every sidecar record whose `target` reference points at a
      # host document that was just soft-deleted. Sidecar records are linked
      # to their host through a `reference` field (`target` by default) on
      # the sidecar, NOT through the composition tree (`parent_id`). The
      # composition cascade in `Document::Delete` only tombstones owned
      # children — sidecar records survive a host delete unless this sweep
      # tombstones them.
      #
      # ## Architecture
      #
      # Two parts live in this file:
      #
      # - `SidecarSweep::Handler` — the per-message logic. Resolves the
      #   deleted host identity from the event headers + payload, loads the
      #   host doctype's `sidecars` map, and tombstones every attached
      #   sidecar record through `Document::Delete`. Separated from the
      #   manager so it can be unit-tested with a synthetic `Event::Message`
      #   (mirrors the `Replication::Handler` / `Replication::Manager`
      #   split).
      # - `SidecarSweep::Manager` — owns its own `Event::Manager` instance
      #   (consumer-group prefix `cg:sidecar:`) so the sweep consumer group
      #   is isolated from the general-purpose and replication consumers on
      #   the same host-doctype streams. Subscribes to the `deleted` event
      #   on every host doctype that declares a `sidecars` map. Installed
      #   by `main.cr` before `HTTP::Server.routes`.
      #
      # The host-doctype set is rebuilt lazily: a `channel_provider`
      # re-queries it on every stream poll (see
      # `Event::Subscriber::Stream#channel_provider=`), so a doctype
      # create/update that adds or removes a `sidecars` entry is picked up
      # on the next polling turn — no restart, no separate invalidation
      # wiring. This is the same approach `Replication::Manager` uses for
      # source-doctype set changes, and it does NOT introduce a
      # `DoctypeCache`-style cache (per the sidecar plan's concern #5:
      # query, do not cache speculatively).
      #
      # ## Idempotency
      #
      # `Document::Delete.call` returns `410 Gone` ("already deleted") when
      # a document is already tombstoned. The sweep treats that as success —
      # a redelivered `deleted` event must not fail. See
      # `Sidecars.tombstone_by_target`.
      #
      # ## Reentrancy
      #
      # The tombstone deletes the sweep emits are issued with the system
      # auth context and `actioner_id = "system:sidecar-sweep"`. They
      # enqueue `deleted` events on the sidecar doctype streams; a
      # downstream replication handler (if one were ever bound to
      # `core.Comment`) would see them and must skip. The replication
      # handler gates on `headers["reentrant"]`; the sweep's deletes are
      # NOT tagged `reentrant: true` here (they originate from the sweep,
      # not from a replication pull), but they ARE attributed to
      # `system:sidecar-sweep` so audit consumers can distinguish them.
      module SidecarSweep
        # The per-message sweep handler.
        class Handler
          Log = ::Log.for("facet.event.subscriber.sidecar_sweep.handler")

          # Entry point — invoked by `Event::Manager` for each `deleted`
          # message on a host-doctype stream. Tombstones every sidecar
          # record whose `target` reference equals the deleted host's
          # qualified id.
          def call(msg : Facet::Event::Message) : Nil
            domain = msg.headers["domain"]?.try(&.as_s?)
            doctype = msg.headers["doc_type"]?.try(&.as_s?)
            host_id = msg.content["id"]?.try(&.as_s?)

            if domain.nil? || doctype.nil? || host_id.nil?
              Log.warn { "Sweep skipping malformed deleted event: domain=#{domain} doctype=#{doctype} id=#{host_id}" }
              return
            end

            host_qualified = "#{domain}.#{doctype}.#{host_id}"

            Facet::Database.with_db(:read_write) do |db|
              sweep_host(db, domain.as(String), doctype.as(String), host_qualified)
            end

            # The tombstone deletes the sweep emits are enqueued
            # fiber-locally (`Document::Delete.call` calls
            # `Event::Publisher.enqueue`). The sweep runs outside the HTTP
            # layer, so flush here so the `deleted` events land on the
            # stream — same pattern as `Replication::Handler#call`.
            Facet::Event::Publisher.flush
          rescue ex : Exception
            # Logged, not retried — the reconciliation cron is the
            # backstop. Mirrors the replication handler's transient-failure
            # policy.
            Log.error { "Sweep handler error: #{ex.message}" }
          end

          # ── Private ───────────────────────────────────────────────────

          # Tombstones every sidecar record attached to `host_qualified`.
          # Loads the host doctype definition, iterates its `sidecars` map,
          # and for each entry soft-deletes the sidecar records whose
          # `target` column equals the host's qualified id.
          private def sweep_host(
            db : DB::Connection,
            host_domain : String,
            host_doctype : String,
            host_qualified : String,
          ) : Nil
            host_defn = Facet::Doctype::DefinitionStore.fetch(db, "#{host_domain}.#{host_doctype}")
            return if host_defn.nil? || host_defn.sidecars.empty?

            host_defn.sidecars.each_value do |sidecar_ref|
              sweep_sidecar(db, sidecar_ref, host_qualified)
            end
          end

          # Soft-deletes the sidecar records of `sidecar_ref.doctype` whose
          # `sidecar_ref.column` equals `host_qualified`. The actual loop
          # lives on `Sidecars.tombstone_by_target` — shared with the
          # reconciliation cron.
          private def sweep_sidecar(
            db : DB::Connection,
            sidecar_ref : Facet::Doctype::SidecarRef,
            host_qualified : String,
          ) : Nil
            Sidecars.tombstone_by_target(
              db, sidecar_ref.doctype, sidecar_ref.column, host_qualified,
              actioner_id: "system:sidecar-sweep",
              label: "Sweep",
            )
          end
        end

        # Coordinator for the sidecar sweep subsystem. Owns its own
        # `Event::Manager` (consumer-group prefix `cg:sidecar:`) and the
        # `Handler` that processes host `deleted` events. Constructed and
        # started by `main.cr` alongside the replication manager; the
        # channel provider keeps the host-doctype subscription set current
        # without a restart.
        class Manager
          Log = ::Log.for("facet.event.subscriber.sidecar_sweep.manager")

          getter event_manager : Facet::Event::Manager
          getter handler : Handler
          getter? started : Bool

          def initialize(event_config : Facet::Event::Config, service_id : String)
            @event_manager = Facet::Event::Manager.new(
              config: event_config,
              service_id: service_id,
              consumer_group_prefix: "cg:sidecar:",
            )
            @handler = Handler.new
            @started = false
            @mutex = Mutex.new
          end

          # Builds the host-sidecar set from the DB, registers a `deleted`
          # subscription for every host doctype that declares a `sidecars`
          # map, installs the runtime channel provider, and starts the
          # event manager.
          def start(db : DB::Connection) : Nil
            @mutex.synchronize do
              return if @started

              register_subscriptions(db)

              @event_manager.start

              # `sidecar` is the consuming "domain" key the stream
              # subscriber groups channels under. One consumer group
              # (`cg:sidecar:sidecar`) for the whole process — every
              # host-doctype `deleted` stream is consumed by the same
              # single handler.
              @event_manager.set_channel_provider("sidecar", channel_provider)

              @started = true
              Log.info { "Sidecar sweep manager started" }
            end
          end

          def stop : Nil
            @mutex.synchronize do
              return unless @started
              @event_manager.stop
              @started = false
              Log.info { "Sidecar sweep manager stopped" }
            end
          end

          # ── Private ───────────────────────────────────────────────────

          # Subscribes the handler to the `deleted` event on every host
          # doctype that currently declares a `sidecars` map. Called before
          # `event_manager.start`.
          private def register_subscriptions(db : DB::Connection) : Nil
            host_doctypes = host_sidecar_hosts(db)
            host_doctypes.each do |qualified_doctype|
              domain, doctype = Util::QualifiedRef.split_doctype(qualified_doctype)
              resource_type = "#{domain}:#{doctype}"
              @event_manager.subscribe_resource_event("sidecar", resource_type, "deleted") do |msg|
                @handler.call(msg)
              end
            end
          end

          # Returns a callable that yields the *current* set of host-doctype
          # `deleted` channels. The stream subscriber consults it on each
          # polling turn so a doctype create/update that adds or removes a
          # `sidecars` entry is reflected without a restart — same approach
          # `Replication::Manager` uses for source-doctype set changes.
          private def channel_provider : Proc(Array(String))
            -> do
              channels = [] of String
              Facet::Database.with_db(:read_only) do |db|
                host_sidecar_hosts(db).each do |qualified_doctype|
                  domain, doctype = Util::QualifiedRef.split_doctype(qualified_doctype)
                  channels << "FACET:RESOURCE:#{domain}:#{doctype}"
                end
              end
              channels.uniq!
            end
          end

          # Queries every `core.DocType` projection whose definition
          # declares a non-empty `sidecars` map. Returns the set of
          # qualified host doctype ids (`{domain}.{Doctype}`). The sweep
          # subscribes to each one's `deleted` stream.
          #
          # A sidecar doctype itself (e.g. `core.Comment`) declares
          # `sidecar: true` but has an empty `sidecars` map (it points at
          # hosts, hosts do not point at it through `sidecars`). The sweep
          # therefore never subscribes to a sidecar doctype's own
          # `deleted` stream — only host doctypes.
          private def host_sidecar_hosts(db : DB::Connection) : Array(String)
            db.query_all(
              <<-SQL,
                SELECT id FROM projections
                WHERE domain = 'core' AND doc_type = 'DocType'
                  AND deleted_at IS NULL
                  AND content ? 'sidecars'
                  AND jsonb_typeof(content->'sidecars') = 'object'
                  AND (SELECT count(*) FROM jsonb_object_keys(content->'sidecars')) > 0
              SQL
              as: String,
            )
          rescue ex : Exception
            Log.error { "host_sidecar_hosts query failed: #{ex.message}" }
            [] of String
          end
        end
      end
    end
  end
end
