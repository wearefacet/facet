# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/http_helper"
require "../support/http_helpers"
require "json"
require "../../src/http/server"

# QA finding NS-05 — Kemal's `InitHandler` stamps `text/html` on every
# response unless a handler sets `Content-Type` first. The document
# writers therefore set `application/json` on every branch that prints a
# JSON body; the 204 delete path stays header-free.
HTTPTest.init

JSON_CT_DOMAIN  = "jsonct"
JSON_CT_DOCTYPE = "Note"

private def json_ct_create_doctype(db) : Nil
  ensure_domain(db, JSON_CT_DOMAIN)
  Facet::Doctype::DefinitionStore.cache.clear
  defn = %({
    "doctype": "#{JSON_CT_DOCTYPE}",
    "domain": "#{JSON_CT_DOMAIN}",
    "schema_version": 1,
    "search": "{{ title }}",
    "fields": {"title": {"type": "string", "required": true}}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

private def json_ct?(resp : HTTP::Client::Response) : Bool
  resp.headers["Content-Type"]?.try(&.starts_with?("application/json")) == true
end

describe "JSON content type on successful document responses (NS-05)" do
  before_each do
    with_db { |db| json_ct_create_doctype(db) }
  end

  it "sets application/json on create, read, list, and update" do
    created = call_api(HTTP::Request.new(
      "POST", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"title": "First"}),
    ))
    assert_http_status(created, 201)
    json_ct?(created).should be_true
    id = JSON.parse(created.body)["meta"]["id"].as_s

    read = call_api(HTTP::Request.new("GET", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}/#{id}",
      headers: HTTP::Headers{"Content-Type" => "application/json"}))
    assert_http_status(read, 200)
    json_ct?(read).should be_true

    list = call_api(HTTP::Request.new("GET", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}?items=1",
      headers: HTTP::Headers{"Content-Type" => "application/json"}))
    assert_http_status(list, 200)
    json_ct?(list).should be_true

    patched = call_api(HTTP::Request.new(
      "PATCH", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}/#{id}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"title": "Second"}),
    ))
    assert_http_status(patched, 200)
    json_ct?(patched).should be_true
  end

  it "leaves the 204 delete response without a JSON claim" do
    created = call_api(HTTP::Request.new(
      "POST", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"title": "Gone"}),
    ))
    id = JSON.parse(created.body)["meta"]["id"].as_s

    deleted = call_api(HTTP::Request.new("DELETE", "/Api/#{JSON_CT_DOMAIN}/#{JSON_CT_DOCTYPE}/#{id}"))
    assert_http_status(deleted, 204)
    deleted.body.empty?.should be_true
    json_ct?(deleted).should be_false
  end
end
