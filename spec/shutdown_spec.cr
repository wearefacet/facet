# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "../src/shutdown"
require "../src/websocket"
# The production HTTP stack: `Facet::Websocket::Connection`'s dependency set
# (auth handler, MCP, IAM, doctypes, …) is the whole server. Requiring the
# server entry keeps this file's requires complete in an isolated
# `crystal spec` run without tracking each transitive constant. Nothing binds
# or registers at require time — routes mount via `Facet::HTTP::Server.routes`,
# which this spec does not call.
require "../src/http/server"

# ── Graceful shutdown ───────────────────────────────────────────────────────
#
# `Facet::Shutdown` traps SIGTERM / SIGINT / SIGHUP. With the HTTP server
# running, the handler drains: `Kemal.stop` closes the listeners, then every
# tracked WebSocket connection is closed with a close frame. An open socket
# holds Kemal's in-flight count for as long as it lives, so without the close
# step the drain would run the full 30 s `shutdown_timeout` — past the
# container-orchestration grace period — and the process would be SIGKILL'd
# before `at_exit` teardown ever ran.
#
# The signal path runs in-process: the example installs the real traps,
# sends SIGTERM to its own PID, and asserts the outcome. The traps are
# process-global, but the suite process can carry them — the drain branch of
# the handler never calls `exit`, so the example survives, and the teardown
# resets the traps. The drain branch is what this spec exercises; the
# process-exit shape (`exit 0`, the `at_exit` teardown in `main.cr`) lives
# outside it.
#
# Covers the SIGTERM handling contract (`doc/backend/shutdown.md`).

private def free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

# Minimal pub/sub double — the shutdown path never touches the fanout.
private class ShutdownSpecFanout
  include Facet::Websocket::Subscribable

  def subscribe(channel : String) : Nil
  end

  def unsubscribe(channel : String) : Nil
  end

  def start : Nil
  end

  def stop : Nil
  end

  def started? : Bool
    true
  end
end

# The minimal production-shaped `/Ws` route: a tracked `Connection` on a real
# socket. Auth is fixed to the system principal — the shutdown flow never
# reads it.
private def register_ws_route : Nil
  # Same escape hatch the production route sets: Kemal rejects upgrades with
  # a missing Origin header unless the allowlist is "*" (header-capable
  # clients send none).
  Kemal.config.websocket_allowed_origins = ["*"]

  ws "/Ws" do |socket, _env|
    conn = Facet::Websocket::Connection.new(socket, Facet::RBAC::AuthContext.system)
    # Mirrors the production route: track the live socket so the shutdown
    # handler can close it (it holds the HTTP in-flight count even with no
    # subscriptions).
    Facet::Websocket::Manager.instance.track(conn)
    conn.run
  end
end

describe "Facet::Shutdown (SIGTERM)" do
  it "drains an open WebSocket connection and closes it with a close frame on SIGTERM" do
    previous_manager = Facet::Websocket::Manager.instance?
    Facet::Websocket::Manager.instance = Facet::Websocket::Manager.new(ShutdownSpecFanout.new)

    # Capture the two production log sources with sync dispatch: the default
    # async dispatcher queues entries on a background fiber, and the example
    # asserts on the buffer right after the signal — the entries must be on
    # the buffer before the assertions run.
    logs = IO::Memory.new
    backend = Log::IOBackend.new(io: logs, dispatcher: Log::DispatchMode::Sync)
    Log.builder.bind("facet.shutdown", :info, backend)
    Log.builder.bind("facet.websocket.manager", :info, backend)

    port = free_port
    register_ws_route
    Facet::Shutdown.install

    # Buffered: after the drain, the send must never block the server fiber.
    server_returned = Channel(Nil).new(1)
    spawn(name: "shutdown-spec-server") do
      Kemal.run(port: port, trap_signal: false)
      server_returned.send(nil)
    end

    ws : HTTP::WebSocket? = nil
    begin
      assert_eventually(timeout: 5.0) { Kemal.config.running }

      # Open a WebSocket client and keep it open — an open socket must not
      # wedge Kemal's drain. The first attempts may hit
      # a bound-but-not-listening socket; retry until the server accepts.
      ws = wait_for(timeout: 5.0) do
        HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:#{port}/Ws"))
      rescue Socket::ConnectError
        nil
      end
      fail "WebSocket client could not connect within 5 s" if ws.nil?

      close_code = Atomic(Int32).new(0)
      ws_closed = Channel(Nil).new
      ws.on_close do |code, _message|
        close_code.set(code.value)
        ws_closed.close
      end
      spawn(name: "shutdown-spec-ws-client") do
        ws.run
      rescue
        # Abrupt EOF — recorded through ws_closed only for the abnormal path.
        ws_closed.close
      end

      # The route fiber runs between the upgrade and `track`; wait for the
      # manager to hold the connection so the signal cannot land too early.
      assert_eventually(timeout: 5.0) do
        Facet::Websocket::Manager.instance.connections.size == 1
      end

      # Terminate the suite process and measure the graceful path.
      started = Time.instant
      Process.signal(Signal::TERM, Process.pid)

      select
      when ws_closed.receive?
        # A close frame reached the client. AbnormalClosure (1006) is what
        # the client synthesises on an abrupt EOF — its presence would mean
        # the socket dropped without a close frame.
        close_code.get.should_not eq(HTTP::WebSocket::CloseCode::AbnormalClosure.value)
      when timeout(5.seconds)
        fail "no WebSocket close frame within 5 s of SIGTERM"
      end

      # `Kemal.run` returns once the drain completes — the open socket must
      # not hold it. Before the fix the drain ran the full 30 s
      # `shutdown_timeout`. 10 s bounds the whole signal → return path with
      # generous slack for a slow CI machine.
      select
      when server_returned.receive?
      when timeout(10.seconds)
        fail "Kemal.run did not return within 10 s of SIGTERM"
      end

      elapsed = Time.instant - started
      elapsed.should be < 10.seconds

      # The clean shutdown sequence, in order: the handler logs the drain
      # start before the manager closes the connections.
      output = logs.to_s
      signal_idx = output.index("received — draining HTTP server and closing WebSocket connections")
      closing_idx = output.index("Closing 1 WebSocket connection(s) for shutdown")
      signal_idx.should_not be_nil
      closing_idx.should_not be_nil
      (signal_idx.not_nil! < closing_idx.not_nil!).should be_true
    ensure
      # Failure paths can stop here mid-drain: close the client so the route
      # fiber ends, and stop the server so the listener never leaks into
      # later examples.
      begin
        ws.try(&.close)
      rescue IO::Error
        # Socket already gone.
      end
      begin
        Kemal.stop if Kemal.config.running
      rescue
        # The drain already stopped the server.
      end
      Signal::TERM.reset
      Signal::INT.reset
      Signal::HUP.reset
      Log.builder.unbind("facet.shutdown", :info, backend)
      Log.builder.unbind("facet.websocket.manager", :info, backend)
      Facet::Websocket::Manager.instance = previous_manager
    end
  end
end

describe Facet::Shutdown do
  describe "stop_quietly" do
    it "runs the step and returns normally" do
      ran = false
      Facet::Shutdown.stop_quietly("probe step") { ran = true }
      ran.should be_true
    end

    it "logs instead of raising when the step fails" do
      Facet::Shutdown.stop_quietly("failing step") { raise "boom" }
    end
  end
end
