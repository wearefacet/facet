# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

require "../../../src/domain"
require "../../../src/domain/portable"
require "../../../src/doctype"
require "../../../src/doctype/seed"
require "../../../src/document"
require "../../../src/mutation/client"
require "../../../src/rbac"
require "../../../src/secrets/adoption"

# Specs for the secret-leaf gate on the portable-domain import door
# (B-370). A bundled row bypasses the document pipeline, so the type-layer
# check (`SecretType#validate`) and the adoption step
# (`Secrets::Adoption.call`) never ran on it — a plaintext string or a
# forged marker in a `secret` field landed verbatim in the projection, the
# event log, and export. The import now runs the same gate as the write
# door and refuses the bundle with a 422 naming the field; the refusal
# rolls the whole import back, so no mutation row persists.
#
# Each example re-seeds the core doctypes (the global per-spec truncation
# wipes them) and builds its bundle in memory — no fixture files.

# Re-registers the core doctypes that the global truncation wiped.
private def sg_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

private def sg_entry(content : String, meta : String = "{}") : Facet::Domain::Portable::Archive::Entry
  Facet::Domain::Portable::Archive::Entry.new(JSON.parse(content), JSON.parse(meta))
end

private def sg_documents(qualified : String, id : String, content : String) : Hash(String, Array(Facet::Domain::Portable::Archive::DocumentEntry))
  {qualified => [Facet::Domain::Portable::Archive::DocumentEntry.new(id, sg_entry(content))]}
end

# An in-memory bundle: a doctype with one `secret` field plus the given
# document rows. The doctype shape passes the bundled-definition authoring
# gate (mode `hash`, no `search`/`display_name` reference).
private SG_VAULT_DEFINITION = %({
  "doctype": "Vault",
  "domain": "sgdom",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {
    "name": {"type": "string"},
    "api_key": {"type": "secret", "mode": "hash"}
  }
})

private def sg_bundle(
  domain : String,
  documents : Hash(String, Array(Facet::Domain::Portable::Archive::DocumentEntry)),
  doctype_content : String = SG_VAULT_DEFINITION,
) : Facet::Domain::Portable::Archive::Bundle
  parsed = JSON.parse(doctype_content)
  doctypes = [{doctype: "#{domain}.#{parsed["doctype"].as_s}", entry: sg_entry(doctype_content)}]
  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: domain,
    exported_at: "2026-01-01T00:00:00Z",
    facet_version: "test",
    domain: sg_entry(%({"description": "secret gate bundle", "color": "#123456"})),
    doctypes: doctypes,
    document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
    collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
    documents: documents,
  )
end

# A stage-handle-shaped string: `sh_` + 26 Crockford characters. The shape
# gate accepts it; adoption refuses it, because no staging row exists for
# the import actioner.
private SG_HANDLE = "sh_01ABCDEFGHJKMNPQRSTVWXYZ26"

describe "Domain::Portable import secret-leaf gate (B-370)" do
  it "refuses a plaintext secret value with 422 naming the field, persisting nothing" do
    with_db do |db|
      sg_reseed_core(db)

      bundle = sg_bundle("sgdom",
        sg_documents("sgdom.Vault", "v1", %({"name": "n1", "api_key": "hunter2"})))

      result = Facet::Domain::Portable::Import.call(db, bundle, into: "sgtarget")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("sgtarget.Vault#v1")
      err.message.should contain("Secret field validation failed")
      err.details.not_nil!.first.field.should eq("api_key")
      err.details.not_nil!.first.message.should contain("must be a stage handle")

      # The refusal persists nothing — no mutation row anywhere.
      db.query_one(
        "SELECT count(*) FROM mutations WHERE domain = 'sgtarget'",
        as: Int64).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'sgtarget'",
        as: Int64).should eq(0)
    end
  end

  it "refuses a forged marker (shape-valid, no slot) with 422 naming the field" do
    with_db do |db|
      sg_reseed_core(db)

      bundle = sg_bundle("sgdom",
        sg_documents("sgdom.Vault", "v1",
          %({"name": "n1", "api_key": {"mode": "hash", "version": 1, "set_at": "2026-01-01T00:00:00Z"}})))

      result = Facet::Domain::Portable::Import.call(db, bundle, into: "sgtarget")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("sgtarget.Vault#v1")
      err.message.should contain("secret adoption failed")
      err.message.should contain("does not match the stored slot")
      err.message.should contain("api_key")

      db.query_one(
        "SELECT count(*) FROM mutations WHERE domain = 'sgtarget'",
        as: Int64).should eq(0)
    end
  end

  it "refuses a stage handle with 422 (no staging row exists for the import)" do
    with_db do |db|
      sg_reseed_core(db)

      bundle = sg_bundle("sgdom",
        sg_documents("sgdom.Vault", "v1", %({"name": "n1", "api_key": "#{SG_HANDLE}"})))

      result = Facet::Domain::Portable::Import.call(db, bundle, into: "sgtarget")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("secret adoption failed")
      err.message.should contain("unknown, expired, or not yours")
      err.message.should contain("api_key")

      db.query_one(
        "SELECT count(*) FROM mutations WHERE domain = 'sgtarget'",
        as: Int64).should eq(0)
    end
  end

  it "imports a bundle whose secret leaves are absent or null" do
    with_db do |db|
      sg_reseed_core(db)

      absent = sg_bundle("sgdom",
        sg_documents("sgdom.Vault", "v-absent", %({"name": "n1"})))
      result = Facet::Domain::Portable::Import.call(db, absent, into: "sgtarget1")
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)

      cleared = sg_bundle("sgdom",
        sg_documents("sgdom.Vault", "v-null", %({"name": "n2", "api_key": null})))
      result = Facet::Domain::Portable::Import.call(db, cleared, into: "sgtarget2")
      result.should be_a(Facet::Domain::Portable::Import::Result)

      content = db.query_one(
        "SELECT content FROM projections WHERE domain = 'sgtarget2' AND doc_type = 'Vault' AND id = 'v-null'",
        as: JSON::Any)
      content["api_key"].raw.should be_nil

      db.query_one(
        "SELECT count(*) FROM secrets",
        as: Int64).should eq(0)
    end
  end

  it "imports a bundle for a doctype with no secret fields unchanged" do
    with_db do |db|
      sg_reseed_core(db)

      plain = %({
        "doctype": "Widget",
        "domain": "sgdom",
        "schema_version": 1,
        "search": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      bundle = sg_bundle("sgdom",
        sg_documents("sgdom.Widget", "w1", %({"name": "n1"})), doctype_content: plain)

      result = Facet::Domain::Portable::Import.call(db, bundle, into: "sgtarget3")
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)
    end
  end
end
