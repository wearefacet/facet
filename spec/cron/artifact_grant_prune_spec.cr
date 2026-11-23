# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/cron/artifact_grant_prune"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"

# ── Helpers ──────────────────────────────────────────────────────────────

# Inserts one `artifacts` row. Returns the id.
private def agp_insert_artifact(db : DB::Connection, filename : String) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) " \
    "VALUES ($1, $2, $3, $4, $5, $6)",
    id, filename, "image/png", 10, "sha-#{id}", "path/#{id}",
  )
  id
end

# Inserts one `artifact_owners` row. Returns the owner id.
private def agp_insert_owner(db : DB::Connection, artifact_id : String) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) " \
    "VALUES ($1, $2, $3, $4, $5, $6, $7)",
    id, artifact_id, "agpdom", "Asset", Facet::Util::ScriptHelpers.ulid, "file", "system",
  )
  id
end

# Inserts one `artifact_grants` row. Returns the grant id.
private def agp_insert_grant(db : DB::Connection, artifact_id : String, owner_id : String, kind : String,
                             expires_at : Time? = nil) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifact_grants (id, artifact_id, owner_id, kind, expires_at, created_by) " \
    "VALUES ($1, $2, $3, $4, $5, $6)",
    id, artifact_id, owner_id, kind, expires_at, "agp-spec",
  )
  id
end

private def agp_grant_exists(db : DB::Connection, grant_id : String) : Bool
  !db.query_one?("SELECT 1 FROM artifact_grants WHERE id = $1", grant_id, as: Int32).nil?
end

private def agp_age_grant(db : DB::Connection, grant_id : String, days : Int32, hours : Int32 = 0) : Nil
  # Moves the expiry back in time so the retention window boundary can be
  # exercised without waiting. `expires_at` and `now()` are both tz-naive
  # UTC, so the interval math is deterministic (see the Time / Timezone
  # contract).
  db.exec(
    "UPDATE artifact_grants SET expires_at = now() - make_interval(days => $1, hours => $2) WHERE id = $3",
    days, hours, grant_id,
  )
end

# ── Specs ────────────────────────────────────────────────────────────────

describe Facet::Cron::ArtifactGrantPrune do
  before_each do
    with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
  end

  it "deletes expired ephemeral grants past the retention window" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-expired.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      agp_age_grant(db, grant_id, 8)

      Facet::Cron::ArtifactGrantPrune.call
      agp_grant_exists(db, grant_id).should be_false
    end
  end

  it "keeps ephemeral grants inside the retention window" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-fresh.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      agp_age_grant(db, grant_id, 3)

      Facet::Cron::ArtifactGrantPrune.call
      agp_grant_exists(db, grant_id).should be_true
    end
  end

  it "keeps permanent grants no matter how long ago they were minted" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-permanent.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "permanent", nil)

      Facet::Cron::ArtifactGrantPrune.call
      agp_grant_exists(db, grant_id).should be_true

      # The primitive honors the same contract for direct callers.
      Facet::Artifact::Grants.prune_expired(db, retention_days: 7).should eq(0)
      agp_grant_exists(db, grant_id).should be_true
    end
  end

  it "deletes nothing when the caller passes a 0 window (keep forever)" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-forever.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      agp_age_grant(db, grant_id, 400)

      Facet::Artifact::Grants.prune_expired(db, retention_days: 0).should eq(0)
      agp_grant_exists(db, grant_id).should be_true
    end
  end

  it "keeps a row expired less than the window ago and deletes one expired longer" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-boundary.png")
      owner_id = agp_insert_owner(db, artifact_id)
      inside = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      past = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      # One hour of slack takes the boundary out of the microseconds between
      # fixture and pass: 6 days 23 hours stays, 7 days 1 hour goes.
      agp_age_grant(db, inside, 6, 23)
      agp_age_grant(db, past, 7, 1)

      Facet::Artifact::Grants.prune_expired(db, retention_days: 7).should eq(1)
      agp_grant_exists(db, inside).should be_true
      agp_grant_exists(db, past).should be_false
    end
  end

  it "is idempotent: a second pass deletes nothing" do
    with_db do |db|
      artifact_id = agp_insert_artifact(db, "agp-twice.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      agp_age_grant(db, grant_id, 10)

      Facet::Artifact::Grants.prune_expired(db, retention_days: 7).should eq(1)
      Facet::Artifact::Grants.prune_expired(db, retention_days: 7).should eq(0)
      agp_grant_exists(db, grant_id).should be_false
    end
  end

  it "resolves the retention window from the runtime settings on call" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"artifact": {"grant_prune_days": 10}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      # No Redis fanout runs in the unit suite — invalidate like the subscriber.
      Facet::SystemSettings.mark_stale

      artifact_id = agp_insert_artifact(db, "agp-pinned.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      # 8 days expired: past the file default (7 — the pass would delete it)
      # but inside the pinned window (10). Survival proves the pass read the
      # pinned value.
      agp_age_grant(db, grant_id, 8)

      Facet::Cron::ArtifactGrantPrune.call
      agp_grant_exists(db, grant_id).should be_true
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "honors a pinned 0 from the settings (keep forever)" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      pin = Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"artifact": {"grant_prune_days": 0}}),
        Facet::RBAC::AuthContext.system,
      )
      pin.should be_a(Facet::Document::Update::Result)
      Facet::SystemSettings.mark_stale

      artifact_id = agp_insert_artifact(db, "agp-pinned-forever.png")
      owner_id = agp_insert_owner(db, artifact_id)
      grant_id = agp_insert_grant(db, artifact_id, owner_id, "ephemeral", nil)
      agp_age_grant(db, grant_id, 400)

      Facet::Cron::ArtifactGrantPrune.call
      agp_grant_exists(db, grant_id).should be_true
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end
end
