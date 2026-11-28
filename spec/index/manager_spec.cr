# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/index"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"

# Helper: creates a simple field definition for testing. The `operators`
# argument is the *legacy* operator-string list (e.g. `["eq", "gte"]`);
# it is translated to `FilterCapability` values via `caps_for` so existing
# call sites stay readable.
private def make_field(type_name : String, operators : Array(String)? = nil, unique : Bool = false, write_only : Bool = false, read_only : Bool = false)
  type = Facet::Doctype::FieldType.parse(type_name)
  caps = operators.try { |arr| caps_for(type.type_name, arr) }
  Facet::Doctype::FieldDefinition.new(
    type: type,
    filters: caps,
    unique: unique,
    write_only: write_only,
    read_only: read_only,
  )
end

# Translates a legacy operator-string list into `FilterCapability` values
# for the given field type. Mirrors the rules in
# `tmp/migrate_operators_to_filters.rb` (kept here so spec fixtures can
# stay written in the concise operator form).
private def caps_for(type_name : String, ops : Array(String)) : Array(Facet::Doctype::FilterCapability)?
  range_ops = !(ops & ["gt", "gte", "lt", "lte", "between"]).empty?
  has = ->(op : String) { ops.includes?(op) }
  any_of = ->(list : Array(String)) { !(ops & list).empty? }
  chars = [] of Facet::Doctype::FilterCapability
  if type_name == "period" || type_name == "dateperiod"
    chars << Facet::Doctype::FilterCapability::Equality if has.call("eq")
    chars << Facet::Doctype::FilterCapability::Interval if any_of.call(["contains", "overlaps", "within"])
  elsif type_name == "money"
    caps_for_money(chars, range_ops, has)
  elsif type_name == "array"
    chars << Facet::Doctype::FilterCapability::Membership if any_of.call(["eq", "contains", "overlaps"])
  else
    caps_for_scalar(chars, range_ops, has)
  end
  chars.empty? ? nil : chars
end

# Value part of the `money` branch of `caps_for`, split out to keep the
# cyclomatic complexity of both methods low.
private def caps_for_money(chars : Array(Facet::Doctype::FilterCapability), range_ops : Bool, has : (String -> Bool)) : Nil
  if has.call("eq") || range_ops
    chars << (range_ops ? Facet::Doctype::FilterCapability::Comparison : Facet::Doctype::FilterCapability::Equality)
  end
  chars << Facet::Doctype::FilterCapability::Currency if has.call("currency")
end

# Value part of the default branch of `caps_for`, split out to keep the
# cyclomatic complexity of both methods low.
private def caps_for_scalar(chars : Array(Facet::Doctype::FilterCapability), range_ops : Bool, has : (String -> Bool)) : Nil
  chars << Facet::Doctype::FilterCapability::Comparison if range_ops
  chars << Facet::Doctype::FilterCapability::Equality if !range_ops && has.call("eq")
  chars << Facet::Doctype::FilterCapability::TextSearch if has.call("match")
end

describe Facet::Index::Manager do
  describe ".sync" do
    it "inserts rows into doctype_indexes and synchronously builds the index" do
      with_db do |db|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "SyncDoc", domain: "test",
          fields: {"email" => make_field("string", ["eq"])}
        )

        # spec_helper sets `Index::Manager.synchronous = true` before the
        # suite starts, so this `sync` call runs `CREATE INDEX` inline
        # (no `CONCURRENTLY`, no background fiber). The row lands in `active`
        # status by the time `sync` returns; the actual PG index exists on
        # `projections` and can be looked up in `pg_indexes`.
        Facet::Index::Manager.sync(db, defn)

        rows = db.query_all(
          "SELECT field_name, index_type, status FROM doctype_indexes WHERE domain = 'test' AND doc_type = 'SyncDoc'",
          as: {String, String, String}
        )
        rows.size.should eq(1)
        row = rows.first
        row[0].should eq("email")
        row[1].should eq("btree")
        row[2].should eq("active")

        # The actual PG index exists.
        index_name = Facet::Index::Naming.index_name("test", "SyncDoc", "email", "btree")
        pg_index = db.query_one?(
          "SELECT 1 FROM pg_indexes WHERE tablename = 'projections' AND indexname = $1",
          index_name,
          as: Int32
        )
        pg_index.should_not be_nil
      end
    end

    it "creates the field's extended statistics object with the btree index" do
      with_db do |db|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "StatsDoc", domain: "test",
          fields: {"number" => make_field("string", ["eq"])}
        )

        Facet::Index::Manager.sync(db, defn)

        stats_name = Facet::Index::Naming.statistics_name("test", "StatsDoc", "number")
        exists = db.query_one?(
          "SELECT 1 FROM pg_statistic_ext WHERE stxname = $1",
          stats_name,
          as: Int32
        )
        exists.should_not be_nil
      end
    end

    it "drops the statistics object with the last btree variant of a field" do
      with_db do |db|
        full = Facet::Doctype::DoctypeDefinition.new(
          doctype: "StatsDropDoc", domain: "test",
          fields: {"number" => make_field("string", ["eq"])}
        )
        Facet::Index::Manager.sync(db, full)

        stats_name = Facet::Index::Naming.statistics_name("test", "StatsDropDoc", "number")
        db.query_one?("SELECT 1 FROM pg_statistic_ext WHERE stxname = $1", stats_name, as: Int32).should_not be_nil

        # Removing the field from the definition drops its btree index and
        # with it the statistics object.
        empty = Facet::Doctype::DoctypeDefinition.new(
          doctype: "StatsDropDoc", domain: "test",
          fields: {} of String => Facet::Doctype::FieldDefinition,
        )
        Facet::Index::Manager.sync(db, empty)

        db.query_one?("SELECT 1 FROM pg_statistic_ext WHERE stxname = $1", stats_name, as: Int32).should be_nil
      end
    end

    it "is idempotent — calling sync twice does not create duplicate rows" do
      with_db do |db|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "IdempotentDoc", domain: "test",
          fields: {"email" => make_field("string", ["eq"])}
        )

        Facet::Index::Manager.sync(db, defn)
        Facet::Index::Manager.sync(db, defn)

        rows = db.query_all(
          "SELECT field_name, index_type FROM doctype_indexes WHERE domain = 'test' AND doc_type = 'IdempotentDoc'",
          as: {String, String}
        )
        rows.size.should eq(1)
      end
    end

    it "handles multiple fields with mixed operators" do
      with_db do |db|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "MixedDoc", domain: "test",
          fields: {
            "email" => make_field("string", ["eq"]),
            "name"  => make_field("string", ["eq", "match"]),
            "tags"  => make_field("array", ["eq"]),
          }
        )

        Facet::Index::Manager.sync(db, defn)

        rows = db.query_all(
          "SELECT field_name, index_type FROM doctype_indexes WHERE domain = 'test' AND doc_type = 'MixedDoc' ORDER BY field_name, index_type",
          as: {String, String}
        )
        rows.size.should eq(4) # email btree, name btree, name gin_trgm, tags gin_jsonb
      end
    end

    # Domains containing characters that are not valid in a PostgreSQL
    # unquoted identifier (e.g. `new-crm`) must be sanitised — the emitted
    # `CREATE INDEX` / `DROP INDEX` SQL embeds the identifier unquoted.
    # This test exercises the full sync (CREATE INDEX) and
    # `drop_one_index` (DROP INDEX) paths to guard the end-to-end DDL.
    it "succeeds for a hyphenated domain name (regression for new-crm)" do
      with_db do |db|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "Deal", domain: "new-crm",
          fields: {"expected_close_date" => make_field("datetime", ["eq", "gte", "lte"])}
        )

        # No exception should escape `sync`.
        Facet::Index::Manager.sync(db, defn)

        rows = db.query_all(
          "SELECT field_name, index_type, status FROM doctype_indexes WHERE domain = 'new-crm' AND doc_type = 'Deal'",
          as: {String, String, String}
        )
        rows.size.should eq(1)
        row = rows.first
        row[0].should eq("expected_close_date")
        row[1].should eq("btree")
        row[2].should eq("active")

        index_name = Facet::Index::Naming.index_name("new-crm", "Deal", "expected_close_date", "btree")
        index_name.should_not match(/-/)
        pg_index = db.query_one?(
          "SELECT 1 FROM pg_indexes WHERE tablename = 'projections' AND indexname = $1",
          index_name,
          as: Int32
        )
        pg_index.should_not be_nil

        # DROP INDEX must also succeed without choking on a `-`. Schedule a
        # drop by syncing an empty field set; `drop_one_index` runs the
        # configured (synchronous) DROP path.
        empty_defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "Deal", domain: "new-crm",
          fields: {} of String => Facet::Doctype::FieldDefinition
        )
        Facet::Index::Manager.sync(db, empty_defn)

        dropped = db.query_one?(
          "SELECT status FROM doctype_indexes WHERE index_name = $1",
          index_name,
          as: String
        )
        dropped.should eq("dropped")
        pg_index_after = db.query_one?(
          "SELECT 1 FROM pg_indexes WHERE tablename = 'projections' AND indexname = $1",
          index_name,
          as: Int32
        )
        pg_index_after.should be_nil
      end
    end

    # A money field carrying a stale `btree_numeric` row must drop that row
    # when `sync` recomputes the desired set to `btree_money` /
    # `btree_money_currency`. The manager's diff logic (`compute_desired`
    # vs `fetch_current`) emits a DROP for the removed index_type
    # (`doc/backend/index-management.md`).
    it "drops a stale btree_numeric row when a money field now wants btree_money" do
      with_db do |db|
        # Seed a money-typed doctype; sync creates the btree_money pair.
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "RevampDoc", domain: "test",
          fields: {"price" => make_field("money", ["gte"])}
        )
        Facet::Index::Manager.sync(db, defn)

        # Inject a stale `btree_numeric` row directly — an index_type the
        # desired set no longer includes.
        stale_name = Facet::Index::Naming.index_name("test", "RevampDoc", "price", "btree_numeric")
        db.exec(
          "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
          "VALUES ($1, $2, $3, $4, $5, 'active') " \
          "ON CONFLICT (domain, doc_type, field_name, index_type) DO NOTHING",
          "test", "RevampDoc", "price", "btree_numeric", stale_name
        )

        # Re-sync: the desired set no longer includes `btree_numeric`; the
        # manager must DROP the stale row.
        Facet::Index::Manager.sync(db, defn)

        stale_status = db.query_one?(
          "SELECT status FROM doctype_indexes " \
          "WHERE domain = $1 AND doc_type = $2 AND field_name = $3 AND index_type = $4",
          "test", "RevampDoc", "price", "btree_numeric",
          as: String
        )
        stale_status.should eq("dropped")

        # The new money indexes are active.
        active = db.query_all(
          "SELECT index_type FROM doctype_indexes " \
          "WHERE domain = $1 AND doc_type = $2 AND field_name = $3 AND status = 'active'",
          "test", "RevampDoc", "price",
          as: String
        ).to_set
        active.should contain("btree_money")
        active.should contain("btree_money_currency")
      end
    end
  end

  # Exercises the production concurrent path (`synchronous? = false` →
  # `run_batch` with `async: true` in a background fiber with `CREATE INDEX
  # CONCURRENTLY`). The spec suite sets `synchronous = true` in
  # `spec_helper.cr`'s `before_suite`, so this block explicitly opts back
  # into the production path for the duration of each example and restores
  # the test default in `ensure`. Run in isolation, these tests pay the
  # `CREATE INDEX CONCURRENTLY` cost the rest of the suite is bypassing.
  describe "concurrent mode" do
    it "spawns a background fiber and marks rows active after the fiber drains" do
      previous = Facet::Index::Manager.synchronous?
      Facet::Index::Manager.synchronous = false
      begin
        with_db do |db|
          defn = Facet::Doctype::DoctypeDefinition.new(
            doctype: "ConcurrentDoc", domain: "test",
            fields: {"email" => make_field("string", ["eq"])}
          )

          # Spawning increments the pending-fiber counter before the fiber
          # actually runs, so the counter is non-zero immediately after
          # `sync` returns even though the DDL has not necessarily finished.
          Facet::Index::Manager.pending_fibers.should eq(0)
          Facet::Index::Manager.sync(db, defn)
          Facet::Index::Manager.pending_fibers.should be > 0

          # Drain the fiber. On success the row reaches `active` and the
          # actual PG index exists on `projections`.
          drained = Facet::Index::Manager.wait_for_pending_fibers(timeout: 30.seconds)
          drained.should be_true
          Facet::Index::Manager.pending_fibers.should eq(0)

          rows = db.query_all(
            "SELECT field_name, index_type, status FROM doctype_indexes WHERE domain = 'test' AND doc_type = 'ConcurrentDoc'",
            as: {String, String, String}
          )
          rows.size.should eq(1)
          rows.first[2].should eq("active")

          index_name = Facet::Index::Naming.index_name("test", "ConcurrentDoc", "email", "btree")
          pg_index = db.query_one?("SELECT 1 FROM pg_indexes WHERE tablename = 'projections' AND indexname = $1",
            index_name,
            as: Int32
          )
          pg_index.should_not be_nil
        end
      ensure
        Facet::Index::Manager.synchronous = previous
      end
    end
  end

  # The DDL gate serialises every managed-index DDL unit across fibers and
  # processes (session-level advisory lock taken by `pg_try_advisory_lock`
  # polling, see `with_ddl_gate`). Two concurrent `CREATE`/`DROP INDEX
  # CONCURRENTLY` statements on `projections` deadlock against each other —
  # PG aborts one with 40P01 — which is what the gate prevents.
  describe "DDL gate" do
    # B-46 regression: a session blocked on `pg_advisory_lock` holds an
    # open (implicit) transaction, and the gate-holder's `CREATE INDEX
    # CONCURRENTLY` snapshot-wait collects concurrent transactions —
    # including that waiter's — and waits for its virtual xid while the
    # waiter waits for the gate. PG kills the queued fiber and its
    # tracking row stayed `pending` forever behind a successful publish.
    # The try-lock poll never blocks in the database, so no ungranted
    # advisory lock may ever exist while a waiter is polling.
    it "polls without ever leaving a blocked advisory waiter" do
      holder_ready = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      holder_done = Channel(Nil).new(1)

      spawn do
        Facet::Database.with_db do |db|
          Facet::Index::Manager.with_ddl_gate(db) do
            holder_ready.send(nil)
            release.receive
          end
        end
        holder_done.send(nil)
      end

      holder_ready.receive

      entered = Channel(Nil).new(1)
      spawn do
        Facet::Database.with_db do |db|
          Facet::Index::Manager.with_ddl_gate(db) do
            entered.send(nil)
          end
        end
      end

      # Wait for proof the waiter polled and was refused while the holder
      # kept the gate: the refusal counter moves only on a failed
      # `pg_try_advisory_lock`. A blocking acquire (the B-46 regression)
      # would never be refused — it would park inside `pg_advisory_lock`,
      # the counter would stay flat, and this wait would time out.
      baseline = Facet::Index::Manager.gate_refusals
      assert_eventually { Facet::Index::Manager.gate_refusals > baseline }

      # With the try-lock poll the waiter never holds a waiting transaction:
      # no ungranted advisory lock may exist. One deterministic sample at a
      # proven-refused instant replaces the old sampled window.
      with_db do |db|
        blocked = db.query_one(
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted " \
          "AND database = (SELECT oid FROM pg_database WHERE datname = current_database())",
          as: Int64
        )
        blocked.should eq(0)
      end

      # The waiter still converges into the gate once the holder leaves.
      release.send(nil)
      entered.receive
      holder_done.receive
    end

    it "admits one DDL holder at a time across fibers" do
      in_flight = Atomic.new(0)
      max_seen = Atomic.new(0)
      done = Channel(Nil).new(2)

      2.times do
        spawn do
          begin
            Facet::Database.with_db do |db|
              20.times do
                Facet::Index::Manager.with_ddl_gate(db) do
                  current = in_flight.add(1) + 1
                  max_seen.max(current)
                  # Yield while holding the gate — a broken gate would let
                  # the other fiber enter and push `max_seen` above 1.
                  Fiber.yield
                  in_flight.add(-1)
                end
              end
            end
          ensure
            done.send(nil)
          end
        end
      end

      2.times { done.receive }
      max_seen.get.should eq(1)
    end

    it "re-raises non-deadlock PG errors without retrying" do
      with_db do |db|
        expect_raises(PQ::PQError) do
          # Syntax error on an unknown index type — SQLSTATE 42603/42703
          # family, not 40P01, so the helper must surface it immediately.
          Facet::Index::Manager.exec_ddl_with_deadlock_retry(
            db,
            "CREATE INDEX idx_env_spec_gate_probe ON projections USING btree ((no_such_column))",
          )
        end
      end
    end
  end
end
