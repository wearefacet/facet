# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./util/script_helpers"

module Facet
  # Process-wide service identity for the server process.
  #
  # Each boot mints one instance id (a ULID). Every event manager, stream
  # subscriber, and Pub/Sub subscriber in the process derives its
  # `service_id` from here, so two instances of one environment never share
  # an identity: shard locks stay exclusive per instance, and a dead
  # instance's liveness key expires instead of being kept alive by a
  # sibling.
  #
  # The id is a ULID (`Util::ScriptHelpers.ulid`): time-sortable, so boot
  # order is visible in Redis keys and logs, and no infrastructure topology
  # (hostname, PID) leaks into Redis keys. Constructions outside the server
  # boot (specs, tools) keep the managers' random-hex defaults.
  module Service
    @@instance_id : String? = nil
    @@instance_id_mutex = Mutex.new

    # The instance id — one ULID per process, minted on first access.
    # Memoized under a mutex: every manager and subscriber in the process
    # reads this, and the mint must happen exactly once.
    def self.instance_id : String
      @@instance_id_mutex.synchronize do
        @@instance_id ||= Util::ScriptHelpers.ulid
      end
    end

    # The deployment environment. This module owns the `APP_ENV` rule, so
    # the boot log and `/Healthcheck` always report the same value.
    class_getter app_env : String { ENV["APP_ENV"]? || "dev" }

    # Builds a subsystem service id: `{prefix}-{env}-{instance_id}`.
    # The prefix says which subsystem holds a lock or owns a Redis key;
    # the instance id says which boot owns it. This is the single owner of
    # the id format.
    def self.service_id(prefix : String) : String
      "#{prefix}-#{app_env}-#{instance_id}"
    end
  end
end
