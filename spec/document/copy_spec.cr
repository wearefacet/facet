# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document"
require "../../src/rbac"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Creates a parent doctype with a child relationship and the child doctype,
# both under `domain`.
def register_parent_with_child(db, domain, parent_dt, child_dt)
  parent_defn = %({
    "doctype": "#{parent_dt}",
    "domain": "#{domain}",
    "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": {"name": {"type": "string"}},
    "children": {"items": {"doctype": "#{child_dt}", "collection": true}}
  })
  Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)

  child_defn = %({
    "doctype": "#{child_dt}",
    "domain": "#{domain}",
    "member_of": "#{parent_dt}",
    "fields": {"label": {"type": "string"}}
  })
  Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
end

# Creates a parent document with N children under `domain`.
def create_parent_with_children(db, domain, parent_dt, child_dt, count)
  parent_body = %({"name": "Parent"})
  parent_res = Facet::Document::Create.call(
    db, domain, parent_dt, parent_body, Facet::RBAC::AuthContext.system
  )
  parent_id = expect_create_success(parent_res).projection.id

  child_ids = [] of String
  count.times do |i|
    child_doc = %({"label": "Child #{i}"})
    meta = %({"parent_id": #{parent_id.to_json}})
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, domain, child_dt,
      doc_id: doc_id, content: child_doc, meta: meta,
      actioner_id: "system:test",
    )
    child_ids << doc_id
  end
  {parent_id, child_ids}
end

describe Facet::Document::Copy do
  # ── deep_copy ────────────────────────────────────────────────────────────────

  describe ".deep_copy" do
    it "copies a document into a different domain with a fresh doc_id" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          ensure_domain(txn, "src")
          ensure_domain(txn, "dst")
          register_parent_with_child(txn, "src", "Widget", "Part")

          parent_id, _child_ids = create_parent_with_children(txn, "src", "Widget", "Part", 1)

          new_id = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Widget",
            doc_id: parent_id,
            actioner_id: "system:copy",
          )
          new_id.should be_a(String)
          new_id = new_id.as(String)

          # Fresh doc_id, different from source.
          new_id.should_not eq(parent_id)

          # Content copied verbatim.
          proj = Facet::Mutation::Client.fetch_projection(txn, "dst", "Widget", new_id)
          proj.content["name"].as_s.should eq("Parent")
        end
      end
    end

    it "recursively copies owned children and remaps parent_id" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          ensure_domain(txn, "src")
          ensure_domain(txn, "dst")
          register_parent_with_child(txn, "src", "Widget", "Part")

          parent_id, child_ids = create_parent_with_children(txn, "src", "Widget", "Part", 3)

          new_parent_id = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Widget",
            doc_id: parent_id,
            actioner_id: "system:copy",
          )
          new_parent_id.should be_a(String)
          new_parent_id = new_parent_id.as(String)

          # Children copied into the target domain.
          dst_children = txn.query_all(
            "SELECT id, meta->>'parent_id' FROM projections WHERE domain = 'dst' AND doc_type = 'Part' AND deleted_at IS NULL",
            as: {String, String?},
          )
          dst_children.size.should eq(3)

          # All children's parent_id mapped to the new parent.
          dst_children.each do |(id, pid)|
            pid.should eq(new_parent_id)
            child_ids.should_not contain(id)
          end
        end
      end
    end

    it "respects new_parent_id for the top-level copy" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          ensure_domain(txn, "src")
          ensure_domain(txn, "dst")
          register_parent_with_child(txn, "src", "Widget", "Part")

          parent_id, _child_ids = create_parent_with_children(txn, "src", "Widget", "Part", 1)

          new_id = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Widget",
            doc_id: parent_id,
            actioner_id: "system:copy",
            new_parent_id: "custom-parent",
          )
          new_id.should be_a(String)
          new_id = new_id.as(String)

          proj = Facet::Mutation::Client.fetch_projection(txn, "dst", "Widget", new_id)
          proj.meta["parent_id"].as_s.should eq("custom-parent")
        end
      end
    end

    it "applies the content_transformer to copied documents" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          ensure_domain(txn, "src")
          ensure_domain(txn, "dst")
          register_parent_with_child(txn, "src", "Widget", "Part")

          parent_id, _child_ids = create_parent_with_children(txn, "src", "Widget", "Part", 1)

          transformer = Facet::Document::Copy::ContentTransformer.new do |content, _src, _dst|
            h = content.as_h
            h = h.dup
            h["copied"] = JSON::Any.new(true)
            JSON::Any.new(h)
          end

          new_id = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Widget",
            doc_id: parent_id,
            actioner_id: "system:copy",
            content_transformer: transformer,
          )
          new_id.should be_a(String)
          new_id = new_id.as(String)

          proj = Facet::Mutation::Client.fetch_projection(txn, "dst", "Widget", new_id)
          proj.content["copied"].raw.should be_true
        end
      end
    end
  end

  # ── copy_children_of ─────────────────────────────────────────────────────────

  describe ".copy_children_of" do
    it "copies only the children of a document, not the document itself" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          ensure_domain(txn, "src")
          ensure_domain(txn, "dst")
          register_parent_with_child(txn, "src", "Widget", "Part")

          parent_id, _child_ids = create_parent_with_children(txn, "src", "Widget", "Part", 2)

          Facet::Document::Copy.copy_children_of(
            txn,
            from_domain: "src",
            to_domain: "dst",
            parent_doctype: "Widget",
            source_parent_id: parent_id,
            new_parent_id: "new-parent-id",
            actioner_id: "system:copy",
          )

          # Children copied into dst.
          dst_children = txn.query_all(
            "SELECT id, meta->>'parent_id' FROM projections WHERE domain = 'dst' AND doc_type = 'Part' AND deleted_at IS NULL",
            as: {String, String?},
          )
          dst_children.size.should eq(2)
          dst_children.each do |(_, pid)|
            pid.should eq("new-parent-id")
          end

          # Parent NOT copied — no Widget documents in dst.
          count = txn.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'dst' AND doc_type = 'Widget'",
            as: Int64,
          )
          count.should eq(0)
        end
      end
    end
  end
end
