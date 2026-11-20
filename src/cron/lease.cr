# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../iam/redis"

module Facet
  module Cron
    # Redis-backed once-per-tick lease acquirer for `Cron::Scheduler`.
    #
    # The scheduler calls the proc on its loop fiber, before it spawns the
    # task fiber — one client, one calling fiber, no locking. The acquire
    # is `SET key owner NX EX ttl`: the first instance to reach the key
    # wins the tick, every other instance loses and skips. A Redis error
    # also skips (fail-close): the next tick re-arms, and a lost
    # maintenance pass is safer than a duplicated one. The lease is never
    # released — the TTL sweeps the key.
    module Lease
      Log = ::Log.for("facet.cron.lease")

      # Builds the acquirer for the Redis instance at `url`. `owner` (the
      # boot's service id) lands in the value, so `GET cron:lease:*` names
      # the instance that won the tick.
      def self.redis_acquirer(url : String) : Proc(String, Int32, String, Bool)
        redis = Facet::Redis.client(url)
        ->(key : String, ttl_s : Int32, owner : String) : Bool do
          begin
            redis.set(key, owner, ex: ttl_s, nx: true) == "OK"
          rescue ex : Exception
            Log.warn { "Lease acquire failed for '#{key}' (skipping fire): #{ex.message}" }
            false
          end
        end
      end
    end
  end
end
