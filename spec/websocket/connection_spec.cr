# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/websocket"
require "../../src/event/subscriber/fanout"

# Minimal in-memory `Facet::Websocket::Socket` double that records
# every frame sent to it. `run` blocks on a channel until `close` is called,
# mirroring the real socket lifecycle without requiring a real TCP connection.
class FakeWebSocket
  include Facet::Websocket::Socket

  getter sent : Array(String)
  getter on_message_callback : (String ->)?
  getter on_close_callback : (::HTTP::WebSocket::CloseCode, String ->)?
  @done : Channel(Nil)?

  def initialize
    @sent = [] of String
    @done = Channel(Nil).new(1)
    @on_message_callback = nil
    @on_close_callback = nil
  end

  def on_message(&block : String ->)
    @on_message_callback = block
  end

  def on_close(&block : ::HTTP::WebSocket::CloseCode, String ->)
    @on_close_callback = block
  end

  def run
    @done.try &.receive?
  end

  def send(message : String)
    @sent << message
  end

  def close(code : Int? = nil, message : String? = nil)
    ch = @done
    @done = nil
    ch.try &.close
  end

  # Test helper: simulate an inbound client frame.
  def receive_frame(data : String) : Nil
    @on_message_callback.try(&.call(data))
  end

  # Test helper: true once `on_message` has been registered.
  def ready? : Bool
    !@on_message_callback.nil?
  end

  # Test helper: simulate the transport closing.
  def simulate_close : Nil
    @on_close_callback.try(&.call(::HTTP::WebSocket::CloseCode::NormalClosure, ""))
    ch = @done
    @done = nil
    ch.try &.close
  end
end

# A `Subscribable` test double so we never touch Redis.
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

# Reset the Manager singleton after each example so other spec files (e.g.
# `manager_spec.cr`'s "raises when accessed before being set" case) don't
# observe leaked state.
Spec.after_each do
  Facet::Websocket::Manager.instance = nil
end

# Install a Manager singleton backed by a FakeFanout so the Connection can
# call `Manager.instance.register/unregister_all` without touching Redis.
def install_manager : {FakeFanout, Facet::Websocket::Manager}
  fanout = FakeFanout.new
  manager = Facet::Websocket::Manager.new(fanout)
  Facet::Websocket::Manager.instance = manager
  {fanout, manager}
end

def build_ws_message(event : String = "updated", id : String = "msg-1", channel : String = "fanout:hr.Employee:e1") : Facet::Event::Message
  Facet::Event::Message.unpack(
    %({"i":"#{id}","c":{"id":"e1"},"h":{"event":"#{event}"}}),
    channel: channel
  )
end

# Wait until `predicate` returns true or the timeout elapses. The writer
# fiber runs on its own fiber, so specs that assert on its side effects
# must yield.
def eventually(timeout : Time::Span = 2.seconds, &predicate : -> Bool) : Nil
  deadline = Time.utc + timeout
  loop do
    return if predicate.call
    raise "eventually: timed out waiting for condition" if Time.utc > deadline
    Fiber.yield
    sleep 5.milliseconds
  end
end

describe Facet::Websocket::Connection do
  describe "deliver" do
    it "writes the fanout message to the socket via the writer fiber" do
      _, manager = install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      manager.register(conn, "fanout:hr.Employee:e1")
      conn.subscribed_channels << "fanout:hr.Employee:e1"

      spawn(name: "test-run") { conn.run }

      conn.deliver(build_ws_message)

      eventually { socket.sent.any?(&.includes?(%("event":"updated"))) }
      socket.sent.any?(&.includes?(%("channel":"fanout:hr.Employee))).should be_true
      socket.sent.any?(&.includes?(%("payload":{"id":"e1"}))).should be_true

      conn.close
    end

    it "preserves per-connection send order" do
      _, manager = install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      manager.register(conn, "fanout:hr.Employee:e1")
      conn.subscribed_channels << "fanout:hr.Employee:e1"

      spawn(name: "test-run") { conn.run }

      3.times do |i|
        conn.deliver(build_ws_message("event-#{i}"))
      end

      eventually { socket.sent.size >= 3 }
      events = socket.sent.compact_map do |frame|
        JSON.parse(frame)["event"]?.try(&.as_s?)
      end
      events.should eq(["event-0", "event-1", "event-2"])

      conn.close
    end

    it "closes the connection when the mailbox fills past capacity" do
      fanout, manager = install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      manager.register(conn, "fanout:hr.Employee:e1")
      conn.subscribed_channels << "fanout:hr.Employee:e1"

      spawn(name: "test-run") { conn.run }

      # Synchronously fill the mailbox past capacity without yielding to the
      # writer fiber. The (capacity + 1)th deliver hits the `else` branch of
      # the select and triggers `cleanup`.
      (Facet::Websocket::Connection::MAILBOX_CAPACITY + 1).times do
        conn.deliver(build_ws_message)
      end

      eventually { conn.closed? }
      conn.closed?.should be_true
      # cleanup → unregister_all → exactly one unsubscribe for the channel.
      fanout.commands.count({:unsubscribe, "fanout:hr.Employee:e1"}).should eq(1)
    end

    it "is idempotent on close across dispatch, writer, and read paths" do
      fanout, manager = install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      manager.register(conn, "fanout:hr.Employee:e1")
      conn.subscribed_channels << "fanout:hr.Employee:e1"

      spawn(name: "test-run") { conn.run }

      # Triple-close from different logical paths.
      conn.close
      conn.close
      socket.simulate_close

      eventually { fanout.commands.includes?({:unsubscribe, "fanout:hr.Employee:e1"}) }
      # Unsubscribe issued exactly once even after three close paths.
      fanout.commands.count({:unsubscribe, "fanout:hr.Employee:e1"}).should eq(1)
    end
  end

  describe "notifications self-subscription" do
    it "subscribes, delivers, and unsubscribes the caller's own notifications channel" do
      fanout, manager = install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      spawn(name: "test-run") { conn.run }
      eventually { socket.ready? }

      socket.receive_frame(%({"action":"subscribe","args":["/notifications"]}))
      eventually { fanout.commands.includes?({:subscribe, "fanout:notifications:system"}) }
      conn.subscribed_channels.should contain("fanout:notifications:system")

      manager.dispatch(
        "fanout:notifications:system",
        build_ws_message("notified", channel: "fanout:notifications:system"),
      )
      eventually { socket.sent.any?(&.includes?(%("event":"notified"))) }

      socket.receive_frame(%({"action":"unsubscribe","args":["/notifications"]}))
      eventually { fanout.commands.includes?({:unsubscribe, "fanout:notifications:system"}) }
      conn.subscribed_channels.should_not contain("fanout:notifications:system")

      conn.close
    end
  end

  describe "handle_frame" do
    it "replies with an error on invalid JSON" do
      install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      spawn(name: "test-run") { conn.run }
      eventually { socket.ready? }

      socket.receive_frame("not json")
      eventually { socket.sent.any?(&.includes?(%("error"))) }
      error_frame = JSON.parse(socket.sent.last)
      error_frame["error"].as_s.should contain("Invalid JSON")

      conn.close
    end

    it "replies with an error frame when 'action' or 'args' is missing" do
      install_manager
      socket = FakeWebSocket.new
      conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
      spawn(name: "test-run") { conn.run }
      eventually { socket.ready? }

      socket.receive_frame(%({"action":"subscribe"}))
      eventually { socket.sent.any?(&.includes?("Missing")) }
      error_frame = JSON.parse(socket.sent.last)
      error_frame["error"].as_s.should contain("Missing 'action' or 'args'")

      conn.close
    end
  end
end
