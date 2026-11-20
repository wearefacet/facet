# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../config"

module Facet
  module Util
    # Staleness bound shared by the invalidate-only process caches: doctype
    # definitions, OAuth origins, app hosts, the replication / hooks /
    # webhook registries, and the currency registry.
    #
    # These caches follow one contract: a Redis Pub/Sub fanout marks them
    # stale, and the next read rebuilds from PostgreSQL. The fanout is the
    # fast path, but it is fire-and-forget — a mutation published while
    # Redis was down reaches no subscriber, and an invalidate-only cache
    # would serve the old data until restart. Every cache that follows the
    # contract therefore also stamps the monotonic time of its last
    # successful rebuild (a `Time::Instant`, the same clock the OIDC
    # discovery cache uses) and treats reads past `cache.staleness_ttl_s`
    # as stale. The bound turns "stale until restart" into "stale for at
    # most the bound"; `0` disables it (the fanout is then the only
    # invalidation).
    #
    # The fanout keeps priority: a broadcast clears a cache immediately,
    # long before the bound would. The bound only bounds the worst case.
    module CacheFreshness
      # The staleness bound from `cache.staleness_ttl_s`. `0` (disabled)
      # yields a zero span — `expired?` then never fires.
      def self.configured_ttl : Time::Span
        Facet::Config.instance.cache.staleness_ttl_s.seconds
      end

      # True when a cache that last rebuilt at *built_at* may no longer
      # serve reads under the bound *ttl*.
      #
      # - A zero (or negative) *ttl* disables the bound — never expired.
      # - A `nil` *built_at* counts as expired whenever a bound is set: a
      #   cache that never rebuilt has no data to trust.
      # - Otherwise the monotonic age decides, so wall-clock jumps never
      #   expire a healthy cache.
      def self.expired?(built_at : Time::Instant?, ttl : Time::Span) : Bool
        return false if ttl <= Time::Span.zero
        return true unless stamp = built_at
        Time.instant - stamp > ttl
      end

      # Convenience form that reads the bound from the config. The hot
      # paths of the process caches call this; the config singleton is a
      # cached class getter, so the check stays cheap.
      def self.expired?(built_at : Time::Instant?) : Bool
        expired?(built_at, configured_ttl)
      end
    end
  end
end
