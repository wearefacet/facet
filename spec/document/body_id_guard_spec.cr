# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

describe Facet::Document::Create do
  describe "body id guard" do
    it "rejects a body id on a non-Domain create" do
      with_temp_doctype("bidplain") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
        Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

        result = Facet::Document::Create.call(db, domain, doctype, %({"id": "loc-1", "title": "x"}), Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.message.should eq("Document validation failed")
        details = err.details.not_nil!
        details.size.should eq(1)
        details.first.field.should eq("id")
        details.first.code.should eq("reserved")
        details.first.message.should eq("is assigned by the server and cannot be set on create")
      end
    end

    it "rejects an unknown top-level key on a compound body and persists nothing" do
      with_temp_doctype("bidcompound") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        # The relationship name as a bare top-level key is the classic
        # mistake — it must not answer 201 with zero children.
        body = %({"$content": {"name": "Parent"}, "items": [{"label": "Child A"}]})
        result = Facet::Document::CreateWithChildren.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("items")
        err.message.should contain("$children")

        count = db.query_one("SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL", domain, doctype, as: Int64)
        count.should eq(0)
      end
    end

    it "keeps reading the body id as the domain name on a core.Domain create" do
      with_db do |db|
        domain = "bid-#{unique_suffix(6).downcase}"
        result = Facet::Document::Create.call(db, "core", "Domain", %({"id": "#{domain}", "color": "#123456"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(result).projection
        proj.id.should eq(domain)
        proj.doc_type.should eq("Domain")
      end
    end

    it "keeps the Domain 422 when the body carries neither id nor domain" do
      with_db do |db|
        result = Facet::Document::Create.call(db, "core", "Domain", %({"color": "#123456"}), Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.message.should eq("Domain creation requires an 'id' or 'domain' field in the body")
      end
    end

    it "rejects a doctype that declares the reserved id field" do
      with_temp_doctype("bidfield") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"id": {"type": "string"}, "title": {"type": "string", "required": true}}})
        result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.details.not_nil!.any? { |d| d.field == "id" && d.code == "reserved" }.should be_true
      end
    end

    it "rejects a body id on a compound child body" do
      with_temp_doctype("bidchild") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"id": "kid-1", "label": "Child A"}]}})
        result = Facet::Document::CreateWithChildren.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Failed to create child 'items'")
        err.message.should contain("Document validation failed")
      end
    end
  end
end

describe Facet::Document::Update do
  describe "server-owned keys guard" do
    it "rejects a patch carrying each server-owned key and leaves the document unchanged" do
      with_temp_doctype("bidupd") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
        Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

        created = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "W1"}), Facet::RBAC::AuthContext.system))
        doc_id = created.projection.id

        patches = {
          "id"         => %({"id": "hijack"}),
          "doctype"    => %({"doctype": "X"}),
          "domain"     => %({"domain": "other"}),
          "created_at" => %({"created_at": "2020-01-01T00:00:00Z"}),
          "updated_at" => %({"updated_at": "2020-01-01T00:00:00Z"}),
        }
        patches.each do |key, patch|
          result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
          err = expect_update_error(result, status: 422)
          err.message.should eq("Document validation failed")
          details = err.details.not_nil!
          details.size.should eq(1)
          details.first.field.should eq(key)
          details.first.code.should eq("reserved")
        end

        # The refused patches never reached the projection.
        proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id).as(Facet::Mutation::Client::Projection)
        proj.id.should eq(doc_id)
        proj.content["title"].as_s.should eq("W1")
        patches.each_key { |key| proj.content[key]?.should be_nil }
      end
    end

    it "rejects a doctype that declares the reserved id field" do
      with_temp_doctype("bidupdfield") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"id": {"type": "string"}, "title": {"type": "string", "required": true}}})
        result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.details.not_nil!.any? { |d| d.field == "id" && d.message.includes?("reserved") }.should be_true
      end
    end

    it "accepts a normal patch" do
      with_temp_doctype("bidupdplain") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
        Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

        created = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "W1"}), Facet::RBAC::AuthContext.system))
        doc_id = created.projection.id

        result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "W2"}), Facet::RBAC::AuthContext.system)
        expect_update_success(result)
      end
    end

    it "accepts a nested id key inside a declared field" do
      with_temp_doctype("bidupdnest") do |db, domain, doctype|
        ensure_domain(db, domain)
        defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}, "extra": {"type": "any"}}})
        Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

        created = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "W1"}), Facet::RBAC::AuthContext.system))
        doc_id = created.projection.id

        result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"extra": {"id": "inner"}}), Facet::RBAC::AuthContext.system)
        upd = expect_update_success(result)
        upd.projection.content["extra"].as_h["id"].as_s.should eq("inner")
      end
    end

    it "rejects an id patch on a core.Domain document" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "bid-#{unique_suffix(6).downcase}"
        result = Facet::Document::Create.call(db, "core", "Domain", %({"id": "#{domain}", "color": "#123456"}), Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"id": "somewhere-else", "color": "#654321"})
        upd = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        err = expect_update_error(upd, status: 422)
        err.details.not_nil!.first.field.should eq("id")
        err.details.not_nil!.first.code.should eq("reserved")
      end
    end
  end
end
