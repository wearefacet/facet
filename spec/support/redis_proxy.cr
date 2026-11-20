# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Redis TCP proxy ─────────────────────────────────────────────────────────
#
# A minimal TCP proxy between the spec process and the real Redis server,
# used by the stream-outage regression specs: the subscriber connects through
# the proxy, and the spec pauses the proxy to simulate a Redis outage without
# stopping the real server. Byte-transparent — the Redis protocol passes
# through untouched.

require "uri"
require "socket"

class RedisProxy
  @target : URI
  @listener : TCPServer?
  @clients = Set(TCPSocket).new
  @mutex = Mutex.new
  @port = 0

  def initialize(target_url : String)
    @target = URI.parse(target_url)
  end

  # Binds the listener (the first call picks an ephemeral port, later calls
  # rebind the same port) and starts accepting client connections. Returns
  # the Redis URL clients should use — the target URL pointed at the proxy,
  # so path (db) and credentials are preserved.
  def start : String
    @listener = TCPServer.new("127.0.0.1", @port)
    @port = @listener.not_nil!.local_address.port
    spawn(name: "RedisProxy accept (:#{@port})") { accept_loop }
    # Return the target URL pointed at the proxy — path (db) and credentials
    # preserved. The target itself stays untouched: the pumps still dial it.
    url = URI.parse(@target.to_s)
    url.host = "127.0.0.1"
    url.port = @port
    url.to_s
  end

  # Simulates an outage: closes the listener and every live client socket.
  # In-flight proxy connections die and reconnect attempts are refused
  # until `resume`.
  def pause : Nil
    @listener.try(&.close)
    @listener = nil
    sockets = @mutex.synchronize do
      live = @clients.to_a
      @clients.clear
      live
    end
    sockets.each(&.close)
  end

  # Reopens the listener on the same port.
  def resume : Nil
    start
  end

  # Full teardown for spec cleanup.
  def close : Nil
    pause
  end

  private def accept_loop : Nil
    loop do
      listener = @listener
      break if listener.nil? || listener.closed?

      client = listener.accept?
      break if client.nil?

      @mutex.synchronize { @clients << client }
      pump(client)
    end
  end

  # Opens the upstream connection and relays in both directions.
  private def pump(client : TCPSocket) : Nil
    upstream = TCPSocket.new(@target.host || "127.0.0.1", @target.port || 6379)
    spawn(name: "RedisProxy pump c→r (:#{@port})") { relay(client, upstream) }
    spawn(name: "RedisProxy pump r→c (:#{@port})") { relay(upstream, client) }
  rescue
    # The backend refused the connection: drop the client so the caller
    # observes the refusal instead of a silent hang.
    drop(client)
  end

  # Copies bytes in one direction until EOF or error, then closes both ends
  # so the sibling relay and the subscriber notice. An IO::Error here is the
  # expected teardown path (pause closes the client side) — swallowed.
  private def relay(from : TCPSocket, to : TCPSocket) : Nil
    IO.copy(from, to)
  rescue IO::Error | Socket::Error
    nil
  ensure
    drop(from)
    drop(to)
  end

  private def drop(socket : TCPSocket) : Nil
    socket.close rescue nil
    @mutex.synchronize { @clients.delete(socket) }
  end
end
