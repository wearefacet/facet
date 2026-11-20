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

# Specs for the authoring gate on bundled doctype definitions (B-302).
# The fresh-import path persists definitions verbatim — no
# `Doctype::Validation`, no `ScriptValidator`, no `DraftTargetCheck`, no
# named-scope validation — so a hand-edited bundle could land definitions
# the REST authoring door refuses with 422. The import now runs the same
# battery before it persists, and the rejection rolls the whole import
# back.
#
# Each example re-seeds the core doctypes (the global per-spec truncation
# wipes them) and builds its bundle in memory — no fixture files.

# Re-registers the core doctypes that the global truncation wiped.
private def dtg_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Wraps raw content into a bundle entry (empty meta — doctype entries
# carry no parent linkage; the import rewrites the domain field itself).
private def dtg_entry(content : String) : Facet::Domain::Portable::Archive::Entry
  Facet::Domain::Portable::Archive::Entry.new(JSON.parse(content), JSON.parse(%({})))
end

# Builds an in-memory bundle for `domain` with the given doctype entries.
private def dtg_bundle(
  domain : String,
  doctype_contents : Array(String),
  domain_content : String = %({"description": "doctype gate bundle", "color": "#123456"}),
) : Facet::Domain::Portable::Archive::Bundle
  doctypes = doctype_contents.map do |content|
    parsed = JSON.parse(content)
    {doctype: "#{domain}.#{parsed["doctype"].as_s}", entry: dtg_entry(content)}
  end
  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: domain,
    exported_at: "2026-01-01T00:00:00Z",
    facet_version: "test",
    domain: dtg_entry(domain_content),
    doctypes: doctypes,
    document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
    collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
  )
end

# A `search` template that references a `secret` field — the leak shape
# the REST authoring door refuses (`validate_secret_fields`).
DTG_SECRET_SEARCH = %({
  "doctype": "Vault",
  "domain": "dtgate",
  "schema_version": 1,
  "fields": {"ssn": {"type": "secret", "mode": "hash"}},
  "search": "{{ ssn }}"
})

# A `search` template that references a field the doctype does not define
# (`validate_search` — the template compiles but the variable does not
# resolve).
DTG_UNDEFINED_SEARCH = %({
  "doctype": "Thing",
  "domain": "dtgate",
  "schema_version": 1,
  "fields": {"name": {"type": "string"}},
  "search": "{{ ghost }}"
})

# A named scope whose `where` references a context set the domain does
# not declare.
DTG_UNKNOWN_SCOPE = %({
  "doctype": "Scoped",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {"name": {"type": "string"}},
  "scopes": {"mine": {"where": {"name": "$no_such_set"}}}
})

# A cross-domain reference whose target domain name carries the draft
# prefix (`DraftTargetCheck` — B-287).
DTG_DRAFT_TARGET = %({
  "doctype": "Ref",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {"other": {"type": "reference", "doctype": "_dtgate2.Thing"}}
})

# Valid control definitions — the same shapes land through the REST door.
DTG_VALID_WIDGET = %({
  "doctype": "Widget",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {"name": {"type": "string"}}
})

DTG_VALID_GADGET = %({
  "doctype": "Gadget",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ size }}",
  "fields": {"size": {"type": "integer"}}
})

# A doctype whose script is the empty string — the shape a definition
# carries when the script editor was empty at save time. The authoring
# door treats it as "no script"; the import gates must too.
DTG_EMPTY_SCRIPT = %({
  "doctype": "Emptied",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {"name": {"type": "string"}},
  "script": ""
})

# The same definition with one additive field — the merge re-import is
# no longer content-identical, so the version gate runs on it.
DTG_EMPTY_SCRIPT_GROWN = %({
  "doctype": "Emptied",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {"name": {"type": "string"}, "note": {"type": "string"}},
  "script": ""
})

# A doctype that declares a named action but ships an empty script — the
# authoring door refuses it, so the import door must too.
DTG_ACTIONS_EMPTY_SCRIPT = %({
  "doctype": "Acted",
  "domain": "dtgate",
  "schema_version": 1,
  "search": "{{ name }}",
  "fields": {"name": {"type": "string"}},
  "actions": {"publish": {"args": {}}},
  "script": ""
})

# A field that omits `type` — the definition grammar rejects it before
# any row is written. The error must name the bundle, not a stored
# definition.
DTG_MISSING_TYPE = %({
  "doctype": "Leech",
  "domain": "dtgate",
  "schema_version": 1,
  "fields": {"stolen": {"title": "x"}}
})

describe "Domain::Portable import doctype authoring gate (B-302)" do
  it "refuses a fresh import whose search template references a secret field (422, all-or-nothing)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_SECRET_SEARCH, DTG_VALID_WIDGET])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Vault")
      err.message.should contain("schema validation failed")

      # The transaction rolled back — no doctype row, no domain row.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'dtgate.%'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'dtgate'",
        as: Int64
      ).should eq(0)
    end
  end

  it "refuses a fresh import whose search template references an undefined field (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_UNDEFINED_SEARCH])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Thing")
      err.message.should contain("schema validation failed")
    end
  end

  it "refuses a fresh import whose named scope references an undeclared context set (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_UNKNOWN_SCOPE])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Scoped")
      err.message.should contain("named scope validation failed")
    end
  end

  it "refuses a fresh import whose reference targets a draft domain (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_DRAFT_TARGET])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Ref")
      err.message.should contain("draft domain")
    end
  end

  it "refuses a merge import that creates a missing doctype with an invalid definition (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      # Land the valid base first, so the merge reaches the create door
      # only through the missing-row branch.
      clean = dtg_bundle("dtgate", [DTG_VALID_WIDGET])
      clean_result = Facet::Domain::Portable::Import.call(db, clean)
      clean_result.should be_a(Facet::Domain::Portable::Import::Result)

      # The merge carries one unchanged doctype and one new invalid one.
      bundle = dtg_bundle("dtgate", [DTG_VALID_WIDGET, DTG_SECRET_SEARCH])
      result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Vault")
      err.message.should contain("schema validation failed")

      # The rolled-back merge left the target at its prior state.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'dtgate.Vault'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'dtgate.Widget'",
        as: Int64
      ).should eq(1)
    end
  end

  it "imports a doctype whose script is the empty string (fresh and merge re-import)" do
    with_db do |db|
      dtg_reseed_core(db)

      # Fresh import runs the authoring gate on the bundled definition.
      bundle = dtg_bundle("dtgate", [DTG_EMPTY_SCRIPT])
      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).doctypes_created.should eq(1)

      # The grown merge is not content-identical, so the version gate
      # runs on the empty script too.
      grown = dtg_bundle("dtgate", [DTG_EMPTY_SCRIPT_GROWN])
      merge_result = Facet::Domain::Portable::Import.call(db, grown, merge: true)
      merge_result.should be_a(Facet::Domain::Portable::Import::Result)
      merge_result.as(Facet::Domain::Portable::Import::Result).doctypes_updated.should eq(1)

      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'dtgate.Emptied'",
        as: Int64
      ).should eq(1)
    end
  end

  it "refuses a doctype that declares actions with an empty script (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_ACTIONS_EMPTY_SCRIPT])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Acted")
      err.message.should contain("schema validation failed")
      err.details.not_nil!.any?(&.message.includes?("actions are declared but no script is defined")).should be_true
    end
  end

  it "names the bundle, not a stored definition, when a bundled field misses 'type' (422)" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_MISSING_TYPE])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("dtgate.Leech")
      err.message.should contain("bundle doctype definition is invalid")
      err.message.should contain("must declare a 'type'")
      err.message.should_not contain("stored doctype definition is corrupt")
    end
  end

  it "still imports a valid bundle with two clean definitions" do
    with_db do |db|
      dtg_reseed_core(db)

      bundle = dtg_bundle("dtgate", [DTG_VALID_WIDGET, DTG_VALID_GADGET])
      result = Facet::Domain::Portable::Import.call(db, bundle)

      result.should be_a(Facet::Domain::Portable::Import::Result)
      res = result.as(Facet::Domain::Portable::Import::Result)
      res.doctypes_created.should eq(2)

      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'dtgate.%'",
        as: Int64
      ).should eq(2)
    end
  end
end
