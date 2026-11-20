# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../../doctype/definition_store"
require "../../replication"
require "../../grants"
require "../../hooks"
require "../../webhook"
require "../../currency"
require "./pattern_subscriber"

module Facet
  module Event
    module Subscriber
      # Process-wide Redis Pub/Sub listener that invalidates the doctype
      # definition cache when a `core.DocType` mutation is published, the
      # replication registry when a `core.Domain` mutation is published, the
      # hooks registry when a `core.Domain` mutation is published, the
      # webhook registry when a `core.Webhook` mutation is published, the
      # currency registry when a `core.Currency` mutation is published, and
      # the grants registry when a `core.DomainGrant` mutation is published.
      #
      # Uses a single long-lived `PSUBSCRIBE` connection on five patterns:
      #
      # - `fanout:core.DocType:*` — evicts the cached doctype definition
      #   and marks the replication registry stale.
      # - `fanout:core.Domain:*` — marks the replication and hooks
      #   registries stale (both re-read `core.Domain` state at rebuild).
      # - `fanout:core.DomainGrant:*` — marks the grants registry stale
      #   (grants live on `core.DomainGrant` projections) plus the
      #   replication and hooks registries: a grant change must cut or
      #   restore bindings and hook fires without a restart.
      # - `fanout:core.Webhook:*` — marks the webhook registry stale
      #   (bindings live on `core.Webhook` projections).
      # - `fanout:core.Currency:*` — marks the currency registry stale
      #   (rows live on `core.Currency` projections; `Facet::Currency::
      #   Registry` rebuilds on the next `ensure_fresh` on a write path).
      #
      # All follow the same **invalidate-only** pattern: the subscriber
      # never rebuilds, it only signals staleness. Each node recovers via
      # its own DB query on the next read. This keeps the subscriber
      # DB-free and lets the invalidation fan out across a multi-node
      # cluster via Redis Pub/Sub. Lifecycle (connection, reconnect loop,
      # start/stop) lives in `PatternSubscriber`.
      #
      # Pub/Sub delivery is fire-and-forget, so a mutation published while
      # Redis was down reaches no subscriber. The read-side caches therefore
      # also stamp their last rebuild and reload on reads past
      # `cache.staleness_ttl_s` (`Util::CacheFreshness`) — the bound caps
      # worst-case staleness instead of letting it persist until restart.
      #
      # ## Subscribe-before-fetch ordering
      #
      # `main.cr` starts this subscriber **before** `HTTP::Server.routes`
      # to avoid a stale-forever window: any `core.DocType` or
      # `core.Domain` mutation published after startup is observed, even
      # before any request has warmed the caches.
      #
      # Bounded by doctype + domain + webhook + currency + grant count:
      # every
      # mutation emits exactly
      # one fanout message, and the resulting eviction is O(1).
      class DoctypeCache < PatternSubscriber
        Log = ::Log.for("facet.event.subscriber.doctype_cache")

        PATTERN_DOCTYPE      = "fanout:core.DocType:*"
        PATTERN_DOMAIN       = "fanout:core.Domain:*"
        PATTERN_DOMAIN_GRANT = "fanout:core.DomainGrant:*"
        PATTERN_WEBHOOK      = "fanout:core.Webhook:*"
        PATTERN_CURRENCY     = "fanout:core.Currency:*"

        def initialize(redis_url : String, service_id : String)
          super(redis_url, service_id, "DoctypeCache")
        end

        def patterns : Tuple(String, String, String, String, String)
          {PATTERN_DOCTYPE, PATTERN_DOMAIN, PATTERN_DOMAIN_GRANT, PATTERN_WEBHOOK, PATTERN_CURRENCY}
        end

        # Dispatches the fanout message to the appropriate invalidation
        # path based on the channel prefix. The payload is never inspected
        # — eviction is purely channel-keyed, which is safe because any
        # mutation (create/update/delete) on `core.DocType` invalidates
        # the cached definition, any mutation on `core.Domain` may have
        # changed the `hooks` array, any mutation on `core.Webhook`
        # may have added/removed/disabled a binding, and any mutation on
        # `core.Currency` may have created, deactivated, or deleted a
        # currency row.
        def handle_message(channel : String, message : String) : Nil
          if channel.starts_with?("fanout:core.Currency:")
            mark_currency_registry_stale(channel)
            return
          end

          if channel.starts_with?("fanout:core.DomainGrant:")
            mark_grant_registries_stale(channel)
            return
          end

          if channel.starts_with?("fanout:core.Webhook:")
            mark_webhook_registry_stale(channel)
            return
          end

          if channel.starts_with?("fanout:core.Domain:")
            mark_domain_registries_stale(channel)
            return
          end

          mark_doctype_caches_stale(channel)
        end

        # A grant change must cut or restore bindings and hook fires
        # without a restart — the replication registry re-asserts coverage
        # against the grants registry at build, and the hooks registry
        # gates foreign-source fires on the same data.
        private def mark_grant_registries_stale(channel : String) : Nil
          grant_id = channel.rpartition(':').[2]?
          return if grant_id.nil? || grant_id.empty?

          Facet::Grants::Registry.mark_stale
          Facet::Replication::Manager.instance.try(&.mark_registry_stale)
          Facet::Hooks::Manager.instance.try(&.mark_registry_stale)
          Log.debug { "Invalidated grants + replication + hooks registries: #{grant_id}" }
        end

        private def mark_webhook_registry_stale(channel : String) : Nil
          webhook_id = channel.rpartition(':').[2]?
          return if webhook_id.nil? || webhook_id.empty?

          Facet::Webhook::Manager.instance.try(&.mark_registry_stale)
          Log.debug { "Invalidated webhook registry: #{webhook_id}" }
        end

        private def mark_domain_registries_stale(channel : String) : Nil
          domain_id = channel.rpartition(':').[2]?
          return if domain_id.nil? || domain_id.empty?

          # The replication registry re-asserts grant coverage at build
          # time (fail-closed) and the hooks registry gates foreign-source
          # fires — a domain write (draft flag, hooks array) can change
          # both verdicts.
          Facet::Grants::Registry.mark_stale
          Facet::Replication::Manager.instance.try(&.mark_registry_stale)
          Facet::Hooks::Manager.instance.try(&.mark_registry_stale)
          Log.debug { "Invalidated grants + replication + hooks registries: #{domain_id}" }
        end

        private def mark_doctype_caches_stale(channel : String) : Nil
          # Channel format: fanout:core.DocType:{doctype_id}
          doctype_id = channel.rpartition(':').[2]?
          return if doctype_id.nil? || doctype_id.empty?

          Doctype::DefinitionStore.invalidate(doctype_id)
          Facet::Replication::Manager.instance.try(&.mark_registry_stale)
          Log.debug { "Invalidated doctype cache + replication registry: #{doctype_id}" }
        end

        # Currency fanouts invalidate in one direction only: the registry
        # flag flips to stale, and the next `ensure_fresh` on a write path
        # rebuilds from `core.Currency` projections.
        private def mark_currency_registry_stale(channel : String) : Nil
          ticker = channel.rpartition(':').[2]?
          return if ticker.nil? || ticker.empty?

          Facet::Currency::Registry.mark_stale
          Log.debug { "Marked currency registry stale: #{ticker}" }
        end
      end
    end
  end
end
