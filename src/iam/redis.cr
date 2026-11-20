# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "redis"
require "../config"

module Facet
  # Shared per-call Redis client factory for the feature modules.
  #
  # The `event.url` config key is the single source of truth for the Redis
  # endpoint — every module that talks to Redis builds its client here. The
  # per-call pattern stays: callers open a client, use it, and close it (or
  # hand its lifetime to a subscriber fiber). No pooling, no state.
  module Redis
    # A fresh client bound to the configured `event.url`.
    def self.client : ::Redis::Client
      ::Redis::Client.new(URI.parse(Config.instance.event.url))
    end

    # A fresh client for an explicitly injected URL — used by callers that
    # receive the URL as a parameter (the hooks scheduler and the assistant
    # stream-cancel bus) so tests can isolate their own Redis instance.
    def self.client(url : String) : ::Redis::Client
      ::Redis::Client.new(URI.parse(url))
    end
  end
end
