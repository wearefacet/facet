# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/redis_helper"

# Integration spec: a settings save must mark the in-process cache stale
# through the real chain — Document::Update → Event::Publisher (a real
# `Event::Manager` against Redis) → the `fanout:core.SystemSettings:*`
# Pub/Sub pattern → the `SystemSettingsCache` subscriber. A lost fanout
# self-heals through the staleness bound; that bound's semantics are pinned
# by the `Util::CacheFreshness` specs, not here.
#
# Uses the dedicated subscriber Redis database (9), the same one the other
# Pub/Sub subscriber specs run against.

ENV["EVENT_REDIS_URL"] = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/event/subscriber/system_settings_cache"
require "../../src/event/manager"

describe "SystemSettings save fans out and marks the cache stale" do
  redis_url = ENV["EVENT_REDIS_URL"]

  before_each do
    Facet::SystemSettings.reset_cache!
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
    # Restore the suite's in-process manager so the stub never leaks.
    Facet::Event::Publisher.manager = Facet::Event::InProcessManager.new
  end

  it "marks the cache stale in-process after a real save and flush" do
    # Warm the cache so the assertion observes an invalidation, not the
    # never-built state.
    with_db do |db|
      Facet::SystemSettings.value_at(db, "assistant.model")
    end
    Facet::SystemSettings.stale?.should be_false

    # Install a real manager (spec_helper installs the in-process one) and
    # start the subscriber on the pattern before the save — the same
    # subscribe-before-fetch ordering boot uses.
    manager = Facet::Event::Manager.new(
      config: Facet::Event::Config.new(url: redis_url),
      service_id: "system-settings-fanout-spec",
    )
    Facet::Event::Publisher.manager = manager

    subscriber = Facet::Event::Subscriber::SystemSettingsCache.new(
      redis_url: redis_url,
      service_id: "system-settings-fanout-spec",
    )
    subscriber.start

    begin
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
          %({"assistant": {"model": "fanout-model"}}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Update::Result)
        Facet::Event::Publisher.flush
      end

      # The save published on fanout:core.SystemSettings:settings; the
      # subscriber receives it and marks the in-process cache stale.
      assert_eventually(timeout: 5.0) do
        Facet::SystemSettings.stale?
      end
    ensure
      subscriber.stop
    end

    # The next read rebuilds from the projection row: the hot change is live.
    with_db do |db|
      Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s).should eq("fanout-model")
    end
  end
end
