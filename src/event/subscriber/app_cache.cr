# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../../oauth/origin_cache"
require "../../app/hosting"
require "./pattern_subscriber"

module Facet
  module Event
    module Subscriber
      # Process-wide Redis Pub/Sub listener that invalidates the OAuth
      # `OriginCache` and the app-host dispatch cache (`App::Hosting::HostCache`)
      # when an `app.App` mutation is published.
      #
      # A single long-lived `PSUBSCRIBE fanout:app.App:*` connection. On
      # every message it calls `OAuth::OriginCache.mark_stale` — the next
      # CORS request rebuilds the cache lazily from the DB. The subscriber
      # never rebuilds, only signals staleness. Lifecycle lives in
      # `PatternSubscriber`.
      #
      # Pub/Sub delivery is fire-and-forget, so a mutation published while
      # Redis was down reaches no subscriber. The two read-side caches
      # therefore also stamp their last rebuild and reload on reads past
      # `cache.staleness_ttl_s` (`Util::CacheFreshness`) — the bound caps
      # worst-case staleness instead of letting it persist until restart.
      #
      # Started by `main.cr` **before** `HTTP::Server.routes` so any
      # `app.App` mutation published after startup is observed, even before
      # any request has warmed the cache.
      #
      # Bounded by app count: every app create/update/delete emits exactly
      # one fanout message, and the resulting eviction is O(1).
      class AppCache < PatternSubscriber
        Log = ::Log.for("facet.event.subscriber.app_cache")

        PATTERN = "fanout:app.App:*"

        def initialize(redis_url : String, service_id : String)
          super(redis_url, service_id, "AppCache")
        end

        def patterns : Tuple(String)
          {PATTERN}
        end

        # Channel-keyed eviction only — the payload is never inspected. Any
        # mutation (create/update/delete) on `app.App` invalidates the origin
        # cache and the app-host dispatch cache, which is the correct
        # coarse-grained behavior: an app can set or move its `host` and the
        # dispatcher picks it up on the next request without a restart.
        def handle_message(channel : String, message : String) : Nil
          Facet::OAuth::OriginCache.mark_stale
          Facet::App::Hosting::HostCache.mark_stale
          Log.debug { "Invalidated OAuth origin + app host caches (channel=#{channel})" }
        end
      end
    end
  end
end
