# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/event"

# The CLI publication contract. A CLI command has no boot-time event
# manager: its document mutations buffer into the fiber-local queue and
# `CLI.dispatch` publishes them after the command returns —
# `ensure_config_manager` installs a config-built manager when none is
# set, and `flush!` publishes fail-loud (a CLI process dies right after,
# so a counted loss would be invisible to the operator).
#
# The suite runs with the spec_helper `InProcessManager` installed; these
# specs keep it and assert against its in-memory store. The raising stub
# is the same one `spec/event/loss_spec.cr` defines — that file is not
# always required, so this spec carries its own copy.
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
  describe Event::Publisher do
    describe ".ensure_config_manager" do
      it "keeps an already-installed manager" do
        suite_manager = Event::Publisher.manager
        suite_manager.should_not be_nil

        Event::Publisher.ensure_config_manager

        Event::Publisher.manager.should eq(suite_manager)
      end

      it "installs a manager when the process has none" do
        previous = Event::Publisher.manager
        Event::Publisher.manager = nil
        begin
          Event::Publisher.ensure_config_manager
          Event::Publisher.manager.should_not be_nil
          Event::Publisher.manager.as(Event::Manager).service_id
            .should eq(Facet::Service.service_id("facet-cli"))
        ensure
          Event::Publisher.manager = previous
        end
      end
    end

    describe ".flush!" do
      # Captured by the hooks — restored after each example so the stub
      # never leaks into other specs.
      previous_manager = Event::Publisher.manager

      before_each do
        previous_manager = Event::Publisher.manager
        Event::Publisher.discard
      end

      after_each do
        Event::Publisher.manager = previous_manager
        Event::Publisher.discard
      end

      it "publishes the queued events and drains the queue" do
        manager = Event::Publisher.manager.as(Event::InProcessManager)

        Event::Publisher.enqueue("hr", "Employee", "e-1", "created")
        Event::Publisher.enqueue("hr", "Employee", "e-2", "updated")
        Event::Publisher.pending_count.should eq(2)

        Event::Publisher.flush!

        Event::Publisher.pending_count.should eq(0)
        manager.events_for("fanout:hr.Employee:e-1").size.should eq(1)
        manager.events_for("fanout:hr.Employee:e-2").size.should eq(1)
      end

      it "re-raises when the manager cannot publish" do
        raising = RaisingInProcessManager.new
        raising.raise_on_publish = true
        Event::Publisher.manager = raising

        Event::Publisher.enqueue("hr", "Employee", "e-1", "created")

        expect_raises(Exception, "stub publish failure") do
          Event::Publisher.flush!
        end
        # A failed publish still discards the queue — at-most-once.
        Event::Publisher.pending_count.should eq(0)
      end

      it "raises when no manager is installed" do
        previous = Event::Publisher.manager
        Event::Publisher.manager = nil
        begin
          Event::Publisher.enqueue("hr", "Employee", "e-1", "created")
          expect_raises(Exception, "manager is not set") do
            Event::Publisher.flush!
          end
        ensure
          Event::Publisher.manager = previous
        end
      end
    end
  end
end
