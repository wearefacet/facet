# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../../system_settings"
require "../../emails/base_email"
require "./pattern_subscriber"

module Facet
  module Event
    module Subscriber
      # Process-wide Redis Pub/Sub listener that invalidates the system
      # settings cache when a `core.SystemSettings` mutation is published,
      # and re-arms the mail adapter so the next send rebuilds from the new
      # values.
      #
      # The doctype has exactly one document, so one pattern is the whole
      # invalidation surface:
      #
      # - `fanout:core.SystemSettings:*` — every mutation (create, update,
      #   delete) of the singleton publishes on the document channel
      #   `fanout:core.SystemSettings:settings`, which the pattern matches.
      #
      # Follows the invalidate-only contract: the subscriber never rebuilds,
      # it only calls `SystemSettings.mark_stale` (a pure flag) and
      # `BaseEmail.reset_configuration!` (the mail rebuild hook). Each node
      # recovers via its own DB query on the next read — the assistant at
      # the next turn start, the mail adapter before the next send. A fanout
      # lost while Redis was down self-heals through `cache.staleness_ttl_s`
      # (`Util::CacheFreshness` — the read sites check the cache generation
      # before trusting their memo state).
      #
      # Started in `Facet::Boot.start_cache_subscribers` alongside the other
      # cache subscribers, before HTTP routes mount.
      class SystemSettingsCache < PatternSubscriber
        Log = ::Log.for("facet.event.subscriber.system_settings_cache")

        PATTERN = "fanout:core.SystemSettings:*"

        def initialize(redis_url : String, service_id : String)
          super(redis_url, service_id, "SystemSettingsCache")
        end

        def patterns : Tuple(String)
          {PATTERN}
        end

        def handle_message(channel : String, message : String) : Nil
          Facet::SystemSettings.mark_stale
          Facet::BaseEmail.reset_configuration!
          Log.debug { "Invalidated system settings cache: #{channel}" }
        end
      end
    end
  end
end
