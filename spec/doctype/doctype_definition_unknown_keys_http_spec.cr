# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the unknown-key guard inside nested definition entries (B-13).
# A typo'd key inside a field definition (e.g. `reqired` instead of
# `required`) must answer 422 naming the key and the field path — the
# doctype is not created or changed. Before the guard the write answered
# 201 while silently discarding the key, so the missing constraint was
# discovered only by data that should have been rejected.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def doctype_body(overrides : String) : String
  %({"doctype": "Bogus", "domain": "b13dom", "schema_version": 1,
     "aggregate_root": true, "search": "{{ display_name }}", #{overrides}})
end

describe "Doctype definition unknown nested keys (B-13)" do
  it "answers 422 on the create path when a field carries an unknown key" do
    with_db do |db|
      ensure_domain(db, "b13dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"name": {"type": "string", "reqired": true}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("Unknown key")
      message.should contain("'reqired'")
      message.should contain("field 'name'")
      message.should contain("(did you mean 'required'?)")
    end
  end

  it "answers 422 on the update path when a field carries an unknown key" do
    with_db do |db|
      ensure_domain(db, "b13dom")
      valid = create_doctype_http(
        doctype_body(%("fields": {"name": {"type": "string"}}))
      )
      assert_http_status(valid, 201)
      doc_id = JSON.parse(valid.body)["meta"]["id"].as_s

      request = HTTP::Request.new(
        "PUT", "/Api/core/DocType/#{doc_id}",
        body: doctype_body(%("fields": {"name": {"type": "string", "reqired": true}})),
      )
      resp = call_api(request)
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("'reqired'")
      message.should contain("field 'name'")
    end
  end

  it "answers 422 — not a 500 — when a field declares an unknown filter capability (B-25)" do
    with_db do |db|
      ensure_domain(db, "b13dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"window": {"type": "period", "filters": ["contains"]}}))
      )
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      message = body["error"].as_s
      message.should contain("unknown filter capability")
      message.should contain("\"contains\"")
      message.should contain("field 'window'")
      # The message names what the declared type actually allows.
      message.should contain("allowed for type 'period'")
      message.should contain("interval")
    end
  end

  it "accepts a field whose declared capabilities match its type (B-25, happy path)" do
    with_db do |db|
      ensure_domain(db, "b13dom")

      resp = create_doctype_http(
        doctype_body(%("fields": {"window": {"type": "period", "filters": ["equality", "interval"]}}))
      )
      assert_http_status(resp, 201)
    end
  end
end
