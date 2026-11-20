# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"

private def current_pid(db : DB::Connection) : Int32
  db.query_one("SELECT pg_backend_pid()", as: Int32)
end

# The canonical millisecond value lives in `pg_settings.setting`;
# `SHOW statement_timeout` renders units (e.g. "5s"), which would make
# the assertions config-value-dependent.
def read_statement_timeout(db : DB::Connection) : String
  db.query_one(
    "SELECT setting FROM pg_settings WHERE name = 'statement_timeout'",
    as: String,
  )
end

describe Facet::Database do
  it "with_transaction and with_db use the same connection (singleton pool)" do
    txn_pid = nil
    inner_pid = nil

    Facet::Database.with_transaction do |txn_db|
      txn_pid = current_pid(txn_db)
      Facet::Database.with_db do |inner_db|
        inner_pid = current_pid(inner_db)
      end
    end

    txn_pid.should eq(inner_pid)
  end

  it "with_transaction wraps two writes atomically when using the same connection" do
    Facet::Database.with_transaction do |db|
      db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
               VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "txn-test-1")
      db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
               VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "txn-test-2")
      count = db.query_one("SELECT COUNT(*) FROM mutations WHERE doc_type = 'Test'", as: Int64)
      count.should eq(2)
    end
  end

  it "with_transaction rolls back on exception" do
    expect_raises(Exception, "boom") do
      Facet::Database.with_transaction do |db|
        db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                 VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "txn-rollback-test")
        raise "boom"
      end
    end

    Facet::Database.with_db do |db|
      count = db.query_one("SELECT COUNT(*) FROM mutations WHERE doc_id = 'txn-rollback-test'", as: Int64)
      count.should eq(0)
    end
  end

  it "with_db and with_transaction share the same PID (singleton pool)" do
    txn_pid = nil
    db_pid = nil

    Facet::Database.with_transaction do |txn_db|
      txn_pid = current_pid(txn_db)
    end

    Facet::Database.with_db do |db|
      db_pid = current_pid(db)
    end

    txn_pid.should eq(db_pid)
  end

  describe "pool lifecycle" do
    after_each do
      Facet::Database.init
    end

    it "raises if accessed before init" do
      Facet::Database.close
      expect_raises(Exception, "Database not initialized") do
        Facet::Database.with_db { |_db| }
      end
    end

    it "can be re-initialized" do
      old_pid = nil
      new_pid = nil

      Facet::Database.with_db { |db| old_pid = current_pid(db) }
      Facet::Database.init
      Facet::Database.with_db { |db| new_pid = current_pid(db) }

      old_pid.should_not be_nil
      new_pid.should_not be_nil
    end

    it "close is safe when not initialized" do
      Facet::Database.close
      Facet::Database.close
    end
  end

  describe "session time zone" do
    it "pins every pooled connection to UTC" do
      Facet::Database.with_db do |db|
        tz = db.query_one("SHOW TIME ZONE", as: String)
        # PostgreSQL aliases `UTC` and `Etc/UTC`; both are acceptable.
        {"UTC", "Etc/UTC"}.should contain(tz)
      end
    end
  end

  describe "statement timeout" do
    after_each do
      # The examples below re-initialize the pool (with and without hooks).
      # Restore the suite setup — configured timeout + session tuning — for
      # every example that follows.
      init_suite_database_pool
    end

    it "applies the configured statement_timeout to every pooled connection" do
      init_suite_database_pool
      timeout = Facet::Config.instance.database.statement_timeout_ms
      timeout.should_not be_nil

      Facet::Database.with_db do |db|
        read_statement_timeout(db).should eq(timeout.not_nil!.to_s)
      end
    end

    it "leaves the setting at the PG default when init runs without a timeout" do
      Facet::Database.init

      Facet::Database.with_db do |db|
        read_statement_timeout(db).should eq("0")
      end
    end

    it "keeps independently registered connection hooks (timeout + tuning)" do
      # crystal-db's `DB::Database#setup_connection` stores a single proc;
      # `Facet::Database` composes them. Register a third hook after the
      # suite's two and verify all three took effect on a connection.
      init_suite_database_pool
      Facet::Database.setup_connection do |conn|
        conn.exec("SET application_name = 'facet_hook_composition'")
      end

      Facet::Database.with_db do |db|
        db.query_one("SHOW application_name", as: String)
          .should eq("facet_hook_composition")
        timeout = Facet::Config.instance.database.statement_timeout_ms.not_nil!
        read_statement_timeout(db).should eq(timeout.to_s)
      end
    end
  end
end
