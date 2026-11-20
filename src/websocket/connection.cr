# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http"
require "../rbac/auth_context"
require "../rbac/active_role"
require "../event/message"
require "./subscription_resolver"
require "./manager"

module Facet
  module Websocket
    # Minimal bidirectional socket abstraction used by `Connection`.
    #
    # Decouples `Connection` from `::HTTP::WebSocket` so specs can substitute
    # an in-memory double without inheriting from the stdlib class. Return
    # types intentionally left unannotated — concrete `HTTP::WebSocket`
    # implementations return the proc they stored, which is fine for callers
    # that only care about the registration side effect.
    module Socket
      abstract def on_message(&block : String ->)
      abstract def on_close(&block : ::HTTP::WebSocket::CloseCode, String ->)
      abstract def run
      abstract def send(message : String)
      abstract def close
    end

    # Make the stdlib WebSocket conform to our `Socket` protocol.
    class ::HTTP::WebSocket
      include Facet::Websocket::Socket
    end

    # Wraps a single HTTP::WebSocket connection and handles the frame-level
    # protocol for subscribe/unsubscribe actions.
    #
    # ## Concurrency model
    #
    # Each connection owns two fibers driven by `#run`:
    #
    #   - **Read fiber** — `@socket.run` pumps incoming frames; `#handle_frame`
    #     and `#handle_subscribe` run on it. It can block on a slow client's
    #     reads without affecting anyone else.
    #   - **Writer fiber** — drains `@mailbox` and writes outgoing fanout
    #     payloads to the socket one at a time, preserving per-connection
    #     ordering. A slow socket only stalls its own writer.
    #
    # `Manager#dispatch` does not call `socket.send` directly; it enqueues the
    # message into each connection's mailbox via `#deliver`, which is
    # non-blocking. This isolates clients: a stalled writer cannot block the
    # Fanout dispatch loop or other subscribers on the same channel.
    #
    # ## Incoming frame protocol (JSON text)
    #
    #   {"action": "subscribe",   "args": ["/hr/Employee/e1", ...]}
    #   {"action": "unsubscribe", "args": ["/hr/Employee/e1"]}
    #   {"action": "unsubscribe", "args": ["*"]}
    #
    # ## Outgoing frame shape (on fanout message)
    #
    #   {
    #     "channel": "fanout:hr.Employee:hr.Employee.e1",
    #     "event":   "updated",
    #     "payload": {"id": "hr.Employee.e1"},
    #     "headers": {"mutation_id": "01J...", "actioner_id": "user_1",
    #                 "domain": "hr", "doc_type": "Employee"}
    #   }
    class Connection
      include Connectable

      Log = ::Log.for("facet.websocket.connection")

      # Maximum number of undelivered fanout messages queued per connection.
      # When exceeded, the client is considered too slow to keep up and the
      # connection is closed (the frontend reconnects automatically).
      MAILBOX_CAPACITY = 64

      getter socket : Socket
      getter auth_context : RBAC::AuthContext
      getter subscribed_channels : Set(String)

      # True once `cleanup` has run. Useful for tests asserting a connection
      # has been torn down after the writer fiber hit an error path.
      def closed? : Bool
        @closed
      end

      @mailbox : Channel(Event::Message)
      @closed = false

      def initialize(@socket : Socket, @auth_context)
        @subscribed_channels = Set(String).new
        @mailbox = Channel(Event::Message).new(MAILBOX_CAPACITY)
      end

      # Enter the read loop and spawn the writer fiber. Returns when the
      # socket closes; guarantees that the writer fiber has been started and
      # that cleanup runs exactly once.
      def run : Nil
        spawn name: "ws-writer" do
          writer_loop
        end

        @socket.on_message do |data|
          handle_frame(data)
        end

        @socket.on_close do |_, _|
          cleanup
        end

        @socket.run
      ensure
        cleanup
      end

      # Enqueue a fanout message for delivery to the socket. Non-blocking: if
      # the mailbox is full, the client is too slow and the connection is
      # closed. Never raises `IO::Error` — write failures surface in the
      # writer fiber.
      def deliver(message : Event::Message) : Nil
        return if @closed
        select
        when @mailbox.send(message)
        else
          Log.warn { "Mailbox full — closing slow client" }
          cleanup
        end
      end

      # Close the socket, terminate the writer fiber, and unregister from the
      # Manager. Idempotent: safe to call from the read fiber, writer fiber,
      # and `Manager#dispatch` (mailbox-full) path.
      def close : Nil
        cleanup
      end

      # ── Frame processing ─────────────────────────────────────────────────

      # Process an incoming JSON text frame. Called from the socket's
      # on_message callback.
      def handle_frame(data : String) : Nil
        parsed = JSON.parse(data) rescue nil
        if parsed.nil? || !parsed.is_a?(JSON::Any)
          send_error("Invalid JSON frame")
          return
        end

        action = parsed["action"]?.try(&.as_s?)
        args_raw = parsed["args"]?

        if action.nil? || args_raw.nil?
          send_error("Missing 'action' or 'args' in frame")
          return
        end

        # `args_raw` is a `JSON::Any` wrapper — test the wrapped value
        # with `as_a?`, not `is_a?(Array)` (the wrapper is never an Array).
        args = if raw_args = args_raw.as_a?
                 raw_args.map(&.as_s)
               else
                 send_error("'args' must be an array of strings")
                 return
               end

        case action
        when "subscribe"
          handle_subscribe(args)
        when "unsubscribe"
          handle_unsubscribe(args)
        else
          send_error("Unknown action '#{action}'")
        end
      end

      # ── Private ──────────────────────────────────────────────────────────

      private def writer_loop : Nil
        loop do
          msg = @mailbox.receive?
          break if msg.nil? # mailbox closed → shutdown

          begin
            @socket.send(build_facet(msg).to_json)
          rescue e : IO::Error
            Log.warn { "Write error in writer fiber — closing socket: #{e.message}" }
            break
          end
        end
      ensure
        begin
          @socket.close
        rescue IO::Error
        end
        cleanup
      end

      private def build_facet(message : Event::Message)
        event_name = message.headers["event"]?.try(&.as_s)
        {
          channel: message.channel,
          event:   event_name,
          payload: message.content,
          headers: message.headers,
        }
      end

      private def handle_subscribe(paths : Array(String)) : Nil
        paths.each do |path|
          # Self-subscription: no document resolution, no DB. The channel
          # is the caller's own notifications channel — derived from the
          # authenticated principal, so no cross-account access is
          # possible. App-scoped principals are refused: the feed sits
          # outside the app grant (`notifications_authorized?`).
          if SubscriptionResolver.notifications_path?(path)
            unless SubscriptionResolver.notifications_authorized?(@auth_context)
              send_error("not found or forbidden", path: path)
              next
            end
            channel = SubscriptionResolver.notifications_channel(@auth_context)
            Manager.instance.register(self, channel)
            @subscribed_channels << channel
            next
          end

          Facet::Database.with_db(:read_only) do |db|
            resolved = SubscriptionResolver.resolve_and_authorize(db, path, @auth_context)
            case resolved
            in SubscriptionResolver::Resolved
              if resolved.collection?
                cap = Facet::Config.instance.websocket.collection.max_subscribers_per_doctype
                registered = Manager.instance.register(self, resolved.fanout_channel, cap: cap)
                unless registered
                  # Over-cap: the socket stays open and the client may retry
                  # (e.g. after other subscribers drop off).
                  send_error("too many subscribers for this collection", path: path)
                  next
                end
              else
                Manager.instance.register(self, resolved.fanout_channel)
              end
              @subscribed_channels << resolved.fanout_channel
            in Facet::ServiceError
              send_error(resolved.message, path: path)
            end
          end
        end
      end

      private def handle_unsubscribe(paths : Array(String)) : Nil
        if paths == ["*"]
          Manager.instance.unregister_all(self)
          @subscribed_channels.clear
          return
        end

        paths.each do |path|
          if SubscriptionResolver.notifications_path?(path)
            channel = SubscriptionResolver.notifications_channel(@auth_context)
            Manager.instance.unregister(self, channel)
            @subscribed_channels.delete(channel)
            next
          end

          channel = SubscriptionResolver.resolve_channel(path)
          if channel
            Manager.instance.unregister(self, channel)
            @subscribed_channels.delete(channel)
          else
            send_error("Invalid path '#{path}'")
          end
        end
      end

      private def send_error(message : String, path : String? = nil) : Nil
        payload = {"error" => message}
        payload = payload.merge({"path" => path}) if path
        @socket.send(payload.to_json)
      rescue IO::Error
        # Socket is closing; ignore.
      end

      private def cleanup : Nil
        return if @closed
        @closed = true

        @mailbox.close
        Manager.instance.unregister_all(self)
        Manager.instance.untrack(self)
        begin
          @socket.close
        rescue IO::Error
          # Already closed — ignore.
        end
      end
    end
  end
end
