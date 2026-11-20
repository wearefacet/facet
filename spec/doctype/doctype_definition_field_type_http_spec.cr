# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the field-type lookup hardening on the HTTP authoring paths
# (B-37). An unknown field type escaped as a 500 `ArgumentError`, and its
# malformed neighbours — a non-string `type` value, a junk dictionary
# `values` descriptor, a junk `operators` list — were silently accepted
# with a 201, producing a doctype whose field no document could satisfy.
# Every shape now answers 422 naming the offender, like the sibling
# `filters: ["bogus"]` check (B-25).

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def doctype_body(overrides : String) : String
  %({"doctype": "Bogus", "domain": "b37dom", "schema_version": 1,
     "aggregate_root": true, "search": "{{ display_name }}", #{overrides}})
end

# Bodies for the action-arg cases (B-58). A dedicated doctype name keeps
# the nothing-stored assertion independent of the "Bogus" rows the field
# cases above persist.
private def arg_doctype_body(name : String, arg_type : String) : String
  %({"doctype": "#{name}", "domain": "b37dom", "schema_version": 1,
     "aggregate_root": true, "search": "{{ count }}",
     "fields": {"count": {"type": "integer"}},
     "actions": {"release": {"args": {"amount": {"type": "#{arg_type}"}}}},
     "script": "local export = {}\\nfunction export.release(ctx, args) end\\nreturn export"})
end

describe "Doctype definition field-type validation (B-37)" do
  it "answers 422 — not a 500 — when a field declares an unknown type" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"count": {"type": "int"}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("Unknown field type")
      message.should contain("\"int\"")
      message.should contain("field 'count'")
    end
  end

  it "answers 422 when a nested items descriptor declares an unknown type" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"tags": {"type": "array", "items": {"type": "int"}}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("Unknown field type")
      message.should contain("field 'tags.items'")
    end
  end

  it "answers 422 when a field declares a non-string type value" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"count": {"type": 123}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("'type' must be a string type name")
      message.should contain("field 'count'")
    end
  end

  it "answers 422 when a dictionary values descriptor carries a junk type" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"counts": {"type": "dictionary", "values": {"type": 123}}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("'type' must be a string type name")
      message.should contain("field 'counts.values'")
    end
  end

  it "answers 422 when a field carries a junk operators list" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"count": {"type": "integer", "filters": ["equality"], "operators": ["bogus"]}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("unknown operator")
      message.should contain("\"bogus\"")
      message.should contain("field 'count'.operators")
    end
  end

  it "answers 422 on the update path when a field declares an unknown type" do
    with_db do |db|
      ensure_domain(db, "b37dom")
      valid = create_doctype_http(
        doctype_body(%("fields": {"count": {"type": "integer"}}))
      )
      assert_http_status(valid, 201)
      doc_id = JSON.parse(valid.body)["meta"]["id"].as_s

      request = HTTP::Request.new(
        "PUT", "/Api/core/DocType/#{doc_id}",
        body: doctype_body(%("fields": {"count": {"type": "int"}})),
      )
      resp = call_api(request)
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("Unknown field type")
      message.should contain("field 'count'")
    end
  end

  it "answers 422 — not a 500 — when an action argument declares an unknown type (B-58)" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(arg_doctype_body("BogusArg", "number"))
      assert_http_status(resp, 422)
      message = JSON.parse(resp.body)["error"].as_s
      message.should contain("Invalid doctype definition")
      message.should contain("Unknown field type")
      message.should contain("\"number\"")
      message.should contain("action 'release'.args.amount")

      # The rejection happens at parse time, before any mutation runs —
      # the doctype must not be stored.
      stored = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND content->>'doctype' = 'BogusArg'",
        as: Int64
      )
      stored.should eq(0)
    end
  end

  it "answers 422 on the update path when an action argument declares an unknown type (B-58)" do
    with_db do |db|
      ensure_domain(db, "b37dom")
      valid = create_doctype_http(arg_doctype_body("BogusArgUpd", "integer"))
      assert_http_status(valid, 201)
      doc_id = JSON.parse(valid.body)["meta"]["id"].as_s

      request = HTTP::Request.new(
        "PUT", "/Api/core/DocType/#{doc_id}",
        body: arg_doctype_body("BogusArgUpd", "number"),
      )
      resp = call_api(request)
      assert_http_status(resp, 422)
      message = JSON.parse(resp.body)["error"].as_s
      message.should contain("Unknown field type")
      message.should contain("action 'release'.args.amount")
    end
  end

  it "accepts a well-formed field definition and persists its type (happy path)" do
    with_db do |db|
      ensure_domain(db, "b37dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"count": {"type": "integer", "filters": ["equality", "comparison"]}}))
      )
      assert_http_status(resp, 201)
      doc_id = JSON.parse(resp.body)["meta"]["id"].as_s

      # The persisted content must carry the declared type and the derived
      # operators member, so round-tripped re-parse keeps the field usable.
      doc = db.query_one(
        "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1",
        doc_id, as: JSON::Any
      )
      field = doc["fields"]["count"]
      field["type"].as_s.should eq("integer")
      operators = field["operators"].as_a.map(&.as_s)
      operators.should contain("eq")
      operators.should contain("gte")
    end
  end
end
