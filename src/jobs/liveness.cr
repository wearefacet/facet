# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "mutex"
require "redis"
require "../iam/redis"

module Facet
  module Jobs
    # Instance liveness for the job-queue lease sweep.
    #
    # The worker marks its own instance alive on every sweep tick
    # (`refresh`) — one Redis key per instance, with a TTL. The key
    # expires when the instance dies, so the sweep can recover a
    # `running` row as soon as its owner instance is gone, instead of
    # waiting for the row's lease horizon. The sweep reads each running
    # row's owner key (`alive?`).
    #
    # The key carries the `Facet::Service` instance id — one ULID per
    # boot, per the instance-identity rule (`doc/backend/event.md` →
    # Shard locking). No component mints a second identity.
    #
    # The check is an injectable seam: the worker takes a `Liveness`
    # object, and specs install a fake. `Redis` below is the default.
    module Liveness
      # The liveness key for one instance. The instance id sits in the
      # key, so one `GET` answers one instance and no value parsing is
      # needed.
      def self.key(instance_id : String) : String
        "FACET:JOBS:SERVICE_LIVENESS:#{instance_id}"
      end

      # Marks the instance alive now. Called once per sweep tick.
      abstract def refresh(instance_id : String) : Nil

      # Returns `true` while the instance's liveness key exists.
      abstract def alive?(instance_id : String) : Bool

      # Redis-backed liveness. One client per worker, built on first use.
      #
      # The build is lazy on purpose: `Redis::Client` opens its
      # connection in the constructor, and workers get built in specs and
      # in enqueue-only deployments where Redis may be unreachable. A
      # failed build retries on the next tick.
      class Redis
        include Liveness

        Log = Facet::Jobs::Log.for("liveness")

        # TTL of the liveness key, in seconds. The sweep tick is 30 s
        # (`sweep_interval_s`), so this TTL survives three missed ticks —
        # one more than the two required. A brief stall (a slow tick, a
        # short GC pause) never declares a live instance dead, and a dead
        # instance is still detected within one tick past the TTL — far
        # below any lease horizon.
        TTL_S = 120

        @redis_url : String?
        @redis : ::Redis::Client?
        @mutex = Mutex.new

        # Stores the endpoint. `redis_url` nil binds the `event.url`
        # config key — the single source of truth for the Redis endpoint.
        # Specs pass an explicit URL to point the check at a dead
        # endpoint on purpose. No I/O happens here.
        def initialize(redis_url : String? = nil)
          @redis_url = redis_url
        end

        def refresh(instance_id : String) : Nil
          client.set(Liveness.key(instance_id), "1", ex: TTL_S)
        rescue ex : Exception
          # The next tick retries. If the key expires, peers may requeue
          # this instance's rows while the lease horizon still holds —
          # bounded risk. A silent skip would be worse: an instance that
          # never refreshes must not look alive.
          Log.warn { "Liveness refresh failed for instance #{instance_id}: #{ex.message}" }
        end

        def alive?(instance_id : String) : Bool
          !client.get(Liveness.key(instance_id)).nil?
        rescue ex : Exception
          # Fail open. A Redis outage must not requeue every running row
          # in the cluster; the lease sweep stays the recovery path until
          # Redis returns.
          Log.warn { "Liveness read failed for instance #{instance_id} (treated as alive): #{ex.message}" }
          true
        end

        # Builds the client on first use and memoizes it. `refresh` and
        # `alive?` run on the worker's single loop fiber; the mutex keeps
        # the build safe for any future caller.
        private def client : ::Redis::Client
          @mutex.synchronize do
            @redis ||= build_client
          end
        end

        private def build_client : ::Redis::Client
          url = @redis_url
          url ? Facet::Redis.client(url) : Facet::Redis.client
        end
      end
    end
  end
end
