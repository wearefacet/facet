# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../event/subscriber/fanout"
require "../event/message"
require "../config"
require "../database"
require "../rbac/read_enforcer"

module Facet
  module Websocket
    # Protocol that any pub/sub driver must satisfy so that tests can inject
    # a fake instead of a real Redis-backed Fanout.
    module Subscribable
      abstract def subscribe(channel : String) : Nil
      abstract def unsubscribe(channel : String) : Nil
      abstract def start : Nil
      abstract def stop : Nil
      abstract def started? : Bool
    end

    # Protocol that any connection-like object must satisfy.
    #
    # `deliver` enqueues a message for the connection to send. It must be
    # non-blocking and must not raise `IO::Error` — write failures are the
    # connection's responsibility (e.g. surfaced in a dedicated writer fiber).
    #
    # `auth_context` is required so the collection-channel dispatch branch
    # can run the per-emit RBAC filter without downcasting.
    module Connectable
      getter subscribed_channels : Set(String)

      abstract def auth_context : Facet::RBAC::AuthContext
      abstract def deliver(message : Event::Message) : Nil
      abstract def close : Nil
    end
  end
end

# Make Fanout conform to the Subscribable protocol for testability.
class Facet::Event::Subscriber::Fanout
  include Facet::Websocket::Subscribable
end

module Facet
  module Websocket
    # Process-singleton manager that owns the fanout pub/sub driver and tracks
    # every subscription across all active WebSocket connections.
    #
    # ## Thread safety
    #
    # All mutation of `@listened_resources` happens under `@mutex`. The
    # `dispatch` path snapshots the connection set under the mutex, then
    # enqueues to each connection's mailbox outside it. `deliver` is
    # non-blocking and never raises `IO::Error` — write failures surface in
    # each connection's own writer fiber, which self-cleans via
    # `unregister_all`. There is no reentrancy concern from deliver raising.
    class Manager
      Log = ::Log.for("facet.websocket.manager")

      # Key = fanout channel, value = set of registered connections.
      getter listened_resources : Hash(String, Set(Connectable))

      # Every live connection, tracked when the route accepts the upgrade
      # and untracked in `Connection#cleanup` — including sockets with no
      # subscriptions, which never appear in `listened_resources`. Lets
      # shutdown close idle sockets too (an open socket holds the HTTP
      # in-flight count up regardless of subscriptions).
      getter connections : Set(Connectable)

      # The injected pub/sub driver (e.g. Event::Subscriber::Fanout or a test double).
      getter fanout : Subscribable

      # ── Singleton ────────────────────────────────────────────────────────

      @@instance : Manager?

      def self.instance : Manager
        @@instance || raise "Websocket::Manager not initialized"
      end

      # Nilable variant of `instance` for paths that must not raise — the
      # shutdown handler closes whatever connections exist, and does nothing
      # when the manager never booted.
      def self.instance? : Manager?
        @@instance
      end

      def self.instance=(mgr : Manager?) : Nil
        @@instance = mgr
      end

      # ── Construction ─────────────────────────────────────────────────────

      def initialize(@fanout : Subscribable)
        @listened_resources = {} of String => Set(Connectable)
        @connections = Set(Connectable).new
        @mutex = Mutex.new
      end

      # Start the underlying Fanout subscriber (spawns its control fiber).
      def start : Nil
        @fanout.start
      end

      # Stop the underlying Fanout subscriber (closes connection, joins
      # the control fiber).
      def stop : Nil
        @fanout.stop
      end

      # ── Connection tracking ──────────────────────────────────────────────

      # Marks a connection live. Called by the `/Ws` route as soon as the
      # connection is built; the matching `untrack` runs in `cleanup`.
      def track(connection : Connectable) : Nil
        @mutex.synchronize { @connections << connection }
      end

      # Marks a connection dead. Idempotent — safe to call more than once
      # for the same connection (e.g. from `cleanup` after `close_all`).
      def untrack(connection : Connectable) : Nil
        @mutex.synchronize { @connections.delete(connection) }
      end

      # Closes every live connection with a close frame — the graceful
      # shutdown path (see `Facet::Shutdown`). Snapshots under the mutex and
      # closes outside it: `Connection#close` re-enters the manager through
      # `unregister_all` / `untrack`, which take the same mutex. One failing
      # close must not stop the remaining sockets from being closed.
      def close_all : Nil
        snapshot = @mutex.synchronize { @connections.dup }
        return if snapshot.empty?
        Log.info { "Closing #{snapshot.size} WebSocket connection(s) for shutdown" }
        snapshot.each do |conn|
          conn.close
        rescue e : Exception
          Log.error { "Error closing WebSocket connection: #{e.class}: #{e.message}" }
        end
      end

      # ── Subscription lifecycle ───────────────────────────────────────────

      # Register a connection for a fanout channel.
      #
      # When the channel's subscriber count goes from zero to one, a
      # Redis SUBSCRIBE is issued through the Fanout.
      #
      # `cap` bounds the subscriber count for the channel (used for
      # collection channels — see `websocket.collection` config). When the
      # channel already holds `cap` subscribers, the registration is
      # rejected and `false` is returned; the underlying pub/sub is NOT
      # subscribed to and the caller surfaces an error to the client. The
      # socket stays open so the client may retry.
      def register(connection, channel : String, cap : Int32? = nil) : Bool
        @mutex.synchronize do
          set = @listened_resources[channel] ||= Set(Connectable).new

          if cap && set.size >= cap
            Log.warn { "Collection channel #{channel} at cap (#{cap}) — rejecting register" }
            return false
          end

          was_empty = set.empty?
          set << connection

          if was_empty
            @fanout.subscribe(channel)
            Log.debug { "Started listening on #{channel}" }
          end
        end
        true
      end

      # Unregister a connection from a fanout channel.
      #
      # When the subscriber count drops to zero, the channel key is deleted
      # and a Redis UNSUBSCRIBE is issued through the Fanout.
      def unregister(connection, channel : String) : Nil
        @mutex.synchronize do
          set = @listened_resources[channel]?
          return if set.nil?

          set.delete(connection)

          if set.empty?
            @listened_resources.delete(channel)
            @fanout.unsubscribe(channel)
            Log.debug { "Stopped listening on #{channel}" }
          end
        end
      end

      # Remove a connection from all channels it was subscribed to.
      #
      # Called when a socket closes or encounters a write error.
      def unregister_all(connection) : Nil
        channels = connection.subscribed_channels.dup
        channels.each do |ch|
          unregister(connection, ch)
        end
      end

      # ── Message dispatch ─────────────────────────────────────────────────

      # Called by the Fanout handler block when a message arrives on a
      # subscribed pub/sub channel. Dispatches to every registered connection
      # by enqueuing the message into each connection's mailbox. Non-blocking:
      # a stalled writer on one connection cannot delay delivery to other
      # subscribers on the same channel.
      #
      # Collection channels (`fanout:{domain}.{doc_type}` — no trailing
      # `:id`) take the filtered path: each non-system connection's RBAC
      # read scope is re-evaluated against the projection row before
      # delivery, so a role change on an open connection takes effect on
      # the next mutation. Aggregate `child_changed` frames on per-document
      # channels take their own filtered path (the frame is keyed to the
      # parent, but subscribe-time RBAC covered only the parent). Every
      # other per-document and notification channel takes the
      # direct-deliver fast path (RBAC was enforced at subscribe time).
      def dispatch(channel : String, message : Event::Message) : Nil
        conns = @mutex.synchronize do
          @listened_resources[channel]?.try(&.dup)
        end
        return if conns.nil?

        if collection_channel?(channel)
          dispatch_collection(channel, message, conns)
          return
        end

        if child_changed?(message)
          dispatch_child_changed(channel, message, conns)
          return
        end

        conns.each do |conn|
          conn.deliver(message)
        rescue e : Exception
          Log.error { "Dispatch error: #{e.message}" }
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # True for collection channels: `fanout:{domain}.{doc_type}`. The
      # per-document (`fanout:...:doc_id`), notification
      # (`fanout:notifications:...`), and keepalive sentinel channels all
      # carry a second `:` segment.
      private def collection_channel?(channel : String) : Bool
        channel.starts_with?("fanout:") && channel.count(':') == 1
      end

      # True for aggregate child-change frames: the event name rides the
      # headers (set at publish time).
      private def child_changed?(message : Event::Message) : Bool
        message.headers["event"]?.try(&.as_s?) == Facet::Event::CHILD_CHANGED
      end

      # Filtered dispatch for aggregate `child_changed` frames on
      # per-document channels. The frame is keyed to the PARENT (the
      # channel the subscriber chose), but it names a CHILD mutation —
      # subscribe-time RBAC covered only the parent, so each non-system
      # connection's read scope is re-evaluated against the child document
      # (one `ReadEnforcer.authorized?` per connection). The child identity
      # comes from the payload's `child` pointer; the domain rides the
      # headers (child and parent share the domain). A `false` check
      # suppresses delivery to that connection with no error frame —
      # non-disclosing. A frame without a usable child pointer is dropped.
      # A failed check (e.g. the child row hard-gone mid-flight) is logged
      # and only skips that connection.
      #
      # NOTE: like `dispatch_collection`, this runs on the Fanout control
      # fiber — one per process — so the per-frame cost is serialized
      # behind ALL fanout delivery.
      private def dispatch_child_changed(
        channel : String,
        message : Event::Message,
        conns : Set(Connectable),
      ) : Nil
        domain = message.headers["domain"]?.try(&.as_s?)
        child = message.content.as_h?.try(&.["child"]?).try(&.as_h?)
        child_doc_type = child.try(&.["doc_type"]?).try(&.as_s?)
        child_doc_id = child.try(&.["doc_id"]?).try(&.as_s?)
        unless domain && child_doc_type && child_doc_id
          Log.warn { "child_changed frame without a child pointer on #{channel} — dropped" }
          return
        end

        checked = [] of Connectable
        conns.each do |conn|
          # The system principal bypasses RBAC (same short-circuit
          # `ReadEnforcer` uses internally).
          if conn.auth_context.system?
            deliver_safely(conn, message)
          else
            checked << conn
          end
        end
        return if checked.empty?

        Facet::Database.with_db(:read_only) do |db|
          checked.each do |conn|
            begin
              if RBAC::ReadEnforcer.authorized?(db, domain, child_doc_type, child_doc_id, conn.auth_context)
                conn.deliver(message)
              end
            rescue e : Exception
              # One failing check (e.g. the child row hard-gone
              # mid-flight) must not abort delivery to the remaining
              # connections on the channel.
              Log.error { "child_changed RBAC filter error on #{channel}: #{e.message}" }
            end
          end
        end
      end

      # Filtered dispatch for a collection channel. One DB connection is
      # checked out for the whole message; each non-system connection pays
      # one `ReadEnforcer.authorized?` check (fetch-then-check against the
      # projection row). A `false` suppresses delivery to that connection
      # with no error frame — non-disclosing. A failed check (e.g. the row
      # hard-gone mid-flight) is logged and only skips that connection.
      #
      # NOTE: this runs on the Fanout control fiber — one per process — so
      # the per-message cost is serialized behind ALL fanout delivery.
      # The `websocket.collection.max_subscribers_per_doctype` cap bounds
      # it; see `doc/backend/websocket.md` for the cost model.
      private def dispatch_collection(
        channel : String,
        message : Event::Message,
        conns : Set(Connectable),
      ) : Nil
        name = channel["fanout:".size..]
        dot = name.index('.')
        unless dot && dot > 0
          Log.warn { "Collection channel without a doctype segment: #{channel} — dropped" }
          return
        end
        domain = name[0...dot]
        doc_type = name[(dot + 1)..]

        doc_id = message.content.as_h?.try(&.["id"]?).try(&.as_s?)
        unless doc_id
          Log.warn { "Collection message without a document id on #{channel} — dropped" }
          return
        end

        checked = [] of Connectable
        conns.each do |conn|
          # The system principal bypasses RBAC (same short-circuit
          # `ReadEnforcer` uses internally).
          if conn.auth_context.system?
            deliver_safely(conn, message)
          else
            checked << conn
          end
        end
        return if checked.empty?

        Facet::Database.with_db(:read_only) do |db|
          checked.each do |conn|
            begin
              if RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, conn.auth_context)
                conn.deliver(message)
              end
            rescue e : Exception
              # One failing check (e.g. the projection row hard-gone
              # mid-flight) must not abort delivery to the remaining
              # connections on the channel.
              Log.error { "Collection RBAC filter error on #{channel}: #{e.message}" }
            end
          end
        end
      end

      private def deliver_safely(conn : Connectable, message : Event::Message) : Nil
        conn.deliver(message)
      rescue e : Exception
        Log.error { "Dispatch error: #{e.message}" }
      end
    end
  end
end
