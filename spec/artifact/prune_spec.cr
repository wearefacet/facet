# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/prune"
require "../../src/artifact/purge"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "digest/sha256"
require "json"

# Step 6 of the artifact system: prune.
#
# Files covered:
#   - src/artifact/prune.cr — `Artifact::Prune` eligibility (join-derived)
#     and soft delete, plus the `PruneCLI` subcommand. Hard deletion lives
#     in `Artifact::Purge` (spec/artifact/purge_spec.cr) — the CLI `--hard`
#     path routes through it so every destruction writes the audit event.
#
# Specs walk every documented rule:
#   1. an artifact with no owner rows and no references is eligible (once
#      past the prune window — see rule 9).
#   2. an artifact with a live owner row is kept.
#   3. an artifact whose owner rows all point at tombstoned documents is
#      eligible (the live-document join disciplines out dead owners).
#   4. an artifact with owners but no references is kept (owner clause
#      alone is sufficient).
#   5. an artifact with a recent reference is kept.
#   6. an artifact with only stale references is eligible.
#   7. soft-delete sets deleted_at and keeps the row.
#   8. the CLI soft-deletes by default and purges with --hard.
#   9. an artifact with no owners and no references is KEPT while its
#      `created_at` is within the prune window (Option D — a dangling
#      upload survives at least one prune window so the uploader has time
#      to link it into a document).

DOMAIN_PRUNE = "artprune"

def truncate_prune_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Inserts an `artifacts` row directly (no shrine put — prune operates on
# the DB rows). `created_at` defaults to 31 days ago so the row is past the
# standard 30-day prune window — callers that want to exercise the
# within-window floor pass an explicit value.
def insert_prune_artifact(db, id, sha = "hash-#{id}", created_at : Time = Time.utc - 31.days)
  db.exec(
    "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path, created_at) VALUES ($1, 'a.txt', 'text/plain', 4, $2, $3, $4)",
    id, sha, "#{sha}/#{id}", created_at,
  )
  id
end

# Inserts an `artifact_owners` row pointing at a live document. Returns the
# owner id.
def insert_prune_owner(db, artifact_id, doc_id, field_path = "file", owner_id = "owner-#{artifact_id}-#{field_path}")
  db.exec(
    "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) VALUES ($1, $2, $3, 'Asset', $4, $5, 'sys')",
    owner_id, artifact_id, DOMAIN_PRUNE, doc_id, field_path,
  )
  owner_id
end

# Inserts an `artifact_references` row with the given last_reference_at.
def insert_prune_reference(db, artifact_id, resource_id, last_reference_at : Time)
  db.exec(
    "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field, last_reference_at) VALUES ($1, $2, $3, 'file', $4)",
    artifact_id, DOMAIN_PRUNE, resource_id, last_reference_at,
  )
end

# Creates a live document of `DOMAIN_PRUNE.Asset` and returns its doc_id.
def create_prune_document(db)
  ensure_domain(db, DOMAIN_PRUNE)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Asset",
    domain: DOMAIN_PRUNE,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  Facet::Document::Create.call(
    db, DOMAIN_PRUNE, "Asset", %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
end

# Tombstones a document by soft-deleting its projection row directly.
def tombstone_document(db, doc_id)
  db.exec("UPDATE projections SET deleted_at = now() WHERE id = $1", doc_id)
end

describe Facet::Artifact::Prune do
  before_each { truncate_prune_tables }

  describe ".eligible_ids" do
    it "returns nothing when the window is 0 (keep forever)" do
      with_db do |db|
        insert_prune_artifact(db, "art-ancient", created_at: Time.utc - 400.days)
        Facet::Artifact::Prune.eligible_ids(db, 0).should be_empty
      end
    end

    it "keeps a dangling upload whose created_at is within the prune window (Option D)" do
      with_db do |db|
        insert_prune_artifact(db, "art-fresh", created_at: Time.utc - 1.hour)
        Facet::Artifact::Prune.eligible_ids(db, 30).should be_empty
      end
    end

    it "returns an artifact with no owners and no references" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-orphan")
        Facet::Artifact::Prune.eligible_ids(db, 30).should eq([id])
      end
    end

    it "keeps an artifact with a live owner row" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-owned")
        doc_id = create_prune_document(db)
        insert_prune_owner(db, id, doc_id)
        Facet::Artifact::Prune.eligible_ids(db, 30).should be_empty
      end
    end

    it "keeps an artifact with owners but no references (owner clause alone is sufficient)" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-owned-noref")
        doc_id = create_prune_document(db)
        insert_prune_owner(db, id, doc_id)
        Facet::Artifact::Prune.eligible_ids(db, 30).should be_empty
      end
    end

    it "makes an artifact eligible when all its owner docs are tombstoned" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-deadowner")
        doc_id = create_prune_document(db)
        insert_prune_owner(db, id, doc_id)
        tombstone_document(db, doc_id)
        Facet::Artifact::Prune.eligible_ids(db, 30).should eq([id])
      end
    end

    it "keeps an artifact with a recent reference" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-recentref")
        insert_prune_reference(db, id, "doc-1", Time.utc - 1.hour)
        Facet::Artifact::Prune.eligible_ids(db, 30).should be_empty
      end
    end

    it "makes an artifact eligible when all references are older than the window" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-staleref")
        insert_prune_reference(db, id, "doc-1", Time.utc - 31.days)
        Facet::Artifact::Prune.eligible_ids(db, 30).should eq([id])
      end
    end

    it "excludes already-soft-deleted artifacts" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-deleted")
        Facet::Artifact::Prune.soft_delete(db, id)
        Facet::Artifact::Prune.eligible_ids(db, 30).should be_empty
      end
    end
  end

  describe ".soft_delete" do
    it "sets deleted_at and leaves the row on the books" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-soft")
        Facet::Artifact::Prune.soft_delete(db, id)
        artifact = Facet::Artifact::Store.find_artifact(db, id)
        artifact.should_not be_nil
        artifact.not_nil!.deleted_at.should_not be_nil
      end
    end

    it "is idempotent" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-soft2")
        Facet::Artifact::Prune.soft_delete(db, id)
        Facet::Artifact::Prune.soft_delete(db, id)
        artifact = Facet::Artifact::Store.find_artifact(db, id)
        artifact.not_nil!.deleted_at.should_not be_nil
      end
    end
  end

  describe Facet::Artifact::PruneCLI do
    it "soft-deletes eligible artifacts by default" do
      with_db do |db|
        id = insert_prune_artifact(db, "art-cli-soft")
        silence_stdout { Facet::Artifact::PruneCLI.run([] of String) }
        artifact = Facet::Artifact::Store.find_artifact(db, id)
        artifact.should_not be_nil
        artifact.not_nil!.deleted_at.should_not be_nil
      end
    end

    it "purges eligible artifacts with --hard, through the audited purge primitive" do
      with_db do |db|
        # `--hard` routes through `Artifact::Purge`, which writes an
        # `iam.ArtifactEvent` document — the doctype definition must exist
        # after the per-example TRUNCATE.
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        # Upload a real object so there is a shrine file to delete.
        doctype, doc_id = setup_prune_upload_target(db)
        result = Facet::Artifact::Uploader.upload(
          db, IO::Memory.new("hello world\n"), "a.txt",
          Facet::RBAC::AuthContext.system,
          DOMAIN_PRUNE, doctype, doc_id, "file", nil,
        )
        res = result.as(Facet::Artifact::Uploader::Result)
        # Remove the owner row so the artifact becomes eligible, and age the
        # row past the prune window (the standalone-upload created_at floor
        # would otherwise protect a fresh orphan).
        db.exec("DELETE FROM artifact_owners WHERE artifact_id = $1", res.artifact_id)
        db.exec("UPDATE artifacts SET created_at = now() - interval '31 days' WHERE id = $1", res.artifact_id)

        silence_stdout { Facet::Artifact::PruneCLI.run(["--hard"]) }
        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should be_nil
        Facet::Artifact::Uploader.exists?(res.path).should be_false
        events = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = 'iam' AND doc_type = 'ArtifactEvent' AND content->>'artifact_id' = $1",
          res.artifact_id,
          as: Int64,
        )
        events.should eq(1)
      end
    end
  end
end

# Builds a doctype + live document for the hard-delete spec (needs a real
# upload so there is a shrine object to assert on).
def setup_prune_upload_target(db)
  ensure_domain(db, DOMAIN_PRUNE)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Asset",
    domain: DOMAIN_PRUNE,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  doc_id = Facet::Document::Create.call(
    db, DOMAIN_PRUNE, "Asset", %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
  {"Asset", doc_id}
end
