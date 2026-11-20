# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "./database"
require "./service"
require "./event/subscriber/doctype_cache"
require "./event/subscriber/app_cache"
require "./event/subscriber/role_cache"
require "./event/subscriber/system_settings_cache"
require "./event/subscriber/oidc_provider_cache"
require "./replication/manager"
require "./hooks/manager"
require "./webhook/manager"

module Facet
  # Boot helpers for the server entry point. They keep `main.cr`
  # declarative: the construction data (service-id prefixes) stays visible
  # at the boot site, while the repeated start choreography lives here once.
  #
  # Shutdown does NOT run through this module — `main.cr`'s `at_exit` block
  # keeps the explicit, ordered stop sequence. The termination-signal traps
  # that lead into it live in `Facet::Shutdown` (`./shutdown.cr`).
  module Boot
    # The five cache Pub/Sub subscribers booted before HTTP routes mount.
    alias CacheSubscriber = Event::Subscriber::DoctypeCache |
                            Event::Subscriber::AppCache |
                            Event::Subscriber::RoleCache |
                            Event::Subscriber::SystemSettingsCache |
                            Event::Subscriber::OidcProviderCache

    # Starts every cache Pub/Sub subscriber and returns them in start order
    # for the shutdown sequence. Subscribe-before-fetch ordering is
    # load-bearing (see each subscriber): with a Pub/Sub subscription live
    # before HTTP routes mount, any cache-owning mutation published after
    # startup is observed even before a request warms the cache. The ids
    # come from `Facet::Service` — one per-boot identity, shared with the
    # rest of the process.
    def self.start_cache_subscribers(redis_url : String) : Array(CacheSubscriber)
      subscribers = [
        Event::Subscriber::DoctypeCache.new(
          redis_url: redis_url,
          service_id: Facet::Service.service_id("facet-doctype-cache"),
        ),
        Event::Subscriber::AppCache.new(
          redis_url: redis_url,
          service_id: Facet::Service.service_id("facet-app-cache"),
        ),
        Event::Subscriber::RoleCache.new(
          redis_url: redis_url,
          service_id: Facet::Service.service_id("facet-role-cache"),
        ),
        Event::Subscriber::SystemSettingsCache.new(
          redis_url: redis_url,
          service_id: Facet::Service.service_id("facet-system-settings-cache"),
        ),
        Event::Subscriber::OidcProviderCache.new(
          redis_url: redis_url,
          service_id: Facet::Service.service_id("facet-oidc-provider-cache"),
        ),
      ]
      subscribers.each(&.start)
      subscribers
    end

    # Starts one subsystem manager after its process-wide singleton is
    # installed (the caller assigns `instance=` first, so Pub/Sub
    # invalidation works from the first event and the ordering stays
    # visible at the boot site). Builds the initial registry state from
    # the database and starts the manager.
    def self.start_manager(mgr : Subsystem::ManagerBase) : Nil
      Database.with_db(:read_write) { |db| mgr.start(db) }
    end
  end
end
