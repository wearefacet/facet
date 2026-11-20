# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "./pattern_subscriber"
require "../../agent_tools"
require "../../iam/role_store"

module Facet
  module Event
    module Subscriber
      # Process-wide Redis Pub/Sub listener that invalidates the role
      # content cache (`IAM::RoleStore`) and signals the agent tools
      # registry when an `iam.Roles` mutation is published.
      #
      # A single long-lived `PSUBSCRIBE fanout:iam.Roles:*` connection. On
      # every message it evicts the mutated role's `RoleStore` entry — the
      # next `find_role_content` read (every authenticated, anonymous, and
      # API-key request) rebuilds from the database — and calls
      # `AgentTools.mark_stale`: the next `tools/list` rebuilds, and open
      # sessions observe the generation bump and re-list (the MCP plan's
      # `notifications/tools/list_changed` contract). The subscriber never
      # rebuilds, only evicts/signals staleness. Lifecycle lives in
      # `PatternSubscriber`.
      #
      # Started by `main.cr` **before** `HTTP::Server.routes`, mirroring the
      # other cache subscribers: any roles mutation published after startup
      # is observed even before the first request warms anything.
      #
      # Bounded by role count: every role create/update/delete emits exactly
      # one fanout message, and the resulting eviction is O(1).
      class RoleCache < PatternSubscriber
        Log = ::Log.for("facet.event.subscriber.role_cache")

        PATTERN = "fanout:iam.Roles:*"

        def initialize(redis_url : String, service_id : String)
          super(redis_url, service_id, "RoleCache")
        end

        def patterns : Tuple(String)
          {PATTERN}
        end

        # Channel-keyed signalling only — the payload is never inspected. Any
        # mutation (create/update/delete) on `iam.Roles` evicts that role's
        # cached content and invalidates the MCP tools listing, which is the
        # correct coarse-grained behavior.
        def handle_message(channel : String, message : String) : Nil
          # Channel format: fanout:iam.Roles:{qualified_role_id}. The
          # projection id of a role document is the qualified form
          # (`iam.Roles.admin`), so the suffix keys the cache directly.
          role_id = channel.rpartition(':').[2]?
          if role_id && !role_id.empty?
            Facet::IAM::RoleStore.invalidate(role_id)
          end

          Facet::AgentTools.mark_stale
          Log.debug { "Invalidated role cache + MCP tools (channel=#{channel})" }
        end
      end
    end
  end
end
