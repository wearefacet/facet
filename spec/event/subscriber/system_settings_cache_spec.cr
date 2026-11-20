# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

# Imports the subscriber (which brings `Facet::SystemSettings` and
# `Facet::BaseEmail` with them).
require "../../../src/event/subscriber/system_settings_cache"

# Unit coverage for the `SystemSettingsCache` pattern subscriber. The
# lifecycle (connection, reconnect loop) lives in `PatternSubscriber` and is
# exercised against real Redis by the replication auto-refresh spec; this
# file covers the pattern list and the channel-keyed dispatch, none of which
# needs a connection.
describe Facet::Event::Subscriber::SystemSettingsCache do
  before_each do
    Facet::SystemSettings.reset_cache!
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "subscribes to the singleton's fanout pattern" do
    patterns = Facet::Event::Subscriber::SystemSettingsCache.new("redis://localhost:6379/9", "spec").patterns

    patterns.size.should eq(1)
    patterns[0].should eq("fanout:core.SystemSettings:*")
  end

  it "marks the settings cache stale on a settings fanout" do
    Facet::Database.with_db do |db|
      # Warm the cache (the projections table may be truncated — a missing
      # document still marks the cache fresh, following the file).
      Facet::SystemSettings.value_at(db, "assistant.model")
    end
    Facet::SystemSettings.stale?.should be_false

    subscriber = Facet::Event::Subscriber::SystemSettingsCache.new("redis://localhost:6379/9", "spec")
    subscriber.handle_message("fanout:core.SystemSettings:settings", "{}")

    Facet::SystemSettings.stale?.should be_true
  end

  it "re-arms the mail rebuild hook on a settings fanout" do
    # The subscriber's dispatch must reach both invalidation targets. The
    # settings flag is asserted above; here the mail hook side runs without
    # error (the adapter-rebuild behavior itself is covered by the mail
    # hot-change spec, which observes a rebuild end to end).
    subscriber = Facet::Event::Subscriber::SystemSettingsCache.new("redis://localhost:6379/9", "spec")
    subscriber.handle_message("fanout:core.SystemSettings:settings", "{}")
  end
end
