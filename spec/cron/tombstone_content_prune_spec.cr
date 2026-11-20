# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/cron/tombstone_content_prune"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"

# ── Helpers ──────────────────────────────────────────────────────────────

# Creates a live document with content, then deletes it through the normal
# soft-delete path, so the tombstone carries a pre-delete payload per the
# retention contract.
def seed_prune_tombstone(domain : String, doctype : String, name : String) : String
  with_db do |db|
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, domain, doctype,
      doc_id: doc_id,
      content: %({"name": #{name.to_json}}),
      actioner_id: "system:prune-spec",
    )
    Facet::Mutation::Client.delete(db, domain, doctype, doc_id, "system:prune-spec")
    doc_id
  end
end

def tombstone_payload(db : DB::Connection, doc_id : String) : {JSON::Any, JSON::Any, String?, Time?}
  row = db.query_one?(
    "SELECT content, links, search, deleted_at FROM projections WHERE id = $1",
    doc_id,
    as: {JSON::Any, JSON::Any, String?, Time?},
  )
  raise "projection row not found: #{doc_id}" if row.nil?
  row
end

def age_tombstone(db : DB::Connection, doc_id : String, days : Int32) : Nil
  # Moves the tombstone marker back in time so the prune window boundary
  # can be exercised without waiting. `deleted_at` is tz-naive UTC, and
  # `now()` is pinned to UTC, so the interval math is deterministic.
  db.exec(
    "UPDATE projections SET deleted_at = now() - make_interval(days => $1) WHERE id = $2",
    days, doc_id,
  )
end

# ── Specs ────────────────────────────────────────────────────────────────

describe Facet::Cron::TombstoneContentPrune do
  it "resolves the retention window from the runtime settings on call" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"tombstone": {"content_retention_days": 10}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      # No Redis fanout runs in the unit suite — invalidate like the subscriber.
      Facet::SystemSettings.mark_stale

      doc_id = seed_prune_tombstone("prunetest", "Widget", "pinned-window")
      # 20 days old: inside the file default (30) but past the pinned
      # window (10) — only the settings-resolved pass may clear the payload.
      age_tombstone(db, doc_id, 20)

      Facet::Cron::TombstoneContentPrune.call
      content, _links, _search, _deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse("{}"))
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "keeps every payload when the pinned window is 0 (keep forever)" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"tombstone": {"content_retention_days": 0}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      Facet::SystemSettings.mark_stale

      doc_id = seed_prune_tombstone("prunetest", "Widget", "keep-forever")
      age_tombstone(db, doc_id, 400) # far past every window

      Facet::Cron::TombstoneContentPrune.call
      content, _links, _search, _deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse(%({"name": "keep-forever"})))
      # The primitive honors the same contract for direct callers.
      Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 0).should eq(0)
      content, _links, _search, _deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse(%({"name": "keep-forever"})))
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  before_each do
    with_db do |db|
      ensure_domain(db, "prunetest")
      Facet::Doctype::DefinitionStore.cache.clear
      body = %({
        "doctype": "Widget",
        "domain": "prunetest",
        "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": { "type": "string" }
        }
      })
      result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
      raise "prune spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
    end
  end

  it "clears content/links/search on tombstones older than the retention window" do
    doc_id = seed_prune_tombstone("prunetest", "Widget", "expired")

    with_db do |db|
      age_tombstone(db, doc_id, 31)

      cleared = Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30)
      cleared.should eq(1)

      content, links, search, deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse("{}"))
      links.should eq(JSON.parse("[]"))
      search.should be_nil
      # The tombstone marker itself survives the prune — the row stays
      # deleted, only the payload is dropped.
      deleted_at.should_not be_nil
    end
  end

  it "keeps the payload on tombstones inside the retention window" do
    doc_id = seed_prune_tombstone("prunetest", "Widget", "fresh")

    with_db do |db|
      age_tombstone(db, doc_id, 10)

      cleared = Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30)
      cleared.should eq(0)

      content, _links, _search, _deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse(%({"name": "fresh"})))
    end
  end

  it "treats the retention boundary as exclusive (row exactly N days old is cleared)" do
    doc_id = seed_prune_tombstone("prunetest", "Widget", "boundary")

    with_db do |db|
      age_tombstone(db, doc_id, 30)

      cleared = Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30)
      cleared.should eq(1)
    end
  end

  it "never clears display_name (audit views label tombstones with it)" do
    doc_id = seed_prune_tombstone("prunetest", "Widget", "labelled")

    with_db do |db|
      # Stage a display_name so the prune's payload clear cannot touch it.
      db.exec(
        "UPDATE projections SET display_name = 'labelled' WHERE id = $1",
        doc_id,
      )
      age_tombstone(db, doc_id, 31)

      Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30)

      display_name = db.query_one(
        "SELECT display_name FROM projections WHERE id = $1",
        doc_id, as: String?)
      display_name.should eq("labelled")
    end
  end

  it "is idempotent: a second pass clears nothing" do
    doc_id = seed_prune_tombstone("prunetest", "Widget", "twice")

    with_db do |db|
      age_tombstone(db, doc_id, 31)

      Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30).should eq(1)
      Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30).should eq(0)
    end
  end

  it "does not touch live rows" do
    with_db do |db|
      doc_id = Facet::Util::ScriptHelpers.ulid
      Facet::Mutation::Client.create(
        db, "prunetest", "Widget",
        doc_id: doc_id,
        content: %({"name": "live"}),
        actioner_id: "system:prune-spec",
      )

      cleared = Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30)
      cleared.should eq(0)

      content, _links, _search, _deleted_at = tombstone_payload(db, doc_id)
      content.should eq(JSON.parse(%({"name": "live"})))
    end
  end
end
