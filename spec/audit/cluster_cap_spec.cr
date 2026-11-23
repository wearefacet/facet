# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/audit"

# Regression for the 2026-11-23 DB desync: a causal cluster larger than
# `Audit::Rollback::CLUSTER_MUTATION_CAP` is refused with a 422, and the
# pinned transaction connection stays wire-clean.
#
# `cluster_groups` used to stream the whole cluster with a non-block
# `db.query` and `return nil` from inside the row loop. The early return
# abandoned the open `ResultSet` — and mid-`DataRow`, at the first column's
# length bytes — so the following `ROLLBACK` on the same socket read garbage
# frames. The cap is now pushed into SQL (`LIMIT cap + 1`), so a runaway
# cluster is never streamed and the connection is never abandoned.
private def cluster_cap_trace : String
  "01" + "Z" * 24
end

describe "Audit::Rollback cluster cap" do
  it "refuses a cluster above the cap and leaves the connection clean" do
    before = Facet::Metrics.value("facet_db_poisoned_discards_total")
    trace = cluster_cap_trace
    cap = Facet::Audit::Rollback::CLUSTER_MUTATION_CAP

    Facet::Database.with_transaction do |db|
      # One statement, `cap + 1` rows sharing one cause trace. The
      # projection and periodic-snapshot triggers stay active: a synthetic
      # snapshot would carry its own trace and not inflate the count.
      db.exec(
        <<-SQL,
          INSERT INTO mutations (domain, doc_type, doc_id, idx, action, actioner_id, arguments, channel, cause_kind, cause_trace)
          SELECT 'clustercap', 'Big', 'big-' || lpad(g::text, 6, '0'), 1, 'create', 'system:test',
                 jsonb_build_object('content', jsonb_build_object('name', 'row ' || g)), 'internal', 'request', $1
          FROM generate_series(1, $2) AS g
        SQL
        trace, cap + 1,
      )

      counted = db.query_one(
        "SELECT COUNT(*) FROM mutations WHERE cause_trace = $1", trace, as: Int64
      )
      counted.should eq cap + 1

      # The trace root is one of the cluster's rows: the rollback resolves
      # it first, then refuses the cluster.
      root_id = db.query_one(
        "SELECT id FROM mutations WHERE cause_trace = $1 ORDER BY idx ASC LIMIT 1", trace, as: String
      )

      result = Facet::Audit::Rollback.call(db, root_id, Facet::RBAC::AuthContext.system, scope: Facet::Audit::Rollback::Scope::Cluster)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq 422
      err.message.should contain "more than #{cap} mutations"

      # The pinned transaction connection ran the rollback's ROLLBACK and is
      # still wire-idle.
      db.scalar("SELECT 'clean'").should eq "clean"
      db.as(PG::Connection).wire_dirty?.should be_false
    end

    (Facet::Metrics.value("facet_db_poisoned_discards_total") - before).should eq 0
  end

  it "undoes a cluster at exactly the cap" do
    trace = "01" + "Y" * 24
    cap = Facet::Audit::Rollback::CLUSTER_MUTATION_CAP

    Facet::Database.with_transaction do |db|
      db.exec(
        <<-SQL,
          INSERT INTO mutations (domain, doc_type, doc_id, idx, action, actioner_id, arguments, channel, cause_kind, cause_trace)
          SELECT 'clustercap', 'Edge', 'edge-' || lpad(g::text, 6, '0'), 1, 'create', 'system:test',
                 jsonb_build_object('content', jsonb_build_object('name', 'row ' || g)), 'internal', 'request', $1
          FROM generate_series(1, $2) AS g
        SQL
        trace, cap,
      )

      root_id = db.query_one(
        "SELECT id FROM mutations WHERE cause_trace = $1 ORDER BY idx ASC LIMIT 1", trace, as: String
      )

      # At the cap the cluster is not refused for its size. The undo may
      # still fail on the synthetic documents (their doctype is not
      # registered), but it must not be the cap refusal.
      result = Facet::Audit::Rollback.call(db, root_id, Facet::RBAC::AuthContext.system, scope: Facet::Audit::Rollback::Scope::Cluster)
      if result.is_a?(Facet::ServiceError)
        result.as(Facet::ServiceError).message.should_not contain "more than #{cap} mutations"
      end

      db.scalar("SELECT 'clean'").should eq "clean"
    end
  end
end
