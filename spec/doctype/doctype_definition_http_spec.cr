# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the container-key type guard on the doctype authoring paths
# (B-12). A definition key of the wrong JSON type (array or scalar where
# an object is expected) must answer 422 naming the key and the got-type —
# never an uncaught cast error, which surfaced as an HTTP 500 with a
# compiler source path in the body.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def doctype_body(overrides : String) : String
  %({"doctype": "Arr", "domain": "b12dom", "schema_version": 1,
     "aggregate_root": true, "search": "{{ display_name }}", #{overrides}})
end

describe "Doctype definition wrong-type keys (B-12)" do
  it "answers 422 (not 500) on the create path for each container key" do
    with_db do |db|
      ensure_domain(db, "b12dom")

      {
        "fields"     => %("fields": [{"fieldname": "name", "type": "string"}]),
        "scopes"     => %("scopes": ["mine"]),
        "children"   => %("children": ["operations"]),
        "sidecars"   => %("sidecars": ["comments"]),
        "actions"    => %("actions": ["release"]),
        "migrations" => %("migrations": ["migrate_from_1"]),
      }.each do |key, override|
        resp = create_doctype_http(doctype_body(override))
        assert_http_status(resp, 422)
        body = JSON.parse(resp.body)
        message = body["error"].as_s
        message.should contain("'#{key}' must be an object")
        message.should contain("array")
        message.should_not contain("/usr/")
        message.should_not contain(" at line")
      end
    end
  end

  it "answers 422 (not 500) on the update path for a wrong-typed key" do
    with_db do |db|
      ensure_domain(db, "b12dom")
      valid = create_doctype_http(doctype_body(%("fields": {"name": {"type": "string"}})))
      assert_http_status(valid, 201)
      doc_id = JSON.parse(valid.body)["meta"]["id"].as_s

      request = HTTP::Request.new(
        "PUT", "/Api/core/DocType/#{doc_id}",
        body: doctype_body(%("fields": [{"fieldname": "name", "type": "string"}])),
      )
      resp = call_api(request)
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("'fields' must be an object")
      message.should contain("array")
      message.should_not contain("/usr/")
      message.should_not contain(" at line")
    end
  end
end
