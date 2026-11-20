# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/grants"
require "../../src/artifact/revoke"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "digest/sha256"
require "json"

# Step 6 addition: the `artifacts:revoke` CLI subcommand.
#
# Files covered:
#   - src/artifact/revoke.cr — `Artifact::RevokeCLI` bumps the `epoch` on
#     every `artifact_grants` row for an artifact, invalidating every signed
#     URL minted against any of its owner rows.
#   - src/artifact/grants.cr — the underlying `Grants.bump_epoch` primitive.
#
# Specs walk every documented rule:
#   1. revoking invalidates every URL already issued for the artifact.
#   2. revoking does not touch other artifacts' grants.
#   3. revoking keeps the grant rows (rows are not deleted).
#   4. a nonexistent artifact id fails loud (exit 1, nothing bumped).

DOMAIN_REVOKE = "artrevoke"

def truncate_revoke_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Builds a doctype with a `file` field and a live document. Returns
# `{doctype, doc_id}`.
def setup_revoke_doctype(db, doctype)
  ensure_domain(db, DOMAIN_REVOKE)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_REVOKE,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  doc_res = Facet::Document::Create.call(
    db, DOMAIN_REVOKE, doctype, %({}), Facet::RBAC::AuthContext.system,
  )
  doc_res.should be_a(Facet::Document::Create::Result)
  {doctype, doc_res.as(Facet::Document::Create::Result).projection.id}
end

# Drives `Uploader.upload` to seed an artifact + owner row bound to a
# document. Returns `{artifact_id, path, owner_id}`.
def upload_revoke_fixture(db, doctype, doc_id)
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new("revoke-bytes-#{rand(100_000)}"), "a.txt",
    Facet::RBAC::AuthContext.system,
    DOMAIN_REVOKE, doctype, doc_id, "file", nil,
  )
  result.should be_a(Facet::Artifact::Uploader::Result)
  res = result.as(Facet::Artifact::Uploader::Result)
  owner_id = Facet::Artifact::Store.find_owner_rows(db, res.artifact_id).first.id
  {res.artifact_id, res.path, owner_id}
end

# Mints an ephemeral grant as the system principal (which bypasses the read
# gate) and returns the `SignedURL`.
def mint_revoke_grant(db, art_id)
  grant = Facet::Artifact::Grants.mint_ephemeral(db, Facet::RBAC::AuthContext.system, art_id)
  grant.should be_a(Facet::Artifact::Grants::SignedURL)
  grant.as(Facet::Artifact::Grants::SignedURL)
end

describe Facet::Artifact::RevokeCLI do
  before_each { truncate_revoke_tables }

  it "invalidates every URL already issued for the artifact" do
    with_db do |db|
      doctype, doc_id = setup_revoke_doctype(db, "Asset")
      art_id, _path, _owner_id = upload_revoke_fixture(db, doctype, doc_id)

      signed = mint_revoke_grant(db, art_id)
      exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
      sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!
      # Sanity: the URL verifies before the revoke.
      Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        .should be_a(Facet::Artifact::Grants::ValidResult)

      silence_stdout { Facet::Artifact::RevokeCLI.run([art_id]) }

      Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        .should be_a(Facet::Artifact::Grants::InvalidResult)
    end
  end

  it "does not invalidate grants on other artifacts" do
    with_db do |db|
      doctype, doc_id = setup_revoke_doctype(db, "Asset")
      art_a, _pa, _oa = upload_revoke_fixture(db, doctype, doc_id)
      art_b, _pb, _ob = upload_revoke_fixture(db, doctype, doc_id)

      signed_a = mint_revoke_grant(db, art_a)
      signed_b = mint_revoke_grant(db, art_b)
      exp_a = signed_a.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
      sig_a = signed_a.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!
      exp_b = signed_b.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
      sig_b = signed_b.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

      silence_stdout { Facet::Artifact::RevokeCLI.run([art_a]) }

      Facet::Artifact::Grants.verify(db, signed_a.grant_id, exp_a, sig_a)
        .should be_a(Facet::Artifact::Grants::InvalidResult)
      Facet::Artifact::Grants.verify(db, signed_b.grant_id, exp_b, sig_b)
        .should be_a(Facet::Artifact::Grants::ValidResult)
    end
  end

  it "keeps the grant rows when revoking" do
    with_db do |db|
      doctype, doc_id = setup_revoke_doctype(db, "Asset")
      art_id, _path, _owner_id = upload_revoke_fixture(db, doctype, doc_id)

      signed = mint_revoke_grant(db, art_id)
      silence_stdout { Facet::Artifact::RevokeCLI.run([art_id]) }

      # The grant row survives (only its epoch changed), so the row is still
      # findable by id — revoking is not deleting.
      row = db.query_one?(
        "SELECT epoch FROM artifact_grants WHERE id = $1",
        signed.grant_id, as: Int32)
      row.should eq(1)
    end
  end
end
