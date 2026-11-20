# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# Boot-time seed reconcile (`Doctype::Seed.seed`): the embedded corpus is the
# source of truth for system doctypes.
#
# Covers:
#   - a seeded database reconciles to a no-op (no false drift between the
#     stored rows and the corpus)
#   - a drifted definition is re-applied through `Doctype::Update`
#     (`Report#updated`, stored content back to the seed, `seed` cause)
#   - a stored definition ahead of the seed (version downgrade) fails loudly
#   - a deleted seed document is re-created by the documents pass
#   - a busy reconcile lock skips the pass
# ─────────────────────────────────────────────────────────────────────────────

private def stored_definition(db : DB::Connection, doctype_id : String) : JSON::Any
  db.query_one(
    "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1",
    doctype_id,
    as: JSON::Any,
  )
end

private def latest_cause_kind(db : DB::Connection, doctype_id : String) : String?
  db.query_one?(
    "SELECT cause_kind FROM mutations WHERE domain = 'core' AND doc_type = 'DocType' AND doc_id = $1 ORDER BY idx DESC LIMIT 1",
    doctype_id,
    as: String,
  )
end

describe "Doctype::Seed reconcile" do
  it "is a no-op on a database that already matches the corpus" do
    with_db do |db|
      restore_seeded_baseline(db)
      report = Facet::Doctype::Seed.seed(db)
      report.empty?.should be_true, "drift: created=#{report.created.join(", ")} updated=#{report.updated.join(", ")}"
      report.created.should eq([] of String)
      report.updated.should eq([] of String)
    end
  end

  it "re-applies a drifted definition through Doctype::Update" do
    with_db do |db|
      restore_seeded_baseline(db)

      seed_color = stored_definition(db, "core.Domain")["color"].as_s
      drift = Facet::Document::Update.call(
        db, "core", "DocType", "core.Domain",
        %({"color": "#FF0000"}),
        Facet::RBAC::AuthContext.system,
      )
      drift.should be_a(Facet::Document::Update::Result)
      stored_definition(db, "core.Domain")["color"].as_s.should eq("#FF0000")

      report = Facet::Doctype::Seed.seed(db)

      report.updated.should eq(["core.Domain"])
      stored_definition(db, "core.Domain")["color"].as_s.should eq(seed_color)
      latest_cause_kind(db, "core.Domain").should eq("seed")
    end
  end

  it "fails loudly when the stored definition is ahead of the seed" do
    with_db do |db|
      restore_seeded_baseline(db)

      # The generic document pipeline validates a core.DocType row on
      # update (a version bump requires a migration map), so stage the
      # ahead state with direct SQL — this spec targets the seed's
      # downgrade guard, not the drift mechanism.
      db.exec(
        "UPDATE projections SET content = jsonb_set(content, '{schema_version}', '2') " \
        "WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'core.Domain'",
      )

      expect_raises(Exception, "Seed update for core.Domain failed") do
        Facet::Doctype::Seed.seed(db)
      end
    end
  end

  it "re-creates a seed document deleted from the database" do
    with_db do |db|
      restore_seeded_baseline(db)

      view_id = db.query_one(
        "SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'DocumentView' AND deleted_at IS NULL LIMIT 1",
        as: String,
      )
      deleted = Facet::Document::Delete.call(db, "core", "DocumentView", view_id, Facet::RBAC::AuthContext.system)
      deleted.should be_a(Facet::Document::Delete::Result)

      report = Facet::Doctype::Seed.seed(db)

      # The definition pass saw no drift; the documents pass restored the row.
      report.empty?.should be_true
      Facet::Util::Projections.exists?(db, "core", "DocumentView", view_id).should be_true
    end
  end

  it "skips the pass when another boot holds the reconcile lock" do
    Facet::Doctype::Seed.reconcile_lock_timeout = 200.milliseconds
    begin
      with_db do |db|
        restore_seeded_baseline(db)
        db.exec("SELECT pg_advisory_lock($1)", Facet::Doctype::Seed::RECONCILE_LOCK_KEY)
        begin
          report = Facet::Doctype::Seed.seed(db)
          report.empty?.should be_true
        ensure
          db.exec("SELECT pg_advisory_unlock($1)", Facet::Doctype::Seed::RECONCILE_LOCK_KEY)
        end
      end
    ensure
      Facet::Doctype::Seed.reconcile_lock_timeout = 30.seconds
    end
  end
end
