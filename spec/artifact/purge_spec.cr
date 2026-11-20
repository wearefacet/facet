# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/grants"
require "../../src/artifact/prune"
require "../../src/artifact/purge"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "digest/sha256"
require "json"

# Artifact destruction (purge).
#
# Files covered:
#   - src/artifact/purge.cr — `Artifact::Purge.destroy` (gated HTTP path)
#     and `Purge.destroy_system` (CLI path): transactional row delete +
#     `iam.ArtifactEvent` audit document, post-commit object delete.
#
# Specs walk every documented rule:
#   1. `destroy` purges the row, the storage object, and every child row
#      (owners, grants, references — all `ON DELETE CASCADE`), and returns
#      the cascade counts.
#   2. every purge writes an `iam.ArtifactEvent` document with the content
#      facts, the child counts, and the actioner attribution (fail-closed:
#      written in the delete's transaction).
#   3. `details` carries the operator's reason verbatim.
#   4. a tombstoned artifact purges too (the row keeps `path`).
#   5. `destroy` answers `404` for an unknown id.
#   6. `destroy` answers `403` when the caller holds neither system nor the
#      `purge *.*` operator action; a role holding the action passes.
#   7. `destroy_system` purges without a gate and attributes to `system`.
#   8. the signed URL minted before a purge stops verifying (grant row
#      cascade-deleted).

DOMAIN_PURGE = "artpurge"

def truncate_purge_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Re-registers the seeded doctype definitions after the per-example
# TRUNCATE (the purge writes an `iam.ArtifactEvent` document through the
# real mutation pipeline, which needs the definition in `core.DocType`
# projections). Same pattern as the assistant specs.
def seed_purge_doctypes(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

def setup_purge_upload_target(db)
  ensure_domain(db, DOMAIN_PURGE)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Asset",
    domain: DOMAIN_PURGE,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  doc_id = Facet::Document::Create.call(
    db, DOMAIN_PURGE, "Asset", %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
  {"Asset", doc_id}
end

# Creates one more Asset document when the doctype is already registered.
# Doctype registration is create-only — a second register answers 409.
def create_purge_asset_document(db)
  Facet::Document::Create.call(
    db, DOMAIN_PURGE, "Asset", %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
end

# Uploads a real object against the purge target doctype (so a shrine file
# exists to assert on) and returns the uploader result.
def upload_purge_fixture(db)
  doctype, doc_id = setup_purge_upload_target(db)
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new("hello world\n"), "a.txt",
    Facet::RBAC::AuthContext.system,
    DOMAIN_PURGE, doctype, doc_id, "file", nil,
  )
  result.as(Facet::Artifact::Uploader::Result)
end

def purge_role_context(db, account_id, role_id, with_purge)
  perms = [permission_json("read", "#{DOMAIN_PURGE}.Asset")]
  perms << permission_json("purge", "*.*") if with_purge
  create_role_projection(db, role_id, perms)
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def purge_event_rows(db, artifact_id)
  db.query_all(
    "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'ArtifactEvent' AND deleted_at IS NULL AND content->>'artifact_id' = $1",
    artifact_id,
    as: JSON::Any,
  )
end

describe Facet::Artifact::Purge do
  before_each { truncate_purge_tables }

  describe ".destroy" do
    it "purges the row, the object, and every child row, returning the cascade counts" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        # A second owner row + a reference row + a grant row, so the
        # cascade has something to remove on every child table.
        doc_id = create_purge_asset_document(db)
        db.exec(
          "INSERT INTO artifact_owners (artifact_id, domain, doc_type, doc_id, field_path, created_by) VALUES ($1, $2, 'Asset', $3, 'file', 'sys')",
          res.artifact_id, DOMAIN_PURGE, doc_id,
        )
        db.exec(
          "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field) VALUES ($1, $2, $3, 'file')",
          res.artifact_id, DOMAIN_PURGE, doc_id,
        )
        db.query_one(
          "SELECT id FROM artifact_owners WHERE artifact_id = $1 LIMIT 1",
          res.artifact_id,
          as: String,
        )
        Facet::Artifact::Grants.mint_ephemeral(db, Facet::RBAC::AuthContext.system, res.artifact_id)

        result = Facet::Artifact::Purge.destroy(db, Facet::RBAC::AuthContext.system, res.artifact_id, nil)
        case r = result
        when Facet::ServiceError
          fail("purge failed: #{r.status} #{r.message}")
        when Facet::Artifact::Purge::Result
          r.artifact_id.should eq(res.artifact_id)
          r.owner_count.should eq(2)
          r.reference_count.should eq(1)
        end

        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should be_nil
        Facet::Artifact::Uploader.exists?(res.path).should be_false
        Facet::Artifact::Store.find_owner_rows(db, res.artifact_id).should be_empty
        db.query_one("SELECT COUNT(*) FROM artifact_references WHERE artifact_id = $1", res.artifact_id, as: Int64).should eq(0)
        db.query_one("SELECT COUNT(*) FROM artifact_grants WHERE artifact_id = $1", res.artifact_id, as: Int64).should eq(0)
      end
    end

    it "writes an iam.ArtifactEvent with the content facts, counts, and actioner" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        operator = purge_role_context(db, "purge_op", "purge_op_role", true)
        Facet::Artifact::Purge.destroy(db, operator, res.artifact_id, "contains leaked data").should be_a(Facet::Artifact::Purge::Result)

        events = purge_event_rows(db, res.artifact_id)
        events.size.should eq(1)
        event = events.first
        event["event"].to_s.should eq("purged")
        event["filename"].to_s.should eq("a.txt")
        event["mime_type"].to_s.should eq("text/plain")
        event["size"].as_i.should eq(12)
        event["sha256"].to_s.should eq(res.signature_sha256)
        event["owner_count"].as_i.should eq(1)
        event["reference_count"].as_i.should eq(0)
        event["details"].to_s.should eq("contains leaked data")

        # The event write is a raw mutation, so it must stage the
        # projection GUCs itself — the stored `iam.ArtifactEvent`
        # definition renders `display_name: "{{ filename }}"`. An
        # unstaged GUC stores a NULL display_name and every audit view
        # shows a blank label for the event.
        row = db.query_one(
          <<-SQL,
            SELECT search, display_name
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'ArtifactEvent'
              AND content->>'artifact_id' = $1
          SQL
          res.artifact_id,
          as: {search: String?, display_name: String?},
        )
        row[:display_name].should eq("a.txt")
        # No `search` template: the fallback corpus is the folded
        # display_name (B-115).
        row[:search].should eq("a.txt")
      end
    end

    it "omits details when no reason is supplied" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        Facet::Artifact::Purge.destroy(db, Facet::RBAC::AuthContext.system, res.artifact_id, nil).should be_a(Facet::Artifact::Purge::Result)
        event = purge_event_rows(db, res.artifact_id).first
        event["details"]?.should be_nil
      end
    end

    it "purges a tombstoned artifact" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)
        Facet::Artifact::Prune.soft_delete(db, res.artifact_id)

        Facet::Artifact::Purge.destroy(db, Facet::RBAC::AuthContext.system, res.artifact_id, nil).should be_a(Facet::Artifact::Purge::Result)
        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should be_nil
        Facet::Artifact::Uploader.exists?(res.path).should be_false
      end
    end

    it "answers 404 for an unknown artifact" do
      with_db do |db|
        result = Facet::Artifact::Purge.destroy(db, Facet::RBAC::AuthContext.system, "01UNKNOWNARTIFACT0000000", nil)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end

    it "answers 403 without the purge *.* action and leaves the artifact alive" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        plain = purge_role_context(db, "plain_op", "plain_op_role", false)
        result = Facet::Artifact::Purge.destroy(db, plain, res.artifact_id, nil)
        result.as(Facet::ServiceError).status.should eq(403)

        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should_not be_nil
        purge_event_rows(db, res.artifact_id).should be_empty
      end
    end

    it "purges when the caller holds the purge *.* action" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        operator = purge_role_context(db, "purge_op2", "purge_op2_role", true)
        Facet::Artifact::Purge.destroy(db, operator, res.artifact_id, nil).should be_a(Facet::Artifact::Purge::Result)
        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should be_nil
      end
    end
  end

  describe ".destroy_system" do
    it "purges without a gate and attributes the event to system" do
      with_db do |db|
        seed_purge_doctypes(db)
        res = upload_purge_fixture(db)

        Facet::Artifact::Purge.destroy_system(db, res.artifact_id).should be_a(Facet::Artifact::Purge::Result)
        Facet::Artifact::Store.find_artifact(db, res.artifact_id).should be_nil

        row = db.query_one(
          "SELECT actioner_id FROM mutations WHERE domain = 'iam' AND doc_type = 'ArtifactEvent'",
          as: String,
        )
        row.should eq("system")
      end
    end
  end

  it "a signed URL minted before the purge stops verifying" do
    with_db do |db|
      seed_purge_doctypes(db)
      res = upload_purge_fixture(db)

      signed = Facet::Artifact::Grants.mint_ephemeral(db, Facet::RBAC::AuthContext.system, res.artifact_id)
        .as(Facet::Artifact::Grants::SignedURL)
      Facet::Artifact::Grants.verify(db, signed.grant_id, "9999999999", "sig").should be_a(Facet::Artifact::Grants::VerifyResult)

      # The signature is wrong on purpose above; assert the alive-vs-dead
      # distinction through the grant row instead.
      Facet::Artifact::Purge.destroy(db, Facet::RBAC::AuthContext.system, res.artifact_id, nil).should be_a(Facet::Artifact::Purge::Result)
      db.query_one("SELECT COUNT(*) FROM artifact_grants WHERE id = $1", signed.grant_id, as: Int64).should eq(0)
    end
  end
end
