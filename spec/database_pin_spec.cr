# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"

# Pin-model semantics of `Facet::Database` (the segregation design, §4.3).
#
# Every reuse row of the contract is asserted with `pg_backend_pid` — the
# only observable that proves two Crystal objects are the same backend
# connection. The suite runs on the back-compat single pool, so both modes
# resolve to the same pool here; the *slot* rules are what these specs pin
# down. Route/pool separation is covered in `database_cluster_spec.cr`.
private def current_pid(db : DB::Connection) : Int32
  db.query_one("SELECT pg_backend_pid()", as: Int32)
end

describe "Facet::Database pin model" do
  it "checks out separate connections for ro and rw on one fiber" do
    ro_pid = nil
    rw_pid = nil
    Facet::Database.with_db(:read_only) do |ro_db|
      ro_pid = current_pid(ro_db)
      Facet::Database.with_db(:read_write) do |rw_db|
        rw_pid = current_pid(rw_db)
      end
    end
    ro_pid.should_not eq(rw_pid)
  end

  it "reuses the ro pin for a nested ro request" do
    outer_pid = nil
    inner_pid = nil
    Facet::Database.with_db(:read_only) do |outer_db|
      outer_pid = current_pid(outer_db)
      Facet::Database.with_db(:read_only) do |inner_db|
        inner_pid = current_pid(inner_db)
      end
    end
    outer_pid.should eq(inner_pid)
  end

  it "reuses the rw pin for a nested rw request" do
    outer_pid = nil
    inner_pid = nil
    Facet::Database.with_db do |outer_db|
      outer_pid = current_pid(outer_db)
      Facet::Database.with_db do |inner_db|
        inner_pid = current_pid(inner_db)
      end
    end
    outer_pid.should eq(inner_pid)
  end

  it "reuses the rw pin for a nested ro request (read-your-writes)" do
    rw_pid = nil
    inner_pid = nil
    Facet::Database.with_db do |rw_db|
      rw_pid = current_pid(rw_db)
      Facet::Database.with_db(:read_only) do |inner_db|
        inner_pid = current_pid(inner_db)
      end
    end
    rw_pid.should eq(inner_pid)
  end

  it "keeps the outer ro pin alive across a nested rw block" do
    ro_pid = nil
    after_rw_pid = nil
    Facet::Database.with_db(:read_only) do |ro_db|
      ro_pid = current_pid(ro_db)
      Facet::Database.with_db do |rw_db|
        # Two distinct backends inside the escalation scope.
        current_pid(rw_db).should_not eq(ro_pid)
      end
      # The ro pin survived — the outer frame still holds its connection.
      after_rw_pid = current_pid(ro_db)
    end
    ro_pid.should eq(after_rw_pid)
  end

  it "releases nothing from an inner frame that reused a pin" do
    outer_pid = nil
    inner_pid = nil
    after_inner_pid = nil
    Facet::Database.with_db do |outer_db|
      outer_pid = current_pid(outer_db)
      Facet::Database.with_db(:read_only) do |inner_db|
        inner_pid = current_pid(inner_db)
      end
      # The inner frame released nothing: the rw pin still holds.
      after_inner_pid = current_pid(outer_db)
    end
    outer_pid.should eq(inner_pid)
    outer_pid.should eq(after_inner_pid)
  end

  it "releases each pin at its own frame boundary" do
    # The ro role label depends on the shape: a separate ro pool (cluster
    # mode) labels its own checkout; the back-compat single pool serves ro
    # requests from the primary pool. Detect which shape is live.
    has_ro_pool = false
    Facet::Database.each_pool do |_, role, _pool|
      has_ro_pool = true if role == "ro"
    end
    ro_role = has_ro_pool ? "ro" : "rw"

    rw_key = {"database" => "main", "role" => "rw"}
    ro_key = {"database" => "main", "role" => ro_role}
    rw_base = Facet::Metrics.value("facet_db_checkout_total", rw_key)
    ro_base = Facet::Metrics.value("facet_db_checkout_total", ro_key)

    Facet::Database.with_db(:read_only) do |ro_db|
      current_pid(ro_db)
      Facet::Database.with_db do |rw_db|
        current_pid(rw_db)
      end
      # The rw frame released its pin: the next rw request inside the ro
      # scope checks out again (the ro pin is not reusable for rw).
      Facet::Database.with_db do |_fresh_rw|
      end
    end

    # One ro checkout (the outer frame) and two rw checkouts (the nested
    # frame and the post-release frame). A pin leak would show as one rw
    # checkout only. In back-compat mode the ro checkout labels the primary
    # pool, so all three land on the rw series.
    if has_ro_pool
      Facet::Metrics.value("facet_db_checkout_total", rw_key).should eq(rw_base + 2)
      Facet::Metrics.value("facet_db_checkout_total", ro_key).should eq(ro_base + 1)
    else
      Facet::Metrics.value("facet_db_checkout_total", rw_key).should eq(rw_base + 3)
    end
  end

  it "keeps separate savepoint depths for two connections on one fiber" do
    Facet::Database.with_db(:read_only) do |ro_db|
      Facet::Database.with_db do |rw_db|
        # Interleaved transactions on two connections of one fiber: the
        # depth map must track them independently.
        Facet::Database.with_transaction(ro_db) do
          Facet::Database.with_transaction(rw_db) do
            # Both open — a failure on the inner must not abort the outer.
          end
          # rw committed; ro still open. A savepoint on the ro connection
          # now sits at depth 1, not 2.
          Facet::Database.with_transaction(ro_db) do
            ro_db.query_one("SELECT 1", as: Int32).should eq(1)
          end
        end
      end
    end
  end

  it "rolls back an inner savepoint without aborting the outer transaction" do
    Facet::Database.with_db do |db|
      Facet::Database.with_transaction(db) do
        db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                 VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "pin-outer")
        expect_raises(Exception, "boom") do
          Facet::Database.with_transaction(db) do
            db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                     VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "pin-inner")
            raise "boom"
          end
        end
      end
      count = db.query_one("SELECT COUNT(*) FROM mutations WHERE doc_id LIKE 'pin-%'", as: Int64)
      count.should eq(1)
    end
  end

  it "indexes savepoint depth by connection, not by fiber" do
    # A raw, unpinned connection (the seeds' pattern) shares the fiber with
    # pinned connections; each connection's depth is its own.
    DB.open(ENV.fetch("DATABASE_URL")) do |raw_db|
      raw_conn = raw_db.checkout
      begin
        Facet::Database.with_db do |pinned|
          Facet::Database.with_transaction(raw_conn) do
            # Depth on the raw connection is 1; the pinned connection is
            # untouched at 0 — a nested savepoint form would target the
            # wrong backend if the map were fiber-global.
            Facet::Database.with_transaction(pinned) do
              pinned.query_one("SELECT 1", as: Int32).should eq(1)
            end
          end
        end
      ensure
        raw_conn.release
      end
    end
  end
end
