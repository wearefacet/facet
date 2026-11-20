# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

describe Facet::Event::InProcessManager do
  describe "fanout publication" do
    it "stores the event on both the resource channel and the fanout channel" do
      manager = Facet::Event::InProcessManager.new

      manager.publish_resource_event(
        domain: "hr",
        resource_type: "hr:Employee",
        resource_id: "emp-123",
        event: "hired",
        payload: {"name" => ::JSON::Any.new("Alice")}
      )

      # Resource channel
      resource_channel = "FACET:RESOURCE:hr:Employee"
      resource_events = manager.events_for(resource_channel)
      resource_events.size.should eq(1)

      # Fanout channel
      fanout_channel = "fanout:hr.Employee:emp-123"
      fanout_events = manager.events_for(fanout_channel)
      fanout_events.size.should eq(1)

      fanout_events[0].content["name"].should eq(::JSON::Any.new("Alice"))
      fanout_events[0].headers["event"]?.try(&.as_s).should eq("hired")
    end

    it "uses the correct fanout channel format per domain and resource_id" do
      manager = Facet::Event::InProcessManager.new

      manager.publish_resource_event(
        domain: "finance",
        resource_type: "finance:Invoice",
        resource_id: "inv-456",
        event: "paid",
        payload: {"amount" => ::JSON::Any.new(500_i64)}
      )

      fanout_events = manager.events_for("fanout:finance.Invoice:inv-456")
      fanout_events.size.should eq(1)
      fanout_events[0].content["amount"].should eq(::JSON::Any.new(500_i64))
    end

    it "handles resource_type without colon separator" do
      manager = Facet::Event::InProcessManager.new

      manager.publish_resource_event(
        domain: "core",
        resource_type: "core:DocType",
        resource_id: "hr.Employee",
        event: "registered",
        payload: {"doctype" => ::JSON::Any.new("hr.Employee")}
      )

      fanout_events = manager.events_for("fanout:core.DocType:hr.Employee")
      fanout_events.size.should eq(1)
    end
  end

  describe "clear!" do
    it "resets events after clear" do
      manager = Facet::Event::InProcessManager.new

      manager.publish_resource_event(
        domain: "test", resource_type: "test:Item", resource_id: "item-1",
        event: "created", payload: {} of String => ::JSON::Any
      )
      manager.events_for("fanout:test.Item:item-1").size.should eq(1)

      manager.clear!
      manager.events_for("fanout:test.Item:item-1").size.should eq(0)
    end
  end
end
