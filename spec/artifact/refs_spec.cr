# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/rbac"
require "../../src/artifact/refs"

# `Artifact::Refs` — the service behind the MCP `list_artifact_refs` tool.
#
# The fixtures insert straight into the artifact tables and `projections`
# (the service is a pure reader — driving the uploader and the document
# services would only re-exercise their own specs; the end-to-end path is
# covered in `spec/agent_tools/artifacts_spec.cr`). The auth contexts use
# `Facet::RBAC::AuthContext.system` where the point is the row plumbing;
# the gate cases build bespoke roles.
#
# Specs walk every documented rule:
#   1. Reference rows list with their placement field, doc_type, and
#      display_name (projection join).
#   2. `limit` caps the result and `capped` reports honestly.
#   3. Newest reference first within a pair.
#   4. Unknown, tombstoned, ownerless, denied-artifact, and dead-owner
#      gates all collapse to one 404 ServiceError.
REFS_DOMAIN = "refservdom"

private def refs_insert_artifact(db) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) " \
    "VALUES ($1, 'refs.png', 'image/png', 1, $1, $1 || '/' || $1)",
    id,
  )
  id
end

private def refs_insert_owner(db, artifact_id : String, doc_id : String) : Nil
  db.exec(
    "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) " \
    "VALUES ($1, $2, $3, 'Asset', $4, 'file', 'system')",
    Facet::Util::ScriptHelpers.ulid, artifact_id, REFS_DOMAIN, doc_id,
  )
end

private def refs_insert_projection(db, doc_id : String, display_name : String? = nil,
                                   doc_type : String = "Asset") : Nil
  db.exec(
    "INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, display_name, updated_at, created_at) " \
    "VALUES ($1, $2, $3, '{}', 1, '[]', '{}', 'state', $4, now(), now())",
    REFS_DOMAIN, doc_type, doc_id, display_name,
  )
end

private def refs_insert_reference(db, artifact_id : String, resource_id : String, field : String,
                                  last_reference_at : Time = Time.utc) : Nil
  db.exec(
    "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field, last_reference_at) " \
    "VALUES ($1, $2, $3, $4, $5)",
    artifact_id, REFS_DOMAIN, resource_id, field, last_reference_at,
  )
end

# Builds an authenticated context for a freshly-seeded role with the
# given permission lines. `create_role_projection` stores the role under
# doctype `Role` (singular), so the content is read back the same way
# `spec/artifact/admin_spec.cr` reads it — not through `RoleStore`, which
# matches `doc_type = 'Roles'` only.
private def refs_auth(db, perms : Array(JSON::Any)) : Facet::RBAC::AuthContext
  account_id = Facet::Util::ScriptHelpers.ulid
  role_id = "iam.Roles.refs-#{Facet::Util::ScriptHelpers.ulid}"
  create_role_projection(db, role_id, perms)
  create_account_projection(db, account_id, [role_id])
  content = Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  role = Facet::RBAC::ActiveRole.from_projection_content(content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe Facet::Artifact::Refs do
  before_each do
    with_db &.exec(
      "TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE",
    )
  end

  it "lists references with placement, doc_type, and display_name" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      ref_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, ref_doc, display_name: "The Compactor")
      refs_insert_reference(db, art, ref_doc, "file")

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      items = result.as(Facet::Artifact::Refs::Result).items
      items.size.should eq(1)
      item = items.first
      item.id.should eq(ref_doc)
      item.domain.should eq(REFS_DOMAIN)
      item.doc_type.should eq("Asset")
      item.field.should eq("file")
      item.display_name.should eq("The Compactor")
      result.as(Facet::Artifact::Refs::Result).capped.should be_false
    end
  end

  it "lists every placement of one document as its own row" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      ref_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, ref_doc)
      refs_insert_reference(db, art, ref_doc, "file")
      refs_insert_reference(db, art, ref_doc, "body")

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      items = result.as(Facet::Artifact::Refs::Result).items
      items.size.should eq(2)
      items.map(&.field).should contain("file")
      items.map(&.field).should contain("body")
    end
  end

  it "caps at limit and reports capped" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      2.times do
        ref_doc = Facet::Util::ScriptHelpers.ulid
        refs_insert_projection(db, ref_doc)
        refs_insert_reference(db, art, ref_doc, "file")
      end

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art, limit: 1)
      res = result.as(Facet::Artifact::Refs::Result)
      res.items.size.should eq(1)
      res.capped.should be_true
    end
  end

  it "orders newest reference first within a pair" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      old_doc = Facet::Util::ScriptHelpers.ulid
      new_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, old_doc)
      refs_insert_projection(db, new_doc)
      refs_insert_reference(db, art, old_doc, "file", last_reference_at: 1.hour.ago)
      refs_insert_reference(db, art, new_doc, "file")

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      items = result.as(Facet::Artifact::Refs::Result).items
      items.first.id.should eq(new_doc)
      items.last.id.should eq(old_doc)
    end
  end

  it "answers 404 for an unknown artifact" do
    with_db do |db|
      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, Facet::Util::ScriptHelpers.ulid)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "answers 404 for a tombstoned artifact" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      db.exec("UPDATE artifacts SET deleted_at = now() WHERE id = $1", art)

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("(deleted)")
    end
  end

  it "answers 404 for an ownerless artifact, even for system" do
    with_db do |db|
      art = refs_insert_artifact(db)

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "answers 404 for a denied artifact (non-disclosing)" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)

      ctx = refs_auth(db, [JSON.parse(%({"action": "read", "on": "otherdomain.*"}))])
      result = Facet::Artifact::Refs.call(db, ctx, art)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "answers 404 when every owner document is tombstoned" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      db.exec("UPDATE projections SET deleted_at = now() WHERE domain = $1 AND id = $2", REFS_DOMAIN, owner_doc)

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "excludes a tombstoned referrer projection" do
    with_db do |db|
      art = refs_insert_artifact(db)
      owner_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, owner_doc)
      refs_insert_owner(db, art, owner_doc)
      ref_doc = Facet::Util::ScriptHelpers.ulid
      refs_insert_projection(db, ref_doc)
      refs_insert_reference(db, art, ref_doc, "file")
      db.exec("UPDATE projections SET deleted_at = now() WHERE domain = $1 AND id = $2", REFS_DOMAIN, ref_doc)

      result = Facet::Artifact::Refs.call(db, Facet::RBAC::AuthContext.system, art)
      result.as(Facet::Artifact::Refs::Result).items.size.should eq(0)
    end
  end
end
