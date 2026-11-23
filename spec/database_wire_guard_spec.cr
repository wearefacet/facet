# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "../src/database/wire_guard"

# Wire-state guard (`Facet::Database` → `src/database/wire_guard.cr`).
#
# A pooled connection is reusable only while every `Sync` it sent has been
# matched by one `ReadyForQuery` read. These specs reproduce the two shapes
# of the 2026-11-23 desync — an abandoned `ResultSet` (frames left in the
# socket) and an already-lagged connection — and pin the guard's response:
# the release discards the connection instead of pooling it, the counter
# reports it, and the next checkout decodes its own response.
#
# The discarded-connection counter is process-wide, so every example reads it
# as a delta around its own work.

private def wg_pending_ready(conn : DB::Connection) : Int32
  conn.as(PG::Connection).wire_pending_ready
end

# The raw protocol connection behind a pooled one — the specs drive it
# directly to leave a response unread.
private def wg_raw(conn : DB::Connection) : PQ::Connection
  conn.as(PG::Connection).wire_connection
end

private def wg_discards : Float64
  Facet::Metrics.value("facet_db_poisoned_discards_total")
end

describe "PG wire-state guard" do
  it "leaves a clean connection idle: one query, one ReadyForQuery" do
    Facet::Database.with_db do |db|
      db.query_all("SELECT g FROM generate_series(1, 3) AS g", as: Int32).should eq [1, 2, 3]
      wg_pending_ready(db).should eq 0
    end
  end

  it "discards a connection whose ResultSet was abandoned" do
    before = wg_discards

    Facet::Database.with_db do |db|
      rs = db.query("SELECT g FROM generate_series(1, 2) AS g")
      rs.move_next.should be_true
      rs.read(Int32).should eq 1
      # Abandoned on purpose: no `rs.close`. Two frames remain queued
      # (the second DataRow, CommandComplete, ReadyForQuery).
      wg_pending_ready(db).should eq 1
    end

    (wg_discards - before).should eq 1

    # The next checkout decodes its own response, not the leftover frames.
    Facet::Database.with_db do |db|
      db.query_all("SELECT g FROM generate_series(1, 3) AS g", as: Int32).should eq [1, 2, 3]
      db.scalar("SELECT 'clean'").should eq "clean"
    end
  end

  it "discards a connection lagged by one whole unread response" do
    before = wg_discards
    facet_db = nil
    pq = nil

    Facet::Database.with_db do |db|
      facet_db = db
      pq = wg_raw(db)
      # Send a full extended-query response and read none of it: the wire
      # is now one whole response ahead — the incident shape.
      pq.send_parse_message("SELECT 'leak'")
      pq.send_bind_message([] of PQ::Param)
      pq.send_describe_portal_message
      pq.send_execute_message
      pq.send_sync_message
      wg_pending_ready(db).should eq 1
    end

    (wg_discards - before).should eq 1
    facet_db.not_nil!.closed?.should be_true
    pq.not_nil!.soc.closed?.should be_true

    Facet::Database.with_db do |db|
      db.scalar("SELECT 'after'").should eq "after"
    end
  end

  it "keeps the connection clean when the block raises after a closed query" do
    before = wg_discards

    begin
      Facet::Database.with_db do |db|
        db.query_all("SELECT g FROM generate_series(1, 2) AS g", as: Int32).should eq [1, 2]
        raise "boom"
      end
    rescue ex : Exception
      ex.message.should eq "boom"
    end

    (wg_discards - before).should eq 0

    Facet::Database.with_db do |db|
      db.scalar("SELECT 'still clean'").should eq "still clean"
    end
  end

  it "keeps the connection clean when a server-side error rolls back a transaction" do
    before = wg_discards

    expect_raises(PQ::PQError, "no_such_table") do
      Facet::Database.with_transaction do |db|
        db.exec("SELECT no_such_column FROM no_such_table")
      end
    end

    (wg_discards - before).should eq 0

    Facet::Database.with_db do |db|
      db.scalar("SELECT 'recovered'").should eq "recovered"
    end
  end

  it "keeps the connection clean after a clean exec_all" do
    before = wg_discards

    Facet::Database.with_db do |db|
      db.as(PG::Connection).exec_all("SELECT 1; SELECT 2;")
      wg_pending_ready(db).should eq 0
    end

    (wg_discards - before).should eq 0
  end

  it "discards a connection whose COPY output was abandoned" do
    before = wg_discards

    Facet::Database.with_db do |db|
      io = db.as(PG::Connection).exec_copy("COPY (VALUES (1), (2)) TO STDOUT")
      io.read_char.should eq '1'
      wg_pending_ready(db).should eq 1
    end

    (wg_discards - before).should eq 1

    Facet::Database.with_db do |db|
      db.scalar("SELECT 'after copy'").should eq "after copy"
    end
  end
end
