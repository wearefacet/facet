# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

# Imports the subscriber (which brings `Facet::Currency::Registry` with it).
require "../../../src/event/subscriber/doctype_cache"

# Unit coverage for the `DoctypeCache` pattern subscriber. The lifecycle
# (connection, reconnect loop) lives in `PatternSubscriber` and is exercised
# against real Redis by the replication auto-refresh spec; this file covers
# the pattern list and the channel-keyed dispatch, none of which needs a
# connection.
describe Facet::Event::Subscriber::DoctypeCache do
  before_each do
    register_seed_currencies
  end

  after_each do
    # The currency-branch example flips the registry to stale; restore the
    # warm seed registration so later spec files never rebuild from a
    # truncated projections table.
    register_seed_currencies
  end

  it "subscribes to five patterns, one per cached registry" do
    patterns = Facet::Event::Subscriber::DoctypeCache.new("redis://localhost:6379/9", "spec").patterns

    patterns.size.should eq(5)
    patterns[0].should eq("fanout:core.DocType:*")
    patterns[1].should eq("fanout:core.Domain:*")
    patterns[2].should eq("fanout:core.DomainGrant:*")
    patterns[3].should eq("fanout:core.Webhook:*")
    patterns[4].should eq("fanout:core.Currency:*")
  end

  it "marks the currency registry stale on a currency fanout" do
    Facet::Currency::Registry.mark_fresh

    subscriber = Facet::Event::Subscriber::DoctypeCache.new("redis://localhost:6379/9", "spec")
    subscriber.handle_message("fanout:core.Currency:EUR", "{}")

    Facet::Currency::Registry.stale?.should be_true
  end

  it "dispatches the other fanout families without a manager or a connection" do
    subscriber = Facet::Event::Subscriber::DoctypeCache.new("redis://localhost:6379/9", "spec")

    # The hooks / webhook managers are singletons that stay unset in the
    # spec process — the branches must be nil-safe. The doctype branch
    # talks to the in-memory definition cache only.
    subscriber.handle_message("fanout:core.DocType:spec.Deal", "{}")
    subscriber.handle_message("fanout:core.Domain:crm", "{}")
    subscriber.handle_message("fanout:core.Webhook:wh-1", "{}")
  end
end
