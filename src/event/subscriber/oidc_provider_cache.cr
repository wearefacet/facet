# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "./pattern_subscriber"
require "../../iam/oidc/provider_store"

module Facet
  module Event
    module Subscriber
      # Process-wide Redis Pub/Sub listener that invalidates the OIDC
      # provider cache (`IAM::OIDC::ProviderStore`) when an
      # `iam.OIDCProvider` mutation is published.
      #
      # The cache holds the whole enabled-provider list under one key, so
      # one pattern is the whole invalidation surface:
      # `fanout:iam.OIDCProvider:*` matches the document channel of every
      # provider create, update, and delete. Follows the invalidate-only
      # contract: the subscriber never rebuilds, it only clears the list —
      # each node recovers through its own DB query on the next read (the
      # start route, the callback, and the public providers listing). A
      # fanout lost while Redis was down self-heals through
      # `cache.staleness_ttl_s` (`Util::CacheFreshness`).
      #
      # Started in `Facet::Boot.start_cache_subscribers` alongside the
      # other cache subscribers, before HTTP routes mount.
      class OidcProviderCache < PatternSubscriber
        Log = ::Log.for("facet.event.subscriber.oidc_provider_cache")

        PATTERN = "fanout:iam.OIDCProvider:*"

        def initialize(redis_url : String, service_id : String)
          super(redis_url, service_id, "OidcProviderCache")
        end

        def patterns : Tuple(String)
          {PATTERN}
        end

        # Channel-keyed signalling only — the payload is never inspected.
        # Any mutation (create/update/delete) on `iam.OIDCProvider` drops
        # the cached list; the next registry read rebuilds from the
        # database.
        def handle_message(channel : String, message : String) : Nil
          Facet::IAM::OIDC::ProviderStore.invalidate
          Log.debug { "Invalidated OIDC provider cache (channel=#{channel})" }
        end
      end
    end
  end
end
