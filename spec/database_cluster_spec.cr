# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"

# The `database.cluster` route table and pools (the segregation design,
# §4.1–§4.5): route resolution, read-only enforcement, and back-compat.
#
# A spec-scoped cluster points both the primary and the replica pool at the
# worker database URL — one physical database is enough, the enforcement
# hook (not the host) refuses writes on the ro pool (§5.3).
def build_test_cluster(url : String) : Facet::Database::ClusterConfig
  Facet::Database::ClusterConfig.new(
    databases: [
      Facet::Database::ClusterDatabase.new(
        name: "spec_main",
        url: url,
        resources: ["*"],
      ),
    ],
  )
end

describe "Facet::Database cluster" do
  after_each do
    # Restore the suite setup — configured timeout + session tuning — for
    # every example that follows.
    init_suite_database_pool
  end

  describe "route resolution" do
    it "resolves every resource through the entry carrying '*'" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      Facet::Database.with_db(:read_only, "anything") do |db|
        db.query_one("SELECT 1", as: Int32).should eq(1)
      end
      Facet::Database.with_db(:read_write, "hr") do |db|
        db.query_one("SELECT 1", as: Int32).should eq(1)
      end
    end

    it "resolves a listed resource to its own entry" do
      url = ENV.fetch("DATABASE_URL")
      cluster = Facet::Database::ClusterConfig.new(
        databases: [
          Facet::Database::ClusterDatabase.new(name: "main", url: url, resources: ["*"]),
          Facet::Database::ClusterDatabase.new(name: "secondary", url: url, resources: ["hr"]),
        ],
      )
      Facet::Database.init(cluster)

      # Both entries share the worker URL, so both connections speak to the
      # same database — but they are distinct pools (D1), each with its own
      # connection. Sequential frames: the first releases its pin, the
      # second checks out from the other pool. (Nested frames would reuse
      # the held pin — the resource label is consulted at checkout only.)
      pid_secondary = Facet::Database.with_db(:read_write, "hr") do |db|
        db.query_one("SELECT pg_backend_pid()", as: Int32)
      end
      pid_main = Facet::Database.with_db(:read_write, "core") do |db|
        db.query_one("SELECT pg_backend_pid()", as: Int32)
      end
      pid_secondary.should_not eq(pid_main)
    end

    it "keeps ro requests on the enforced ro pool of the same entry" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      Facet::Database.with_db(:read_only) do |ro_db|
        ro_db.query_one("SHOW transaction_read_only", as: String).should eq("on")
      end
      Facet::Database.with_db do |rw_db|
        rw_db.query_one("SHOW transaction_read_only", as: String).should eq("off")
      end
    end
  end

  describe "read-only enforcement" do
    it "refuses INSERT and SELECT … FOR UPDATE on the ro pool, serves SELECT" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      Facet::Database.with_db(:read_only) do |ro_db|
        ro_db.query_one("SELECT 1", as: Int32).should eq(1)
        expect_raises(PQ::PQError) do
          ro_db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                      VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "ro-blocked")
        end
        expect_raises(PQ::PQError) do
          ro_db.exec("SELECT id FROM projections WHERE domain = 'x' FOR UPDATE")
        end
      end
    end

    it "writes normally on the rw pool of the same cluster" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      Facet::Database.with_db do |rw_db|
        rw_db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                    VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "rw-allowed")
        count = rw_db.query_one("SELECT COUNT(*) FROM mutations WHERE doc_id = 'rw-allowed'", as: Int64)
        count.should eq(1)
      end
    end

    it "escalates a nested rw block out of a ro scope" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      Facet::Database.with_db(:read_only) do |ro_db|
        # The ro connection refuses the write...
        expect_raises(PQ::PQError) do
          ro_db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                      VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "escalated")
        end
        # ...and the sanctioned escalation writes through its own rw
        # connection (§4.6.1). Not atomic with anything the ro scope does.
        Facet::Database.with_db(:read_write) do |rw_db|
          rw_db.exec("INSERT INTO mutations (domain, doc_type, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
                      VALUES ($1, $2, $3, 'create', 'system', '{}'::jsonb, 'internal', 'request', $3)", "test", "Test", "escalated")
        end
        # The ro connection now sees the committed row — same database.
        count = ro_db.query_one("SELECT COUNT(*) FROM mutations WHERE doc_id = 'escalated'", as: Int64)
        count.should eq(1)
      end
    end
  end

  describe "back-compat (absent cluster)" do
    it "serves ro requests from the single un-enforced pool" do
      Facet::Database.init

      Facet::Database.with_db(:read_only) do |db|
        db.query_one("SHOW transaction_read_only", as: String).should eq("off")
      end
      Facet::Database.each_pool do |_database, role, _pool|
        role.should eq("rw")
      end
    end
  end

  describe "healthcheck pool enumeration" do
    it "exposes one descriptor per (database, role)" do
      Facet::Database.init(build_test_cluster(ENV.fetch("DATABASE_URL")))

      pools = [] of {String, String}
      Facet::Database.each_pool do |database, role, pool|
        pool.scalar("SELECT 1").to_s.should eq("1")
        pools << {database, role}
      end
      pools.should eq([{"spec_main", "rw"}, {"spec_main", "ro"}])
    end
  end
end
