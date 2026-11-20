# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/cron/mutation_compaction"
require "../../src/audit"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# ── Helpers ──────────────────────────────────────────────────────────────

COMPACT_DOMAIN = "compacttest"

# Registers a plain doctype in the compaction domain. Returns the doctype name.
def register_compact_doctype(db : DB::Connection, name : String = "T#{unique_suffix}") : String
  ensure_domain(db, COMPACT_DOMAIN)
  Facet::Doctype::DefinitionStore.invalidate("#{COMPACT_DOMAIN}.#{name}")
  create_schema = %({"doctype": "#{name}", "domain": "#{COMPACT_DOMAIN}", "fields": {"name": {"type": "string"}, "count": {"type": "integer"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
  raise "compaction spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  name
end

# Creates a document and applies `edits` sequential updates. Returns the doc id
# and the update mutation ids in application order.
def seed_compact_doc(db : DB::Connection, doctype : String, edits : Int32) : {String, Array(String)}
  doc_res = Facet::Document::Create.call(
    db, COMPACT_DOMAIN, doctype,
    %({"name": "seed", "count": 0}),
    Facet::RBAC::AuthContext.system,
  )
  doc_id = expect_create_success(doc_res).projection.id

  mut_ids = [] of String
  edits.times do |i|
    result = Facet::Document::Update.call(
      db, COMPACT_DOMAIN, doctype, doc_id,
      %({"name": "step#{i + 1}", "count": #{i + 1}}),
      Facet::RBAC::AuthContext.system,
    )
    mut_ids << result.as(Facet::Document::Update::Result).mutation_id
  end
  {doc_id, mut_ids}
end

# Ages the document's rows up to and including `through_idx` beyond the
# retention horizon, so the cut lands on `through_idx`.
def age_compact_rows(db : DB::Connection, doctype : String, doc_id : String, through_idx : Int32, days : Int32) : Nil
  db.exec(
    <<-SQL,
      UPDATE mutations SET emitted_at = now() - make_interval(days => $1)
      WHERE domain = $2 AND doc_type = $3 AND doc_id = $4 AND idx <= $5
    SQL
    days, COMPACT_DOMAIN, doctype, doc_id, through_idx,
  )
end

def compact_rows(db : DB::Connection, doctype : String, doc_id : String) : Array({Int32, String, String})
  db.query_all(
    "SELECT idx, action, cause_kind FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx ASC",
    COMPACT_DOMAIN, doctype, doc_id,
    as: {Int32, String, String}
  )
end

def projection_snapshot(db : DB::Connection, doctype : String, doc_id : String)
  db.query_one(
    "SELECT content, state, updated_at, deleted_at FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
    COMPACT_DOMAIN, doctype, doc_id,
    as: {JSON::Any, String, Time, Time?}
  )
end

# ── Specs ────────────────────────────────────────────────────

describe Facet::Cron::MutationCompaction do
  it "resolves the retention window from the runtime settings on call" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"mutations": {"retention_days": 200}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      # No Redis fanout runs in the unit suite — invalidate like the subscriber.
      Facet::SystemSettings.mark_stale

      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 4)
      # 190 days old: outside the file default (180) but inside the pinned
      # window (200) — only the settings-resolved pass may keep the rows.
      age_compact_rows(db, doctype, doc_id, 5, 190)

      Facet::Cron::MutationCompaction.call
      compact_rows(db, doctype, doc_id).size.should eq(5) # create + 4 updates
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "keeps every row when the pinned window is 0 (keep forever)" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"mutations": {"retention_days": 0}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      Facet::SystemSettings.mark_stale

      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 4)
      age_compact_rows(db, doctype, doc_id, 5, 400) # far past every window

      Facet::Cron::MutationCompaction.call
      compact_rows(db, doctype, doc_id).size.should eq(5)
      # The primitive honors the same contract for direct callers.
      Facet::Cron::MutationCompaction.compact(db, retention_days: 0).should eq(0)
      compact_rows(db, doctype, doc_id).size.should eq(5)
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "replaces the aged history with one compaction snapshot at the cut" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 6)

      # Age everything through idx 5 (create=1, updates=2..7); idx 6 and 7
      # stay fresh, so the cut lands on idx 5.
      age_compact_rows(db, doctype, doc_id, 5, 200)

      before_proj = projection_snapshot(db, doctype, doc_id)
      Facet::Event::Publisher.flush
      event_manager.clear!

      removed = Facet::Cron::MutationCompaction.compact(db, retention_days: 180)
      removed.should eq(5) # idx 1..5 removed

      rows = compact_rows(db, doctype, doc_id)
      rows.size.should eq(3) # snapshot@5 + retained 6, 7
      rows[0].should eq({5, "snapshot", "compaction"})
      rows[1].should eq({6, "update", "request"})
      rows[2].should eq({7, "update", "request"})

      # The compaction row carries the cut row's emitted_at (backdated).
      cut_emitted = db.query_one(
        "SELECT emitted_at FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx = 5",
        COMPACT_DOMAIN, doctype, doc_id, as: Time
      )
      aged = db.query_one("SELECT now() - make_interval(days => 200)", as: Time)
      (cut_emitted - aged).total_seconds.abs.should be < 5

      # Projection untouched: state, updated_at, content, deleted_at.
      after_proj = projection_snapshot(db, doctype, doc_id)
      after_proj.should eq(before_proj)

      # No events: the pass changes no document state.
      Facet::Event::Publisher.flush
      event_manager.events_for("FACET:RESOURCE:#{COMPACT_DOMAIN}:#{doctype}").should be_empty
    end
  end

  it "replays the cut state into the compaction snapshot arguments" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 4)
      age_compact_rows(db, doctype, doc_id, 4, 200)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180)

      args = db.query_one(
        "SELECT arguments FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND cause_kind = 'compaction'",
        COMPACT_DOMAIN, doctype, doc_id, as: JSON::Any
      )
      # idx 1=create, 2=update1, 3=update2, 4=update3 — the cut at idx 4
      # holds the state after the third update.
      args["content"]["name"].as_s.should eq("step3")
      args["content"]["count"].as_i.should eq(3)
      args["version"].as_i.should eq(1)
      args["created_at"].as_s.should_not be_nil
      args["meta"].as_h.should_not be_empty
    end
  end

  it "is idempotent: a rerun is a no-op (short path)" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 5)
      age_compact_rows(db, doctype, doc_id, 5, 200)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(5)
      rows_after_first = compact_rows(db, doctype, doc_id)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(0)
      compact_rows(db, doctype, doc_id).should eq(rows_after_first)
    end
  end

  it "skips documents whose only aged row is the first (cut_idx <= 1)" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 2)
      age_compact_rows(db, doctype, doc_id, 1, 200)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(0)
      compact_rows(db, doctype, doc_id).size.should eq(3) # create + 2 updates
    end
  end

  it "skips documents with no row older than the window" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 3)
      age_compact_rows(db, doctype, doc_id, 3, 100) # inside a 180-day window

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(0)
      compact_rows(db, doctype, doc_id).size.should eq(4)
    end
  end

  it "uses the per-doctype retention override" do
    with_db do |db|
      overridden = register_compact_doctype(db)
      plain = register_compact_doctype(db)
      doc_a, _ = seed_compact_doc(db, overridden, 3)
      doc_b, _ = seed_compact_doc(db, plain, 3)
      age_compact_rows(db, overridden, doc_a, 4, 40)
      age_compact_rows(db, plain, doc_b, 4, 40)

      Facet::Cron::MutationCompaction.compact(
        db, retention_days: 180,
        overrides: {"#{COMPACT_DOMAIN}.#{overridden}" => 30},
      ).should eq(4)

      # Overridden doctype compacted; plain doctype untouched (40 < 180).
      compact_rows(db, overridden, doc_a).first.should eq({4, "snapshot", "compaction"})
      compact_rows(db, plain, doc_b).size.should eq(4)
    end
  end

  # B-172. core.SchematicLayout carries the platform's one per-doctype
  # override: drag saves are high-churn, low-value history, bounded to a
  # week by `mutations.retention_overrides` in config.{env}.yml.
  it "resolves the 7-day config override for core.SchematicLayout" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      Facet::Mutation::Retention.effective_days(db, "core", "SchematicLayout").should eq(7)
      # Control: a doctype with no override key keeps the file base.
      Facet::Mutation::Retention.effective_days(db, "core", "DocType").should eq(180)
    end
  end

  it "compacts an aged core.SchematicLayout history through the config-driven pass" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SchematicLayout")
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")

      # Earlier examples pin the settings base to 0 (keep forever) — that
      # disables the config-driven pass. Re-pin a positive base.
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"mutations": {"retention_days": 180}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      Facet::SystemSettings.mark_stale

      domain = "schem#{unique_suffix}"
      ensure_domain(db, domain)
      doc_res = Facet::Document::Create.call(
        db, "core", "SchematicLayout",
        %({"domain": "#{domain}", "positions": {"#{domain}.Widget": {"x": 1, "y": 2}}}),
        Facet::RBAC::AuthContext.system,
      )
      doc_id = doc_res.as(Facet::Document::Create::Result).projection.id

      # Four drag saves — one mutation each (the test env disables
      # write-time coalescing).
      4.times do |i|
        patch = Facet::Document::Update.call(
          db, "core", "SchematicLayout", doc_id,
          %({"positions": {"#{domain}.Widget": {"x": #{i + 10}, "y": #{i + 20}}}}),
          Facet::RBAC::AuthContext.system,
        )
        patch.should be_a(Facet::Document::Update::Result)
      end

      # Age every row (idx 1..5) to 8 days — outside the 7-day override,
      # far inside the 180-day base.
      db.exec(
        <<-SQL,
          UPDATE mutations SET emitted_at = now() - make_interval(days => $1)
          WHERE domain = 'core' AND doc_type = 'SchematicLayout' AND doc_id = $2 AND idx <= 5
        SQL
        8, doc_id,
      )

      # The config-driven pass applies the override from
      # Facet::Config.instance.mutations.retention_overrides.
      Facet::Cron::MutationCompaction.call

      rows = db.query_all(
        "SELECT idx, action, cause_kind FROM mutations WHERE domain = 'core' AND doc_type = 'SchematicLayout' AND doc_id = $1 ORDER BY idx ASC",
        doc_id, as: {Int32, String, String})
      rows.size.should eq(1) # create + 4 updates folded into one snapshot
      rows.first.should eq({5, "snapshot", "compaction"})

      # The projection is untouched and the cut replays the last state.
      args = db.query_one(
        "SELECT arguments FROM mutations WHERE domain = 'core' AND doc_type = 'SchematicLayout' AND doc_id = $1 AND cause_kind = 'compaction'",
        doc_id, as: JSON::Any)
      args["content"]["positions"]["#{domain}.Widget"]["x"].as_i.should eq(13)
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "clamps the cut on tombstoned documents: delete and predecessor survive" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 4)
      # idx: create=1, updates=2..5, delete=6. Clamp = 6-2 = 4.
      del = Facet::Document::Delete.call(db, COMPACT_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
      del.should be_a(Facet::Document::Delete::Result)
      delete_idx = compact_rows(db, doctype, doc_id).last[0]
      delete_idx.should eq(6)

      age_compact_rows(db, doctype, doc_id, 6, 200)

      removed = Facet::Cron::MutationCompaction.compact(db, retention_days: 180)
      removed.should eq(4) # idx 1..4 removed

      # snapshot@4, the delete's predecessor (idx 5), and the delete (idx 6)
      # all survive — restore resolution needs the predecessor.
      rows = compact_rows(db, doctype, doc_id)
      rows.size.should eq(3)
      rows[0].should eq({4, "snapshot", "compaction"})
      rows[1].should eq({5, "update", "request"})
      rows[2].should eq({6, "delete", "request"})
    end
  end

  it "keeps restore and rollback-to-delete working after compaction of a tombstone" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 3)
      Facet::Document::Delete.call(db, COMPACT_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
      age_compact_rows(db, doctype, doc_id, 5, 200)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(3)

      # Restore resolves the mutation before the delete and rolls back to
      # it — the predecessor must have survived the compaction.
      target = Facet::Audit::Restore.resolve_target(db, COMPACT_DOMAIN, doctype, doc_id)
      target.should be_a(String)

      result = Facet::Audit::Rollback.call(db, target.as(String), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::Rollback::Result)
      restored = result.as(Facet::Audit::Rollback::Result)
      restored.projection.content["name"].as_s.should eq("step3")
      restored.projection.deleted_at.should be_nil
    end
  end

  it "skips a tombstone whose delete is too close to the start (delete_idx - 2 < 1)" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 0)
      # idx: create=1, delete=2. Clamp = 0 → skip.
      Facet::Document::Delete.call(db, COMPACT_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
      age_compact_rows(db, doctype, doc_id, 2, 200)

      Facet::Cron::MutationCompaction.compact(db, retention_days: 180).should eq(0)
      compact_rows(db, doctype, doc_id).size.should eq(2)
    end
  end

  it "rolls back to a retained mutation with the correct content after compaction" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, mut_ids = seed_compact_doc(db, doctype, 6)
      age_compact_rows(db, doctype, doc_id, 5, 200)
      Facet::Cron::MutationCompaction.compact(db, retention_days: 180)

      # mut_ids[4] is the update at idx 6 (the first retained row).
      result = Facet::Audit::Rollback.call(db, mut_ids[4], Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::Rollback::Result)
      rb = result.as(Facet::Audit::Rollback::Result)
      rb.projection.content["name"].as_s.should eq("step5")
      rb.projection.content["count"].as_i.should eq(5)
    end
  end

  it "rolls back to the compaction snapshot itself" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 6)
      age_compact_rows(db, doctype, doc_id, 5, 200)
      Facet::Cron::MutationCompaction.compact(db, retention_days: 180)

      snapshot_id = db.query_one(
        "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND cause_kind = 'compaction'",
        COMPACT_DOMAIN, doctype, doc_id, as: String
      )

      result = Facet::Audit::Rollback.call(db, snapshot_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::Rollback::Result)
      rb = result.as(Facet::Audit::Rollback::Result)
      # The cut at idx 5 holds the state after the fourth update.
      rb.projection.content["name"].as_s.should eq("step4")
      rb.projection.content["count"].as_i.should eq(4)
    end
  end

  it "shows the compaction row in the audit list with its cause_kind" do
    with_db do |db|
      doctype = register_compact_doctype(db)
      doc_id, _mut_ids = seed_compact_doc(db, doctype, 4)
      age_compact_rows(db, doctype, doc_id, 4, 200)
      Facet::Cron::MutationCompaction.compact(db, retention_days: 180)

      list = Facet::Audit::List.call(
        db,
        domain: COMPACT_DOMAIN,
        doc_type: doctype,
        doc_id: doc_id,
        auth_context: Facet::RBAC::AuthContext.system,
      )
      list.should be_a(Facet::Audit::List::Result)
      items = list.as(Facet::Audit::List::Result).items
      compaction_rows = items.select(&.cause_kind.==("compaction"))
      compaction_rows.size.should eq(1)
      compaction_rows.first.action.should eq("snapshot")
      compaction_rows.first.actioner_id.should eq("system:compaction")
    end
  end
end
