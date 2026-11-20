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

# Specs for the `$force` knob on the import merge branch
# (`Domain::Portable::Import`). The flag lives at the root of the bundled
# doctype entry content and relaxes the same-version destructive-edit
# rejections exactly as an editor-driven `Doctype::Update` with `$force`
# does. Everything else the version gate enforces (migrations guard,
# version decrease, version jump) stays enforced, and the flag is never
# persisted — see `doc/backend/portable-domains.md`.
#
# Each example re-seeds the core doctypes (the global truncation wipes
# them) and one live domain with a v1 `Widget` doctype (`name`, `color`
# string fields). The tampered-bundle helper replaces the bundle's single
# doctype entry, mirroring a hand-authored bundle.

# Re-registers the core doctypes the global truncation wiped.
def force_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Seeds a live domain `name` with one doctype `Widget` at v1 carrying the
# `name` and `color` string fields. No views, no documents — the force
# specs exercise the doctype merge path only.
def force_seed_source_domain(db, name)
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "force test #{name}"}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: %({
      "doctype": "Widget",
      "domain": "#{name}",
      "schema_version": 1,
      "search": "{{ name }}",
      "fields": {
        "name": {"type": "string"},
        "color": {"type": "string"}
      }
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )
end

# Returns a copy of `bundle` whose single doctype entry carries
# `content_json` (parsed) as its content root. Meta is preserved.
def force_bundle_with_doctype(
  bundle : Facet::Domain::Portable::Archive::Bundle,
  content_json : String,
)
  entry = bundle.doctypes[0]
  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: bundle.source_domain,
    exported_at: bundle.exported_at,
    facet_version: bundle.facet_version,
    domain: bundle.domain,
    doctypes: [{
      doctype: entry[:doctype],
      entry:   Facet::Domain::Portable::Archive::Entry.new(JSON.parse(content_json), entry[:entry].meta),
    }],
    document_views: bundle.document_views,
    collection_views: bundle.collection_views,
  )
end

# Reads the stored `core.DocType` content for the qualified id.
def force_stored_doctype(db, qualified)
  Facet::Mutation::Client.fetch_projection(db, "core", "DocType", qualified).content
end

# Seeds a live domain with one v1 `Widget` doctype covering every gated
# data-shape class: a nested object property, a scalar `collection` flag,
# constraints, an enum, a reference, a `children` entry, and `member_of`.
def force_seed_rich_domain(db, name)
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "force rich #{name}"}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: %({
      "doctype": "Widget",
      "domain": "#{name}",
      "schema_version": 1,
      "search": "{{ display_name }}",
      "fields": {
        "name": {"type": "string"},
        "color": {"type": "string"},
        "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
        "tag": {"type": "string", "collection": false},
        "size": {"type": "integer", "min": 0},
        "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
        "owner": {"type": "reference", "doctype": "hr.Employee"}
      },
      "children": {"events": {"doctype": "Event"}},
      "member_of": "Company"
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )
end

# Exports the seeded domain, swaps the bundle's single doctype entry for
# `content_json`, and merges. Returns the import result.
def force_merge_with(db, content_json)
  bundle = Facet::Domain::Portable::Export.call(db, "forcerich")
    .as(Facet::Domain::Portable::Export::Result).bundle
  tampered = force_bundle_with_doctype(bundle, content_json)
  Facet::Domain::Portable::Import.call(db, tampered, merge: true)
end

# Asserts the generic same-version data-shape rejection naming `label`.
def force_expect_shape_rejection(result, label)
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(422)
  err.message.should contain("data shape")
  err.message.should contain(label)
end

describe "Domain::Portable::Import $force" do
  it "rejects a same-version field removal without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {"name": {"type": "string"}}
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("same-version edit cannot remove fields")
      err.message.should contain("color")

      # The stored row is untouched.
      content = force_stored_doctype(db, "forcesrc.Widget")
      content["fields"].as_h.size.should eq(2)
      content["schema_version"].as_i.should eq(1)
    end
  end

  it "permits a same-version field removal with $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {"name": {"type": "string"}}
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).doctypes_updated.should eq(1)

      # The removal landed at the same schema_version.
      content = force_stored_doctype(db, "forcesrc.Widget")
      content["fields"].as_h.size.should eq(1)
      content["fields"].as_h.has_key?("name").should be_true
      content["schema_version"].as_i.should eq(1)
    end
  end

  it "rejects a same-version type change without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "integer"}
        }
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("same-version edit cannot change type of field 'color'")
    end
  end

  it "permits a same-version type change with $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "integer"}
        }
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).doctypes_updated.should eq(1)

      content = force_stored_doctype(db, "forcesrc.Widget")
      content["fields"]["color"]["type"].as_s.should eq("integer")
      content["schema_version"].as_i.should eq(1)
    end
  end

  it "still rejects migrations on a same-version edit with $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"}
        },
        "migrations": {"1->1": "function migrate(ctx) return ctx end"}
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("same-version edit must not include migrations")
    end
  end

  it "still rejects a version decrease with $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle

      # Bump the stored doctype to v2 — the bundle's v1 then decreases.
      Facet::Database.with_transaction do |txn|
        Facet::Mutation::Client.update(
          txn, "core", "DocType", "forcesrc.Widget",
          diff_json: %({"set": [{"path": ["schema_version"], "value": 2}]}),
          actioner_id: "system:test",
        )
      end
      Facet::Doctype::DefinitionStore.cache.clear

      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"}
        }
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("schema_version cannot decrease")
    end
  end

  it "still rejects a version jump past +1 with $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 3,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"}
        }
      }))

      result = Facet::Domain::Portable::Import.call(db, tampered, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("must be exactly 2")
    end
  end

  # ── Generic same-version data-shape gate (merge branch) ───────────

  it "rejects a same-version nested property removal without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "children": {"events": {"doctype": "Event"}},
        "member_of": "Company"
      }))
      force_expect_shape_rejection(result, "field 'meta' property 'city' removed")
    end
  end

  it "rejects a same-version collection flip without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
          "tag": {"type": "string", "collection": true},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "children": {"events": {"doctype": "Event"}},
        "member_of": "Company"
      }))
      force_expect_shape_rejection(result, "field 'tag' collection false → true")
    end
  end

  it "rejects a same-version constraint change without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 18},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "children": {"events": {"doctype": "Event"}},
        "member_of": "Company"
      }))
      force_expect_shape_rejection(result, "field 'size' min/max/pattern changed")
    end
  end

  it "rejects a same-version enum key removal without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "children": {"events": {"doctype": "Event"}},
        "member_of": "Company"
      }))
      force_expect_shape_rejection(result, "field 'status' enum keys changed")
    end
  end

  it "rejects a same-version reference target change without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
          "owner": {"type": "reference", "doctype": "hr.Contractor"}
        },
        "children": {"events": {"doctype": "Event"}},
        "member_of": "Company"
      }))
      force_expect_shape_rejection(result, "field 'owner' reference target hr.Employee → hr.Contractor")
    end
  end

  it "rejects a same-version children removal and member_of change without $force" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "member_of": "Group"
      }))
      changes = ["children: entry 'events' removed", "member_of: Company → Group"]
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("data shape")
      changes.each { |label| err.message.should contain(label) }
    end
  end

  it "permits every gated data-shape class with $force and never stores the flag" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {}},
          "tag": {"type": "string", "required": true},
          "size": {"type": "integer", "min": 18},
          "status": {"type": "enum", "values": [{"key": "a"}]},
          "owner": {"type": "reference", "doctype": "hr.Contractor"}
        },
        "member_of": "Group"
      }))
      result.should be_a(Facet::Domain::Portable::Import::Result)
      result.as(Facet::Domain::Portable::Import::Result).doctypes_updated.should eq(1)

      content = force_stored_doctype(db, "forcerich.Widget")
      content["fields"]["tag"]["required"].as_bool.should be_true
      content["fields"]["size"]["min"].as_i.should eq(18)
      content["schema_version"].as_i.should eq(1)
      content["$force"]?.should be_nil
    end
  end

  it "keeps additive edits legal without $force through the merge branch" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_rich_domain(db, "forcerich")

      result = force_merge_with(db, %({
        "doctype": "Widget",
        "domain": "forcerich",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string"},
          "color": {"type": "string"},
          "meta": {"type": "object", "properties": {"city": {"type": "string"}, "zip": {"type": "string"}}},
          "tag": {"type": "string", "collection": false},
          "size": {"type": "integer", "min": 0},
          "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}, {"key": "c"}]},
          "owner": {"type": "reference", "doctype": "hr.Employee"}
        },
        "children": {"events": {"doctype": "Event"}, "logs": {"doctype": "Log"}},
        "member_of": "Company"
      }))
      result.should be_a(Facet::Domain::Portable::Import::Result)

      content = force_stored_doctype(db, "forcerich.Widget")
      content["fields"]["meta"]["properties"].as_h.has_key?("zip").should be_true
      content["children"].as_h.has_key?("logs").should be_true
    end
  end

  it "never stores $force; a re-exported bundle is round-trip clean" do
    with_db do |db|
      force_reseed_core(db)
      force_seed_source_domain(db, "forcesrc")

      bundle = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      tampered = force_bundle_with_doctype(bundle, %({
        "doctype": "Widget",
        "domain": "forcesrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "$force": true,
        "fields": {"name": {"type": "string"}}
      }))

      Facet::Domain::Portable::Import.call(db, tampered, merge: true)
        .as(Facet::Domain::Portable::Import::Result)

      # The stored row carries no $force key.
      content = force_stored_doctype(db, "forcesrc.Widget")
      content["$force"]?.should be_nil

      # A re-export of the domain carries no $force either.
      reexport = Facet::Domain::Portable::Export.call(db, "forcesrc")
        .as(Facet::Domain::Portable::Export::Result).bundle
      reexport.doctypes[0][:entry].content["$force"]?.should be_nil
    end
  end
end
