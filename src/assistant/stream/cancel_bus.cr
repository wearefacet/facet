# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../../iam/redis"

module Facet
  module Assistant
    module Stream
      # Redis-backed Pub/Sub bus for cross-process cancel fan-out.
      #
      # One streaming turn owns one cancel channel: `assistant:cancel:<turn_token>`.
      # The streaming route handler subscribes to that channel in a dedicated
      # fiber; the cancel endpoint publishes to it. Whichever server process owns
      # the live `Agent::Response` receives the message and calls `#cancel`,
      # which flips a mutex-protected flag — agent-cr's stream parser checks
      # that flag between SSE lines and aborts the in-flight HTTP instantly.
      #
      # ## Robustness to late subscribers
      #
      # Pub/Sub is fire-and-forget — a subscriber that connects *after* a
      # publish would miss it. To close that race, `publish` also `SET`s a
      # Redis key with a short TTL. `subscribe` issues a `GET` once on the
      # yielded subscription connection AFTER the SUBSCRIBE command has been
      # flushed to the server, so any racing publish is observed either via
      # the GET (catching pre-subscribe publishes) or via the queued message
      # (catching publishes that arrived after the server registered us).
      # The TTL self-cleans stale keys.
      module CancelBus
        Log = ::Log.for("facet.assistant.cancel_bus")

        CHANNEL_PREFIX = "assistant:cancel:"
        KEY_PREFIX     = "assistant:cancel:"

        # Handle returned by `subscribe` so the route handler can shut the
        # subscriber down cleanly. Closing it closes the Redis client, which
        # closes the underlying subscribed connection — the subscriber fiber
        # then exits via an `IO::Error`. Idempotent.
        class SubscriptionHandle
          @closed = false

          def initialize(@client : ::Redis::Client)
          end

          def close : Nil
            return if @closed
            @closed = true
            @client.close
          end
        end

        # Publishes a cancel signal for the given turn token.
        #
        # Order matters: `SET` first (so a subscriber's post-subscribe `GET`
        # sees it), then `PUBLISH` (so already-subscribed listeners wake up).
        # Both commands are issued on the same Redis client, sequentially.
        def self.publish(turn_token : String, redis_url : String, ttl_seconds : Int32) : Nil
          client = Facet::Redis.client(redis_url)
          begin
            client.set(cancel_key(turn_token), "1", ex: ttl_seconds)
            client.publish(channel(turn_token), "1")
          ensure
            client.close
          end
        end

        # Subscribes to the cancel channel for `turn_token` and yields (once,
        # possibly more if publishes arrive) when a cancel is observed.
        #
        # **Spawns a dedicated fiber** that holds the subscription open and
        # returns a `SubscriptionHandle` immediately so the caller can proceed
        # with `agent.ask`. The caller MUST `close` the handle from its
        # `ensure` block to release the subscriber fiber.
        #
        # The yield block is invoked from within the subscriber fiber; it must
        # be fiber-safe (the typical action is `resp.cancel`, which is a
        # mutex-flag flip).
        def self.subscribe(turn_token : String, redis_url : String, &on_cancel : -> Nil) : SubscriptionHandle
          client = Facet::Redis.client(redis_url)
          channel_name = channel(turn_token)
          key = cancel_key(turn_token)

          spawn(name: "assistant-cancel-subscriber") do
            client.subscribe(channel_name) do |subscription, _connection|
              # Wire the live message callback first so anything that arrives
              # once the server registers us is handled.
              subscription.on_message do |_ch, _msg, _pattern|
                on_cancel.call
              end

              # SUBSCRIBE has been flushed to the server by now. Issue a GET
              # on a SEPARATE short-lived client (the yielded connection is in
              # subscribe mode and cannot run non-subscribe commands). This
              # catches a publish that raced ahead of our subscription being
              # registered server-side: either the SET already landed (GET
              # returns "1") or the PUBLISH is queued and will arrive via the
              # message callback above.
              probe = Facet::Redis.client(redis_url)
              begin
                if probe.get(key) != nil
                  on_cancel.call
                end
              ensure
                probe.close
              end
            end
          rescue ex : IO::Error
            # Normal shutdown path: the route handler's ensure closed the
            # client, which closed the subscribed connection mid-read.
            Log.debug { "CancelBus subscriber connection closed: #{ex.message}" }
          rescue ex
            Log.error { "CancelBus subscriber unexpected error: #{ex.message}" }
          end

          SubscriptionHandle.new(client)
        end

        # Builds the Pub/Sub channel name for a turn token.
        def self.channel(turn_token : String) : String
          "#{CHANNEL_PREFIX}#{turn_token}"
        end

        # Builds the Redis key used for the missed-publish safety net.
        def self.cancel_key(turn_token : String) : String
          "#{KEY_PREFIX}#{turn_token}"
        end
      end
    end
  end
end
