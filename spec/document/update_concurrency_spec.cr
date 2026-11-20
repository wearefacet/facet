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
# scheduler, so the update under test runs in its own spawned fiber on its
# own raw connection, and the main fiber commits the racer's transaction
# once the update shows up as a lock waiter in `pg_locks`. Both extra
# connections raise the suite's 5 s statement budget for themselves — the
# lock wait is longer by design.
LOCK_DOMAIN = "updatelock"

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
# spawned update fiber has reached the projection row lock.
private def waiting_waiter?(db : DB::Connection) : Bool
  n = db.query_one(
    "SELECT count(*) FROM pg_locks WHERE granted AND locktype = 'transactionid'",
    as: Int64
  )
  n > 0
end

describe "Document::Update concurrency" do
  it "sees a competing write that commits while the update waits on the row lock" do
    with_db do |db|
      doctype = register_lock_doctype(db)
      doc_id = lock_create_doc(db, doctype)

      racer_pool = DB.open(ENV.fetch("DATABASE_URL"))
      racer = racer_pool.checkout
      victim_pool = DB.open(ENV.fetch("DATABASE_URL"))
      victim = victim_pool.checkout
      begin
        racer.exec("SET statement_timeout = 0")
        victim.exec("SET statement_timeout = 0")

        # The racer opens a transaction, takes the row lock, and waits.
        racer.exec("BEGIN")
        racer.query_one(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE",
          LOCK_DOMAIN, doctype, doc_id, as: Int32
        )

        done = Channel(Facet::Document::Update::Result | Facet::ServiceError).new
        spawn(name: "raced-update") do
          done.send(Facet::Document::Update.call(victim, LOCK_DOMAIN, doctype, doc_id, %({"note": "late"}), Facet::RBAC::AuthContext.system))
        end

        # Wait until the update fiber shows up as a lock waiter, then land
        # the competing write and commit. While the lock is held the
        # update must not complete.
        deadline = Time.utc + 10.seconds
        until waiting_waiter?(racer) || Time.utc >= deadline
          sleep 10.milliseconds
        end
        waiting_waiter?(racer).should be_true
        done.receive?.should be_nil

        racer.query_one(
          "INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace) VALUES ($1, $2, $3, $4, 'update', 'system:racer', $5::jsonb, 'internal', 'request', $3) RETURNING id",
          LOCK_DOMAIN, doctype, Facet::Util::ScriptHelpers.ulid, doc_id,
          %({"diff": {"set": [{"path": ["title"], "value": "Raced"}], "unset": []}}),
          as: String
        )
        racer.exec("COMMIT")

        result = done.receive
        result.should be_a(Facet::Document::Update::Result)
        proj = result.as(Facet::Document::Update::Result).projection

        # The update merged onto the post-race content: both writes landed,
        # and the staged state matches the landed content.
        proj.content["title"].as_s.should eq("Raced")
        proj.content["note"].as_s.should eq("late")
        proj.state.should eq(result.as(Facet::Document::Update::Result).mutation_id)
      ensure
        racer.release
        racer_pool.close
        victim.release
        victim_pool.close
      end
    end
  end

  it "answers 404 when the document is deleted while the update waits on the row lock" do
    with_db do |db|
      doctype = register_lock_doctype(db)
      doc_id = lock_create_doc(db, doctype)

      racer_pool = DB.open(ENV.fetch("DATABASE_URL"))
      racer = racer_pool.checkout
      victim_pool = DB.open(ENV.fetch("DATABASE_URL"))
      victim = victim_pool.checkout
      begin
        racer.exec("SET statement_timeout = 0")
        victim.exec("SET statement_timeout = 0")

        racer.exec("BEGIN")
        racer.query_one(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE",
          LOCK_DOMAIN, doctype, doc_id, as: Int32
        )

        done = Channel(Facet::Document::Update::Result | Facet::ServiceError).new
        spawn(name: "raced-update-delete") do
          done.send(Facet::Document::Update.call(victim, LOCK_DOMAIN, doctype, doc_id, %({"note": "late"}), Facet::RBAC::AuthContext.system))
        end

        deadline = Time.utc + 10.seconds
        until waiting_waiter?(racer) || Time.utc >= deadline
          sleep 10.milliseconds
        end
        waiting_waiter?(racer).should be_true
        done.receive?.should be_nil

        # Tombstone the document under the lock: a raw delete mutation,
        # the trigger tombstones the projection row.
        racer.query_one(
          "INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace) VALUES ($1, $2, $3, $4, 'delete', 'system:racer', '{}'::jsonb, 'internal', 'request', $3) RETURNING id",
          LOCK_DOMAIN, doctype, Facet::Util::ScriptHelpers.ulid, doc_id,
          as: String
        )
        racer.exec("COMMIT")

        result = done.receive
        result.should be_a(Facet::ServiceError)
        (result.as(Facet::ServiceError).status == 404 || result.as(Facet::ServiceError).status == 410).should be_true
      ensure
        racer.release
        racer_pool.close
        victim.release
        victim_pool.close
      end
    end
  end
end
