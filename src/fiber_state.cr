# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Fiber-local state for request-scoped data.
#
# Uses `Fiber` properties instead of `Thread` properties so that concurrent
# fibers within the same thread do not interfere. When spawning a new fiber
# with `spawn`, values from the parent fiber are NOT copied — each fiber
# starts fresh with default values.

module Facet
  module Database
    # A pinned pooled connection plus the route (database entry + pool role)
    # that produced it. Carried on the fiber pin slots so a reused pin still
    # reports the pool it came from — the `db.transaction` span attribute and
    # the checkout counters label by database and role.
    record Pin, connection : DB::Connection, database : String, role : String
  end
end

class Fiber
  # Per-connection transaction nesting depth for `Database.with_transaction`
  # (0 = no active transaction on that connection). Two pin slots can hold
  # two connections on one fiber, and the explicit `with_transaction(db)`
  # form can receive a raw, unpinned connection (the seeds do), so the depth
  # lives in a map keyed by connection instead of a single integer.
  # Lazily allocated — most fibers never enter a transaction.
  property txn_depths : Hash(DB::Connection, Int32)?

  # Pinned DB connections for the current fiber, one slot per mode.
  #
  # Set by `Database.with_connection` so that every statement executed within
  # a request (or any nested call) lands on the same backend connection. An
  # `rw` request reuses the `db_rw` pin; a `ro` request reuses the `db_rw`
  # pin when present (a read on the write connection sees the outer scope's
  # uncommitted writes), else the `db_ro` pin. On block exit a frame releases
  # only a pin it checked out itself — the other slot stays pinned for the
  # outer frame.
  #
  # This is what makes `BEGIN` / `INSERT` / `SELECT` see each other inside a
  # transaction — without pinning, crystal-db's pool may hand out a different
  # connection for each `db.exec` call, and uncommitted writes become
  # invisible to subsequent reads on a different connection.
  #
  # Background fibers (e.g. the async `Index::Manager.run_batch` batches)
  # start with empty slots and check out their own connections, so they never
  # interfere with the request fiber's pins.
  property db_ro : Facet::Database::Pin?
  property db_rw : Facet::Database::Pin?

  # Request cache for doctype definitions (raw JSON, avoids
  # requiring Doctype::DoctypeDefinition at load time).
  property definition_cache : Hash(String, JSON::Any)?

  # Auth context for the current request.
  property auth_context : Facet::RBAC::AuthContext?

  # Event publish queue (set by Event::Publisher).
  property event_publish_queue : Array(Facet::Event::Publisher::PendingEvent)?
end
