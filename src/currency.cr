# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "pg"
require "./util/cache_freshness"
require "./util/money"

module Facet
  module Currency
    # Loads the in-process currency registry (`Util::Currency`) from the
    # `core.Currency` documents. The registry keeps its read APIs; this module
    # owns only population and staleness.
    #
    # Follows the invalidate-only contract of the doctype definition cache and
    # the webhook registry:
    #
    # - The `DoctypeCache` Pub/Sub subscriber marks the registry stale on every
    #   `fanout:core.Currency:*` fanout (create, update, delete).
    # - The next `ensure_fresh` call on a write path rebuilds it from the
    #   `projections` table. Rebuilds are replace-all (`reset!` + `register`)
    #   so deactivations and deletes land.
    # - There is no DB access on the invalidation path itself.
    #
    # A fanout can be lost (a mutation published while Redis was down), so the
    # registry also stamps the monotonic time of its last refresh and rebuilds
    # on `ensure_fresh` calls past `cache.staleness_ttl_s` — see
    # `Util::CacheFreshness`. The bound caps worst-case staleness instead of
    # letting it persist until restart.
    #
    # Consistency window: between a commit and the next `ensure_fresh` on the
    # affected process — the same contract the webhook and doctype registries
    # accept.
    module Registry
      Log = ::Log.for("facet.currency.registry")

      # `true` until the first refresh (or `mark_fresh`).
      @@stale = true

      # Monotonic stamp of the last refresh (or `mark_fresh`). Drives the
      # staleness bound in `ensure_fresh`.
      @@refreshed_at : Time::Instant? = nil

      def self.stale? : Bool
        @@stale
      end

      # Pure flag — called by the Pub/Sub subscriber. No DB access.
      def self.mark_stale : Nil
        @@stale = true
      end

      # Marks the registry fresh without a rebuild. Used by the spec plumbing,
      # which registers the seed set in memory (the per-example truncation
      # wipes the `core.Currency` projections, so a rebuild would empty the
      # registry). Stamps the freshness time so the staleness bound counts
      # from the mark, not from the process start.
      def self.mark_fresh : Nil
        @@stale = false
        @@refreshed_at = Time.instant
      end

      # Rebuilds the registry when it is stale, or when the last refresh is
      # older than the staleness bound (`Util::CacheFreshness`) — the safety
      # net for a lost fanout. A flag check is cheap, so write paths may call
      # this unconditionally.
      def self.ensure_fresh(db : DB::Connection) : Nil
        refresh(db) if @@stale || Util::CacheFreshness.expired?(@@refreshed_at)
      end

      # Rebuilds the registry from every non-deleted `core.Currency` row.
      # Replace-all by design: tickers that no longer exist as live rows leave
      # the registry. A malformed row raises loudly — a broken currency row is
      # data corruption, never a silent gap in the registry.
      def self.refresh(db : DB::Connection) : Nil
        rows = db.query_all(
          "SELECT content FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'Currency' AND deleted_at IS NULL",
          as: JSON::Any,
        )

        currencies = {} of String => Util::Currency
        rows.each do |content|
          currency = Util::Currency.from_json(content.to_json)
          currencies[currency.ticker] = currency
        end

        Util::Currency.reset!
        Util::Currency.register(currencies)
        @@stale = false
        @@refreshed_at = Time.instant
        Log.debug { "Currency registry refreshed: #{currencies.size} currencies" }
      end
    end
  end
end
