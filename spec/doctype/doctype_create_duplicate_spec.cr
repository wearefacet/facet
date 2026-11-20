# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the duplicate-registration guard on the doctype create path
# (B-07). A repeated POST /Api/core/DocType for the same (domain, doctype)
# must answer 409 without appending a second `create` mutation; the first
# registration keeps its 201.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def doctype_body(domain : String, doctype : String) : String
  %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1,
     "aggregate_root": true, "search": "{{ name }}",
     "fields": {"name": {"type": "string", "required": true}}})
end

private def count_create_mutations(db, doc_id : String) : Int64
  db.query_one(
    "SELECT COUNT(*) FROM mutations WHERE domain = 'core' AND doc_type = 'DocType' AND doc_id = $1 AND action = 'create'",
    doc_id,
    as: Int64,
  )
end

describe "Doctype::Create duplicate registration" do
  it "returns 201 on the first registration" do
    with_db do |db|
      ensure_domain(db, "dupdom")
      resp = create_doctype_http(doctype_body("dupdom", "Alpha#{unique_suffix}"))
      assert_http_status(resp, 201)
    end
  end

  it "rejects a repeated registration with 409 and names the existing pair" do
    doctype = "Widget#{unique_suffix}"
    doc_id = "dupdom.#{doctype}"

    with_db do |db|
      ensure_domain(db, "dupdom")
      resp = create_doctype_http(doctype_body("dupdom", doctype))
      assert_http_status(resp, 201)
    end

    with_db do |_db|
      resp = create_doctype_http(doctype_body("dupdom", doctype))
      assert_http_status(resp, 409)
      body = JSON.parse(resp.body)
      body["error"].as_s.should eq("Doctype '#{doc_id}' already exists")
    end
  end

  it "leaves a single create mutation in the audit trail" do
    doctype = "Widget#{unique_suffix}"
    doc_id = "dupdom.#{doctype}"

    with_db do |db|
      ensure_domain(db, "dupdom")
      create_doctype_http(doctype_body("dupdom", doctype))
      count_create_mutations(db, doc_id).should eq(1)
    end

    with_db do |db|
      resp = create_doctype_http(doctype_body("dupdom", doctype))
      assert_http_status(resp, 409)
      count_create_mutations(db, doc_id).should eq(1)
    end
  end

  it "returns the 409 ServiceError from the service call as well" do
    doctype = "Widget#{unique_suffix}"
    doc_id = "dupdom.#{doctype}"
    body = doctype_body("dupdom", doctype)

    with_db do |db|
      ensure_domain(db, "dupdom")
      Facet::Doctype::Create.call(db, "core", "DocType", body).should be_a(Facet::Doctype::Create::Result)

      dup = Facet::Doctype::Create.call(db, "core", "DocType", body)
      dup.should be_a(Facet::ServiceError)
      err = dup.as(Facet::ServiceError)
      err.status.should eq(409)
      err.message.should eq("Doctype '#{doc_id}' already exists")

      count_create_mutations(db, doc_id).should eq(1)
    end
  end

  it "keeps a different doctype in the same domain registrable after a 409" do
    doctype = "Widget#{unique_suffix}"

    with_db do |db|
      ensure_domain(db, "dupdom")
      create_doctype_http(doctype_body("dupdom", doctype))
    end

    with_db do |_db|
      other = "Beta#{unique_suffix}"
      resp = create_doctype_http(doctype_body("dupdom", other))
      assert_http_status(resp, 201)
    end
  end
end
