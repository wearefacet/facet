# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"

# Concurrency behaviour of the document update path.
#
# `Document::Update.call` takes the projection row lock (`FOR UPDATE`)
# before it reads the document, inside the transaction it opens (or joins).
# These specs run a competing writer on a second connection to pin the two
# guarantees that buys:
#
# - a competing write that commits while an update waits on the lock is
#   seen by the update — the merged content and the derived columns can
#   never drift;
# - a delete that commits while an update waits answers 404, never an
#   update mutation written onto a tombstone.
#
# Interleaving note: a blocked statement never yields back to the Crystal
# scheduler, so the update under test runs in its own spawned fiber. The
# racer's lock MUST be taken *before* the victim fiber starts: `spawn` only
# enqueues the fiber (it does not yield), and the first statement the victim
# runs is the very `FOR UPDATE` that must block. If the racer takes its lock
# afterwards, the victim wins the race, acquires the lock, and finishes —
# while the racer's own `FOR UPDATE` then blocks forever, hanging the suite.
# Taking the racer's lock first makes the interleave deterministic: the
# victim is guaranteed to wait.
#
# The spawned fiber ships its outcome through the channel — result, service
# error, or the exception itself — and the main fiber waits under a
# `select` timeout. A producer fiber that dies silently fails the example,
# never hangs the suite.
LOCK_DOMAIN = "updatelock"

# The suite's per-statement budget, for restoring a connection whose
# timeout the example lifts.
private def suite_statement_timeout_ms : Int32
  Facet::Database.statement_timeout_ms || 0
end

def register_lock_doctype(db : DB::Connection) : String
  ensure_domain(db, LOCK_DOMAIN)
  doctype = "LockT#{unique_suffix}"
  Facet::Doctype::DefinitionStore.invalidate("#{LOCK_DOMAIN}.#{doctype}")
  create_schema = %({"doctype": "#{doctype}", "domain": "#{LOCK_DOMAIN}", "fields": {
    "title": {"type": "string"},
    "note": {"type": "string"}
  }})
  result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
  raise "lock spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  doctype
end

def lock_create_doc(db : DB::Connection, doctype : String) : String
  res = Facet::Document::Create.call(db, LOCK_DOMAIN, doctype, %({"title": "Original"}), Facet::RBAC::AuthContext.system)
  expect_create_success(res).projection.id
end

# True once some other transaction waits for a transaction-id lock — the
# spawned update fiber has reached the projection row lock. The probe
# counts *ungranted* locks: the racer's own held lock is granted from the
# moment it takes it and must not satisfy the wait.
private def waiting_waiter?(db : DB::Connection) : Bool
  n = db.query_one(
    "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype = 'transactionid'",
    as: Int64
  )
  n > 0
end

# Blocks until the spawned update shows up as an ungranted lock waiter. A
# waiter that never appears fails the example with the given message instead
# of spinning to a silent timeout.
private def await_waiter(db : DB::Connection, context : String) : Nil
  deadline = Time.utc + 10.seconds
  until waiting_waiter?(db)
    if Time.utc >= deadline
      fail "#{context}: the raced update never reached the projection row lock"
    end
    sleep 10.milliseconds
  end
end

# Asserts the spawned update has NOT completed while the racer still holds
# the row lock. `Channel#receive?` suspends until a value arrives or the
# channel closes — it is not a non-blocking peek — so the check runs under a
# short `select` timeout that proves the absence of an outcome.
private def assert_pending(
  done : Channel(Facet::Document::Update::Result | Facet::ServiceError | Exception),
) : Nil
  received = false
  select
  when done.receive
    received = true
  when timeout 200.milliseconds
  end
  received.should be_false
end

# Receives the raced outcome under a bounded wait — a producer fiber that
# never sends fails the example instead of hanging it.
private def receive_outcome(
  done : Channel(Facet::Document::Update::Result | Facet::ServiceError | Exception),
) : Facet::Document::Update::Result | Facet::ServiceError | Exception
  outcome : Facet::Document::Update::Result | Facet::ServiceError | Exception? = nil
  timed_out = false
  select
  when outcome = done.receive
  when timeout 20.seconds
    timed_out = true
  end
  timed_out.should be_false
  outcome.not_nil!
end

# Runs `Document::Update.call` on a pooled connection of the suite
# singleton, in a spawned fiber, and ships the outcome — result, service
# error, or the raised exception — through *done*. The statement timeout is
# lifted for the lock wait and restored before the connection goes back to
# the pool. Called only once the racer holds the row lock, so the first
# statement the fiber runs is guaranteed to block.
private def spawn_raced_update(
  doctype : String,
  doc_id : String,
  done : Channel(Facet::Document::Update::Result | Facet::ServiceError | Exception),
) : Nil
  spawn(name: "raced-update") do
    Facet::Database.with_db do |victim|
      victim.exec("SET statement_timeout = 0")
      begin
        done.send(Facet::Document::Update.call(victim, LOCK_DOMAIN, doctype, doc_id, %({"note": "late"}), Facet::RBAC::AuthContext.system))
      ensure
        victim.exec("SET statement_timeout = #{suite_statement_timeout_ms}")
      end
    end
  rescue ex
    done.send(ex)
  end
end

# Opens the racer's raw connection, takes the projection row lock, yields
# it, then rolls back and releases on exit. The caller runs the block while
# the racer holds the lock — it spawns the victim, waits for the waiter, and
# lands the competing write. `ensure` rolls back, releases the connection,
# and closes the pool either way.
private def with_racer_lock(db : DB::Connection, doctype : String, doc_id : String, & : DB::Connection ->)
  racer_pool = DB.open(ENV.fetch("DATABASE_URL"))
  racer = racer_pool.checkout
  begin
    racer.exec("SET statement_timeout = 0")
    racer.exec("BEGIN")
    racer.query_one(
      "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE",
      LOCK_DOMAIN, doctype, doc_id, as: Int32
    )
    yield racer
  ensure
    # The block may exit with the transaction still open (a failed
    # assertion before the COMMIT). A raw pool knows nothing of this
    # suite's transaction bookkeeping — roll back here so the connection
    # never re-enters a pool holding the row lock. The rollback of an
    # already-closed connection raises; the release below is what matters
    # on that path.
    begin
      racer.exec("ROLLBACK")
    rescue
      nil
    end
    racer.release
    racer_pool.close
  end
end

describe "Document::Update concurrency" do
  it "sees a competing write that commits while the update waits on the row lock" do
    with_db do |db|
      doctype = register_lock_doctype(db)
      doc_id = lock_create_doc(db, doctype)

      done = Channel(Facet::Document::Update::Result | Facet::ServiceError | Exception).new

      # The racer takes the row lock BEFORE the victim starts: the victim's
      # first statement is the `FOR UPDATE` that must block.
      with_racer_lock(db, doctype, doc_id) do |racer|
        spawn_raced_update(doctype, doc_id, done)

        await_waiter(racer, "update")
        assert_pending(done)

        # Land the competing write and commit, then collect the raced
        # outcome under a bounded wait.
        racer.query_one(
          "INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace) VALUES ($1, $2, $3, $4, 'update', 'system:racer', $5::jsonb, 'internal', 'request', $3) RETURNING id",
          LOCK_DOMAIN, doctype, Facet::Util::ScriptHelpers.ulid, doc_id,
          %({"diff": {"set": [{"path": ["title"], "value": "Raced"}], "unset": []}}),
          as: String
        )
        racer.exec("COMMIT")

        result = receive_outcome(done)
        result.should be_a(Facet::Document::Update::Result)
        proj = result.as(Facet::Document::Update::Result).projection

        # The update merged onto the post-race content: both writes landed,
        # and the staged state matches the landed content.
        proj.content["title"].as_s.should eq("Raced")
        proj.content["note"].as_s.should eq("late")
        proj.state.should eq(result.as(Facet::Document::Update::Result).mutation_id)
      end
    end
  end

  it "answers 404 when the document is deleted while the update waits on the row lock" do
    with_db do |db|
      doctype = register_lock_doctype(db)
      doc_id = lock_create_doc(db, doctype)

      done = Channel(Facet::Document::Update::Result | Facet::ServiceError | Exception).new

      with_racer_lock(db, doctype, doc_id) do |racer|
        spawn_raced_update(doctype, doc_id, done)

        await_waiter(racer, "delete")
        assert_pending(done)

        # Tombstone the document under the lock: a raw delete mutation,
        # the trigger tombstones the projection row.
        racer.query_one(
          "INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace) VALUES ($1, $2, $3, $4, 'delete', 'system:racer', '{}'::jsonb, 'internal', 'request', $3) RETURNING id",
          LOCK_DOMAIN, doctype, Facet::Util::ScriptHelpers.ulid, doc_id,
          as: String
        )
        racer.exec("COMMIT")

        result = receive_outcome(done)
        result.should be_a(Facet::ServiceError)
        (result.as(Facet::ServiceError).status == 404 || result.as(Facet::ServiceError).status == 410).should be_true
      end
    end
  end
end
