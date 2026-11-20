# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/audit"

TXTPATCH_DOMAIN = "txtpatch"

# Builds a `longtext`-bearing doctype, persists it, then yields
# `(db, doctype, doc_id, original_body)` for the block to drive.
def with_longtext_doc(initial_body : String, doctype = "Note", &)
  with_db do |db|
    ensure_domain(db, TXTPATCH_DOMAIN)
    longtext_type = Facet::Doctype::FieldType.parse("longtext")
    defn = Facet::Doctype::DoctypeDefinition.new(
      doctype: doctype,
      domain: TXTPATCH_DOMAIN,
      fields: {
        "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
      },
    )
    create_result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    create_result.should be_a(Facet::Document::Create::Result)

    body_json = JSON::Any.new({"body" => JSON::Any.new(initial_body)}).to_json
    doc_result = Facet::Document::Create.call(db, TXTPATCH_DOMAIN, doctype, body_json, Facet::RBAC::AuthContext.system)
    doc_result.should be_a(Facet::Document::Create::Result)
    doc = doc_result.as(Facet::Document::Create::Result)

    yield db, doctype, doc.projection.id, initial_body
  end
end

# Builds a long markdown-ish string.
def long_body(lines : Int32) : String
  String.build do |io|
    (1..lines).each do |i|
      io << "this is paragraph " << i << " of the document.\n"
    end
  end
end

describe "Mutation longtext patch" do
  it "emits a patch set-entry for a small edit in a long longtext" do
    body = long_body(60)
    with_longtext_doc(body) do |db, doctype, doc_id, _|
      edited = body.gsub("this is paragraph 30", "this is paragraph 30 (revised)")
      patch = %({"body": #{edited.inspect}})
      result = Facet::Document::Update.call(db, TXTPATCH_DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)

      # Pull the persisted mutation. It should carry a `patch`, not a `value`.
      mut = db.query_one(
        "SELECT arguments FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update' ORDER BY idx DESC LIMIT 1",
        TXTPATCH_DOMAIN, doctype, doc_id, as: JSON::Any
      )
      set_entry = mut["diff"]["set"].as_a.first
      set_entry["path"].should eq ["body"]
      set_entry.as_h.has_key?("patch").should be_true
      set_entry.as_h.has_key?("value").should be_false

      # Projection content should reflect the edited body.
      content = Facet::Mutation::Client.fetch_content(db, TXTPATCH_DOMAIN, doctype, doc_id)
      content["body"].as_s.should eq(edited)
    end
  end

  it "falls back to a plain value when the longtext change is small enough" do
    short_body = "hello"
    with_longtext_doc(short_body) do |db, doctype, doc_id, _|
      patch = %({"body": "world"})
      result = Facet::Document::Update.call(db, TXTPATCH_DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)

      mut = db.query_one(
        "SELECT arguments FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update' ORDER BY idx DESC LIMIT 1",
        TXTPATCH_DOMAIN, doctype, doc_id, as: JSON::Any
      )
      set_entry = mut["diff"]["set"].as_a.first
      set_entry.as_h.has_key?("value").should be_true
      set_entry["value"].as_s.should eq("world")

      content = Facet::Mutation::Client.fetch_content(db, TXTPATCH_DOMAIN, doctype, doc_id)
      content["body"].as_s.should eq("world")
    end
  end

  it "rolls back a patched longtext update via Audit::Rollback" do
    body = long_body(80)
    with_longtext_doc(body) do |db, doctype, doc_id, _|
      edited = body.gsub("this is paragraph 40", "this is paragraph 40 (revised)")
      patch = %({"body": #{edited.inspect}})
      upd = Facet::Document::Update.call(db, TXTPATCH_DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)

      # Roll back to the create mutation — the patched update will be
      # re-applied by the Crystal mirror of `jsonb_apply_diff` in Audit::Rollback.
      create_mut = db.query_one(
        "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create' LIMIT 1",
        TXTPATCH_DOMAIN, doctype, doc_id, as: String
      )

      rb = Facet::Audit::Rollback.call(db, create_mut, Facet::RBAC::AuthContext.system)
      rb.should be_a(Facet::Audit::Rollback::Result)

      result = rb.as(Facet::Audit::Rollback::Result)
      result.projection.content["body"].as_s.should eq(body)
    end
  end

  it "normalizes \\r\\n to \\n on create and update of longtext" do
    body_with_crlf = "first line\r\nsecond line\r\nthird line"
    with_longtext_doc(body_with_crlf) do |db, doctype, doc_id, _|
      # Create normalization
      content = Facet::Mutation::Client.fetch_content(db, TXTPATCH_DOMAIN, doctype, doc_id)
      content["body"].as_s.should eq("first line\nsecond line\nthird line")

      # Update with \r\n — should also be normalized.
      patch = %({"body": "first line\\r\\nsecond line (edited)\\r\\nthird line"})
      result = Facet::Document::Update.call(db, TXTPATCH_DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)

      content = Facet::Mutation::Client.fetch_content(db, TXTPATCH_DOMAIN, doctype, doc_id)
      content["body"].as_s.should eq("first line\nsecond line (edited)\nthird line")
    end
  end

  it "raises (rolls back the mutation) when a patch context line is stale" do
    body = long_body(50)
    with_longtext_doc(body) do |db, doctype, doc_id, _|
      # Compute a patch against the current body, then break the body before
      # applying so the in-DB patch context won't match.
      edited = body.gsub("this is paragraph 25", "this is paragraph 25 (revised)")
      diff = Facet::Mutation::JsonDiff.diff(
        JSON.parse(%({"body": #{body.inspect}})),
        JSON.parse(%({"body": #{edited.inspect}}))
      )
      set_entry = diff.set.first
      set_entry.patch.should_not be_nil

      # Tamper with the projection content so the patch's context lines
      # no longer match.
      tampered = body.gsub("this is paragraph 22", "this is paragraph 22 (tampered)")
      db.exec(
        "UPDATE projections SET content = $1 WHERE domain = $2 AND doc_type = $3 AND id = $4",
        JSON::Any.new({"body" => JSON::Any.new(tampered)}).to_json,
        TXTPATCH_DOMAIN, doctype, doc_id
      )

      # Build a raw update mutation using the stale patch.
      expect_raises(PQ::PQError) do
        Facet::Mutation::Client.update(
          db, TXTPATCH_DOMAIN, doctype, doc_id,
          diff_json: diff.to_json
        )
      end
    end
  end
end
