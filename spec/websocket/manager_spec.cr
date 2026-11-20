# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/websocket"
require "../../src/event/subscriber/fanout"

# A fake Fanout that records subscribe/unsubscribe calls and never opens
# a Redis connection.
class FakeFanout
  include Facet::Websocket::Subscribable

  getter commands : Array({Symbol, String})

  def initialize
    @commands = [] of {Symbol, String}
  end

  def subscribe(channel : String) : Nil
    @commands << {:subscribe, channel}
  end

  def unsubscribe(channel : String) : Nil
    @commands << {:unsubscribe, channel}
  end

  def start : Nil
  end

  def stop : Nil
  end

  def started? : Bool
    true
  end
end

# A fake Connection that tracks what channels it receives
class FakeConnection
  include Facet::Websocket::Connectable

  getter auth_context : Facet::RBAC::AuthContext
  getter subscribed_channels : Set(String)
  getter delivered_messages : Array(Facet::Event::Message)

  # Set by `close` so the shutdown specs can assert a connection was closed.
  getter? closed = false

  def initialize
    @auth_context = Facet::RBAC::AuthContext.system
    @subscribed_channels = Set(String).new
    @delivered_messages = [] of Facet::Event::Message
  end

  def deliver(message : Facet::Event::Message) : Nil
    @delivered_messages << message
  end

  def close : Nil
    @closed = true
  end
end

describe Facet::Websocket::Manager do
  describe "register and unregister" do
    it "registers a connection and subscribes to the fanout channel" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = FakeConnection.new

      manager.register(conn, "fanout:hr.Employee:e1")

      manager.listened_resources.has_key?("fanout:hr.Employee:e1").should be_true
      manager.listened_resources["fanout:hr.Employee:e1"].includes?(conn).should be_true
      fanout.commands.should contain({:subscribe, "fanout:hr.Employee:e1"})
    end

    it "unregisters a connection and unsubscribes when set becomes empty" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = FakeConnection.new

      manager.register(conn, "fanout:hr.Employee:e1")
      manager.unregister(conn, "fanout:hr.Employee:e1")

      manager.listened_resources.has_key?("fanout:hr.Employee:e1").should be_false
      fanout.commands.should contain({:unsubscribe, "fanout:hr.Employee:e1"})
    end

    it "does not subscribe twice when a second connection registers for the same channel" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn1 = FakeConnection.new
      conn2 = FakeConnection.new

      manager.register(conn1, "fanout:hr.Employee:e1")
      manager.register(conn2, "fanout:hr.Employee:e1")

      subscribe_calls = fanout.commands.count({:subscribe, "fanout:hr.Employee:e1"})
      subscribe_calls.should eq(1)
    end

    it "does not unsubscribe while other connections remain on the channel" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn1 = FakeConnection.new
      conn2 = FakeConnection.new

      manager.register(conn1, "fanout:hr.Employee:e1")
      manager.register(conn2, "fanout:hr.Employee:e1")
      manager.unregister(conn1, "fanout:hr.Employee:e1")

      manager.listened_resources.has_key?("fanout:hr.Employee:e1").should be_true
      unsub_calls = fanout.commands.count({:unsubscribe, "fanout:hr.Employee:e1"})
      unsub_calls.should eq(0)
    end
  end

  describe "unregister_all" do
    it "removes a connection from all channels it is subscribed to" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = FakeConnection.new
      conn.subscribed_channels << "fanout:hr.Employee:e1"
      conn.subscribed_channels << "fanout:hr.Employee:e2"

      manager.register(conn, "fanout:hr.Employee:e1")
      manager.register(conn, "fanout:hr.Employee:e2")
      manager.unregister_all(conn)

      manager.listened_resources.empty?.should be_true
    end
  end

  describe "dispatch" do
    it "delivers a message to all registered connections" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn1 = FakeConnection.new
      conn2 = FakeConnection.new

      manager.register(conn1, "fanout:hr.Employee:e1")
      manager.register(conn2, "fanout:hr.Employee:e1")

      msg = Facet::Event::Message.unpack(
        %({"i":"msg-1","c":{"id":"e1"},"h":{"event":"updated"}})
      )
      manager.dispatch("fanout:hr.Employee:e1", msg)

      conn1.delivered_messages.size.should eq(1)
      conn2.delivered_messages.size.should eq(1)
    end

    it "does not crash when dispatching to a channel with no listeners" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)

      msg = Facet::Event::Message.unpack(
        %({"i":"msg-2","c":{"id":"e1"},"h":{"event":"updated"}})
      )
      manager.dispatch("fanout:nonexistent", msg)
      # No exception — pass
    end
  end

  describe "singleton" do
    it "raises when accessed before being set" do
      expect_raises(Exception, "not initialized") do
        # Clear the class variable through internal reset mechanism
        Facet::Websocket::Manager.instance
      end
    end

    it "returns the set instance" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      Facet::Websocket::Manager.instance = manager
      Facet::Websocket::Manager.instance.should be(manager)
    end

    it "exposes a nilable instance? that never raises" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      Facet::Websocket::Manager.instance = manager
      Facet::Websocket::Manager.instance?.should be(manager)
      Facet::Websocket::Manager.instance = nil
      Facet::Websocket::Manager.instance?.should be_nil
    end
  end

  describe "connection tracking" do
    it "tracks and untracks a connection" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = FakeConnection.new

      manager.track(conn)
      manager.connections.includes?(conn).should be_true

      manager.untrack(conn)
      manager.connections.includes?(conn).should be_false
    end

    it "untrack is idempotent" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = FakeConnection.new

      manager.track(conn)
      manager.untrack(conn)
      manager.untrack(conn)

      manager.connections.size.should eq(0)
    end
  end

  describe "close_all" do
    it "closes every tracked connection, including sockets with no subscriptions" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      subscribed = FakeConnection.new
      idle = FakeConnection.new

      # The idle connection never registered a channel — before tracking it
      # was invisible to the manager, and an open idle socket still holds
      # the HTTP in-flight count up during shutdown.
      manager.track(subscribed)
      manager.track(idle)
      manager.register(subscribed, "fanout:hr.Employee:e1")

      manager.close_all

      subscribed.closed?.should be_true
      idle.closed?.should be_true
    end

    it "closes nothing when no connection is live" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)

      manager.close_all

      fanout.commands.size.should eq(0)
    end

    it "does not fail when one connection raises on close" do
      fanout = FakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      healthy = FakeConnection.new
      raising = RaisingConnection.new

      # One socket wedged mid-write must not stop the others from closing.
      manager.track(raising)
      manager.track(healthy)

      manager.close_all

      healthy.closed?.should be_true
    end
  end
end

# A connection whose `close` raises — for the close_all error-isolation path.
class RaisingConnection
  include Facet::Websocket::Connectable

  getter auth_context : Facet::RBAC::AuthContext
  getter subscribed_channels : Set(String)

  def initialize
    @auth_context = Facet::RBAC::AuthContext.system
    @subscribed_channels = Set(String).new
  end

  def deliver(message : Facet::Event::Message) : Nil
  end

  def close : Nil
    raise IO::Error.new("wedged socket")
  end
end
