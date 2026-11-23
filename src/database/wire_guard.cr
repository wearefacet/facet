# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../metrics"

# ── PostgreSQL wire-state guard ────────────────────────────────────────────
#
# A pooled connection is reusable only while its wire is idle: every `Sync`
# (or simple `Query`) it sent has been matched by one `ReadyForQuery` read.
# crystal-db does not track that — an abandoned `ResultSet` (a non-block
# `rs = db.query(...)` that never reaches `rs.close`) leaves whole response
# frames queued in the socket. The next borrower then reads the previous
# borrower's response: a shape mismatch raises, but a matching shape decodes
# silently — cross-request (and cross-account) data, phantom 404s, and
# acknowledged writes that the server rejected.
#
# The guard counts the pending `ReadyForQuery` messages per connection. A
# connection that still expects one at release is closed instead of pooled,
# so a slip costs one connection, never data. A connection already lagged
# when the guard ships is healed at its next release (its counter is stuck
# above zero).
#
# ## Counter entry points
#
# - `send_sync_message` — the extended-query `Sync` terminator (every
#   `PG::Statement#perform_query` / `#perform_exec`).
# - `send_query_message` — the simple-query protocol (`PG::Connection#exec_all`,
#   `PG::CopyResult`).
# - `read_one_frame` — every frame read passes through it exactly once.
#   Hooking `read` would double-count (`read` → `handle_async_frames` →
#   `read`). The startup `ReadyForQuery` arrives before `@established` and is
#   not counted; neither is the one `handle_async_frames` consumes directly
#   from an `ErrorResponse` (same `@established` gate).
#
# `read_async_frame_loop` (LISTEN / replication) reads frames outside any
# query-response cycle. Its `ReadyForQuery` is not in the class — it can only
# appear on a polled connection, which Facet does not use — and the loop
# never sends a `Sync` / `Query`, so the count stays zero there.
#
# ## Discard point
#
# `release` is reopened on `PG::Connection` rather than on
# `DB::Connection` because crystal-db 0.14 defines `release` on the base
# class only, and a `previous_def` reopen there would lose the dispatch to
# the driver subclass. A clean release delegates with `super` — the same
# `context.release(self)` the base method runs — and a dirty one calls
# `close`, which runs `DB::Connection#do_close` and discards the connection
# from its pool (`context.discard`); the pool opens a fresh one on demand.
module PQ
  class Connection
    # `Sync` (and simple `Query`) messages sent whose `ReadyForQuery` has
    # not been read yet. Zero at release means the wire is idle.
    getter pending_ready : Int32 = 0

    def send_sync_message
      previous_def
      @pending_ready += 1
    end

    def send_query_message(query)
      previous_def
      @pending_ready += 1
    end

    private def read_one_frame(frame_type)
      frame = previous_def
      @pending_ready -= 1 if @established && frame.is_a?(Frame::ReadyForQuery)
      frame
    end
  end
end

module PG
  class Connection
    # True when a response is still queued on the socket: the next borrower
    # would read another request's frames.
    def wire_dirty? : Bool
      wire_pending_ready != 0
    end

    # The number of `Sync` messages sent whose `ReadyForQuery` is not read
    # yet. Diagnostics and specs read it; the guard decides on
    # `wire_dirty?`.
    def wire_pending_ready : Int32
      connection.pending_ready
    end

    # The raw protocol connection. Specs drive it to reproduce a desync;
    # production code goes through `DB::Connection` and `exec_all`.
    def wire_connection : PQ::Connection
      connection
    end

    # Returns a clean connection to the pool and discards a desynced one.
    # Covers both `Facet::Database.with_pinned`'s explicit `release` and
    # crystal-db's own auto-release path. A closed connection is never
    # handed out again, so a `ResultSet` used after release fails loud
    # instead of decoding another request's data.
    def release
      if wire_dirty?
        Facet::Metrics.inc("facet_db_poisoned_discards_total")
        Log.warn do
          "Discarding a desynced PostgreSQL connection " \
          "(pending_ready=#{wire_pending_ready})"
        end
        close
      else
        super
      end
    end
  end
end
