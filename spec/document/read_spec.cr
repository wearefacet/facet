# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

describe Facet::Document::Read do
  it "reads an existing document" do
    with_temp_doctype("readtest") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Readable"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Read.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Read::Result)
      read = result.as(Facet::Document::Read::Result)
      read.projection.content["title"].as_s.should eq("Readable")
      read.migrated.should be_false
    end
  end

  it "returns 404 for a non-existent document" do
    with_temp_doctype("readnf") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      result = Facet::Document::Read.call(db, domain, doctype, "nonexistent", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("not found")
    end
  end

  it "returns 410 for a deleted document" do
    with_temp_doctype("readdel") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "DeleteMe"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)

      result = Facet::Document::Read.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(410)
      err.message.should contain("was deleted")
    end
  end

  it "returns 404 for an unknown doctype" do
    with_db do |db|
      result = Facet::Document::Read.call(db, "nonexistent", "Unknown", "some-id", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("Unknown doctype")
    end
  end

  it "applies lazy schema migration when schema_version is behind" do
    with_temp_doctype("readmig") do |db, domain, doctype|
      ensure_domain(db, domain)

      # Create v1 doctype
      script_v1 = <<-LUA
        local export = {}
        function export.create(ctx) end
        return export
      LUA
      defn_v1 = %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string"}}, "script": #{script_v1.to_json}})
      result = Facet::Document::Create.call(db, "core", "DocType", defn_v1, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      # Create a document at v1
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Old"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # Update doctype to v2 with a migration script
      script_v2 = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.migrate_from_1(ctx)
          ctx.root.migrated = true
        end
        return export
      LUA
      defn_v2 = %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 2, "fields": {"title": {"type": "string"}, "migrated": {"type": "boolean"}}, "migrations": {"1": "migrate_from_1"}, "script": #{script_v2.to_json}})
      update_result = Facet::Doctype::Update.call(db, "#{domain}.#{doctype}", defn_v2)
      update_result.should be_a(Facet::Doctype::Update::Result)

      # Read should trigger lazy migration
      result = Facet::Document::Read.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Read::Result)
      read = result.as(Facet::Document::Read::Result)
      read.migrated.should be_true
      read.projection.content["migrated"].as_bool.should be_true
    end
  end

  it "returns migrated=false when schema_version is current" do
    with_temp_doctype("readcur") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Current"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Read.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Read::Result)
      read = result.as(Facet::Document::Read::Result)
      read.migrated.should be_false
    end
  end
end
