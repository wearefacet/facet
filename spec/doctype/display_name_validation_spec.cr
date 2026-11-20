# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-204 — a wrong-typed `display_name` in a doctype definition must fail
# loudly with `422`, like the sibling `search` key. Before the gate,
# create silently dropped the value and update nullified the stored
# template.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def dnm_doctype_body(display_name_json : String) : String
  %({"doctype": "DnmType", "domain": "dnmdom", "schema_version": 1,
     "aggregate_root": true,
     "display_name": #{display_name_json},
     "fields": {"name": {"type": "string"}}})
end

# Re-seeds the core doctypes after the per-example truncation — the
# document read route fetches the `core.DocType` definition, which the
# create route does not need.
private def dnm_seed_core(db) : Nil
  restore_seeded_baseline(db)
  ensure_domain(db, "dnmdom")
end

describe "Doctype display_name type gate (B-204)" do
  it "answers 422 on create when display_name is an object" do
    with_db { |db| dnm_seed_core(db) }

    resp = create_doctype_http(dnm_doctype_body(%({"template": "{{ name }}"})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("display_name must be a string (a Jinja2 template")
  end

  it "answers 422 on create when display_name is a number" do
    with_db { |db| dnm_seed_core(db) }

    resp = create_doctype_http(dnm_doctype_body("42"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("display_name must be a string (a Jinja2 template")
  end

  it "answers 422 on update and keeps the stored template" do
    with_db { |db| dnm_seed_core(db) }

    valid = create_doctype_http(dnm_doctype_body(%("{{ name }}")))
    assert_http_status(valid, 201)
    doc_id = JSON.parse(valid.body)["meta"]["id"].as_s

    resp = call_api(HTTP::Request.new("PUT", "/Api/core/DocType/#{doc_id}", body: dnm_doctype_body(%({"tpl": "x"}))))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("display_name must be a string (a Jinja2 template")

    after = get_document_http("core", "DocType", doc_id)
    assert_http_status(after, 200)
    JSON.parse(after.body)["data"]["display_name"].as_s.should eq("{{ name }}")
  end
end
