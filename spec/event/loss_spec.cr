# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/event"

# `Event::Loss` — the in-process visibility counters for the at-most-once
# delivery contract. The publish side is driven through a manager stub
# whose publish raises; the dispatch side is driven through the
# `SubscriptionRegistry` rescue.
class RaisingInProcessManager < Facet::Event::InProcessManager
  property? raise_on_publish : Bool = false

  def publish_resource_event(
    domain : String,
    resource_type : String,
    resource_id : String,
    event : String,
    payload : Hash(String, ::JSON::Any),
    headers : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any,
    fanout_channels : Array(String)? = nil,
  ) : String
    raise "stub publish failure" if @raise_on_publish
    super
  end
end

module Facet
  describe Event::Loss do
    # Captured by the hooks below — the suite's manager is restored after
    # each example so the stub never leaks into other specs.
    previous_manager = Event::Publisher.manager

    before_each do
      previous_manager = Event::Publisher.manager
      Event::Loss.reset
      # The spec runner reuses one fiber — drop any queue the suite
      # seeding left behind so the counters below see only this example's
      # events.
      Event::Publisher.discard
    end

    after_each do
      Event::Publisher.manager = previous_manager
      Event::Loss.reset
    end

    it "counts a failed flush and the events it dropped" do
      manager = RaisingInProcessManager.new
      manager.raise_on_publish = true
      Event::Publisher.manager = manager

      Event::Publisher.enqueue("hr", "Employee", "e-1", "created")
      Event::Publisher.enqueue("hr", "Employee", "e-2", "updated")
      Event::Publisher.flush

      snapshot = Event::Loss.snapshot
      snapshot["publish_flush_failures"].should eq(1)
      snapshot["publish_events_dropped"].should eq(2)
      snapshot["messages_dropped"].should eq(0)
      # The queue is discarded — a later flush is a no-op, not another loss.
      Event::Publisher.pending_count.should eq(0)
    end

    it "counts one message per dispatch rescue" do
      manager = RaisingInProcessManager.new
      Event::Publisher.manager = manager

      manager.subscribe_resource_event(domain: "hr", resource_type: "hr:Employee", event: "boom") do |_msg|
        raise "handler exploded"
      end
      manager.publish_resource_event(
        domain: "hr",
        resource_type: "hr:Employee",
        resource_id: "e-1",
        event: "boom",
        payload: {"id" => ::JSON::Any.new("e-1")},
      )

      # The registry rescue swallows the error (the publish does not
      # raise), and counts exactly one dropped message.
      snapshot = Event::Loss.snapshot
      snapshot["publish_flush_failures"].should eq(0)
      snapshot["messages_dropped"].should eq(1)
    end
  end
end
