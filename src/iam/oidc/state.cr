# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../redis_session"

module Facet
  module IAM
    module OIDC
      STATE_TTL = 300.seconds

      # One-shot OIDC flow state in Redis, following the `pwd_change_token`
      # discipline: consume before act, 300 s TTL. The row is stored as a
      # JSON string and consumed with `GETDEL` so the consume is atomic —
      # the redis shard has no atomic hash consume, and a read-then-delete
      # hash would leave a replay window between the two commands.
      module State
        PREFIX = "oidc:state:"

        struct Entry
          include JSON::Serializable
          property provider : String
          property nonce : String
          property verifier : String

          def initialize(@provider : String, @nonce : String, @verifier : String)
          end
        end

        def self.create(state : String, provider : String, nonce : String, verifier : String) : Nil
          payload = Entry.new(provider: provider, nonce: nonce, verifier: verifier).to_json
          RedisSession.redis.set("#{PREFIX}#{state}", payload, ex: STATE_TTL)
        end

        # Atomically reads and deletes the state row. Returns nil when the
        # state is missing, expired, or already consumed.
        def self.consume(state : String) : Entry?
          raw = RedisSession.redis.getdel("#{PREFIX}#{state}")
          return nil unless raw.is_a?(String)
          Entry.from_json(raw)
        rescue JSON::ParseException
          Log.warn { "OIDC state row is not valid JSON — treating as missing" }
          nil
        end
      end
    end
  end
end
