# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# A-02: the machine-readable API surface (`GET /Api/openapi.json`).
#
# Three layers are pinned here:
# 1. The served route — gated like the other control-plane GETs
#    (AuthHandler chain + `require_account`; a credential-less request
#    answers 401), body built at boot and byte-stable.
# 2. Structural OpenAPI 3.0 validation — the required top-level fields,
#    one `responses` object per operation, and resolvable `$ref` targets.
#    No offline OpenAPI validator ships in the dependency tree, so the
#    structural check is the contract (stated in doc/backend/openapi.md).
# 3. Route-table sync — the declared document/audit/IAM/secrets/
#    import-export/platform paths must match the live Kemal route table
#    exactly (no missing, no extra), and the committed
#    `doc/api/openapi.json` must match the generator output byte for byte.
# Collects every `$ref` value in a JSON document.
private def collect_refs(node : JSON::Any, acc : Array(String)) : Nil
  if hash = node.as_h?
    hash.each do |key, value|
      acc << value.as_s if key == "$ref"
      collect_refs(value, acc)
    end
  elsif array = node.as_a?
    array.each { |value| collect_refs(value, acc) }
  end
end

# Resolves one `#/...` JSON pointer against the spec, raising on a miss.
private def resolve_ref(spec : JSON::Any, ref : String) : Nil
  ref.should start_with("#/")
  target = spec
  ref[2..].split('/').each do |part|
    decoded = part.gsub("~1", "/").gsub("~0", "~")
    target = target[decoded]
  end
end

describe Facet::HTTP::OpenAPI do
  it "serves the spec at GET /Api/openapi.json with application/json" do
    with_db do |db|
      email = "openapi-ct-#{unique_suffix}@example.com"
      create_test_account(db, email: email)
      headers = bearer_headers(login_token(email, "test-password"))
      resp = call_api(HTTP::Request.new("GET", "/Api/openapi.json", headers: headers))
      assert_http_status(resp, 200)
      resp.headers["Content-Type"].should match(/application\/json/)
      resp.body.should eq(Facet::HTTP::OpenAPI.spec_json)
    end
  end

  it "serves a byte-identical body on repeat requests (built at boot, not per request)" do
    with_db do |db|
      email = "openapi-rep-#{unique_suffix}@example.com"
      create_test_account(db, email: email)
      headers = bearer_headers(login_token(email, "test-password"))
      first = call_api(HTTP::Request.new("GET", "/Api/openapi.json", headers: headers))
      second = call_api(HTTP::Request.new("GET", "/Api/openapi.json", headers: headers))
      assert_http_status(first, 200)
      assert_http_status(second, 200)
      first.body.should eq(second.body)
    end
  end

  it "answers 401 for a credential-less request (not anonymous, like control-plane GETs)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/openapi.json"))
    assert_http_status(resp, 401)
  end

  it "serves the spec to an authenticated caller" do
    with_db do |db|
      email = "openapi-#{unique_suffix}@example.com"
      create_test_account(db, email: email)
      token = login_token(email, "test-password")
      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/openapi.json", headers: headers))
      assert_http_status(resp, 200)
      resp.body.should eq(Facet::HTTP::OpenAPI.spec_json)
    end
  end

  it "is structurally valid OpenAPI 3.0.3" do
    spec = JSON.parse(Facet::HTTP::OpenAPI.spec_json)

    spec["openapi"].as_s.should start_with("3.0.")
    spec["info"]["title"].as_s.should_not be_empty
    spec["info"]["version"].as_s.should_not be_empty
    spec["paths"].as_h.size.should be > 0

    ops = [] of JSON::Any
    spec["paths"].as_h.each_value do |path_item|
      path_item.as_h.each do |key, value|
        next unless key == "get" || key == "post" || key == "put" ||
                    key == "patch" || key == "delete" || key == "options" ||
                    key == "head" || key == "trace" || key == "x-query"
        ops << value
      end
    end

    ops.size.should be > 0
    ops.each do |op|
      responses = op["responses"].as_h
      responses.size.should be > 0
      responses.each_value do |response|
        response["description"].as_s.should_not be_empty
      end
    end

    # Every `$ref` must resolve inside the document (v1 has none; the walk
    # stays for when shared schemas arrive).
    refs = [] of String
    collect_refs(spec, refs)
    refs.each { |ref| resolve_ref(spec, ref) }
  end

  it "matches the live Kemal route table (no missing, no extra v1 routes)" do
    issues = Facet::HTTP::OpenAPI.drift_check
    issues.should be_empty
  end

  it "declares every in-scope registered route exactly once" do
    # Pair-count parity: every declared operation resolves in the table, and
    # every in-scope table operation is declared. `drift_check` alone would
    # miss a declaration that is also registered twice under one template.
    declared = Facet::HTTP::OpenAPI.declared_routes
    declared.size.should eq(declared.uniq.size)

    table = Facet::HTTP::OpenAPI.registered_routes
    in_scope_table = table.select { |(_, path)| Facet::HTTP::OpenAPI.in_scope?(path) }
    in_scope_table.to_set.should eq(declared.to_set)
  end

  it "declares the secrets, import/export, and platform paths" do
    spec = JSON.parse(Facet::HTTP::OpenAPI.spec_json)
    paths = spec["paths"].as_h

    {"/Api/secrets/stage"                                      => ["post"],
     "/Api/{domain}/{doctype}/export"                          => ["post"],
     "/Api/{domain}/{doctype}/export_view"                     => ["post"],
     "/Api/{domain}/{doctype}/import"                          => ["post"],
     "/Api/{domain}/{doctype}/import_export/{job_id}"          => ["get"],
     "/Api/{domain}/{doctype}/import_export/{job_id}/download" => ["get"],
     "/Api/Indexes"                                            => ["get", "x-query"],
     "/Api/Artifacts"                                          => ["get", "x-query"],
     "/Api/Artifacts/{id}"                                     => ["delete"],
     "/Api/Artifacts/{id}/grants"                              => ["get"],
     "/Api/Artifacts/{id}/references"                          => ["get"],
     "/Api/SystemSettings"                                     => ["get"],
    }.each do |path, methods|
      paths.has_key?(path).should be_true
      item = paths[path].as_h
      methods.each { |method| item.has_key?(method).should be_true }
    end
  end

  it "keeps MCP, OAuth, and the assistant out of the drift scope" do
    {"/Api/_mcp/tools"                                      => false,
     "/OAuth/token"                                         => false,
     "/Api/assistant/chat"                                  => false,
     "/Api/secrets/stage"                                   => true,
     "/Api/Artifacts/:id"                                   => true,
     "/Api/Indexes"                                         => true,
     "/Api/SystemSettings"                                  => true,
     "/Api/:domain/:doctype/export"                         => true,
     "/Api/:domain/:doctype/import_export/:job_id/download" => true,
    }.each do |path, expected|
      Facet::HTTP::OpenAPI.in_scope?(path).should eq(expected)
    end
  end

  it "reports missing declared routes and undeclared in-scope table routes" do
    # Synthetic tables: the checker must catch both directions.
    declared = [{"GET", "/Api/:domain/:doctype"}, {"POST", "/Api/:domain/:doctype"}]
    table = declared + [{"PATCH", "/Api/:domain/:doctype"}]

    issues = Facet::HTTP::OpenAPI.check_pairs(declared, table)
    issues.should contain("registered but not declared (in scope): PATCH /Api/:domain/:doctype")

    table = declared.reject { |pair| pair[0] == "POST" }
    issues = Facet::HTTP::OpenAPI.check_pairs(declared, table)
    issues.should contain("declared but not registered: POST /Api/:domain/:doctype")

    # The catch-all nested-children route is out of scope — never flagged.
    issues = Facet::HTTP::OpenAPI.check_pairs(declared, [
      {"GET", "/Api/:domain/:doctype"},
      {"POST", "/Api/:domain/:doctype"},
      {"GET", "/Api/:domain/:doctype/:id/*rest"},
    ])
    issues.should be_empty

    # A new route in one of the widened families is flagged — secrets,
    # import/export, and the platform surfaces are in scope now.
    [
      {"POST", "/Api/secrets/stage"},
      {"GET", "/Api/:domain/:doctype/import_export/:job_id"},
      {"POST", "/Api/Indexes"},
      {"GET", "/Api/Artifacts/:id/grants"},
      {"POST", "/Api/SystemSettings"},
    ].each do |pair|
      issues = Facet::HTTP::OpenAPI.check_pairs(declared, declared + [pair])
      issues.should contain("registered but not declared (in scope): #{pair[0]} #{pair[1]}")
    end

    # MCP, OAuth, and the assistant stay outside the scope.
    issues = Facet::HTTP::OpenAPI.check_pairs(declared, declared + [
      {"POST", "/Api/_mcp/tools"},
      {"POST", "/OAuth/token"},
      {"GET", "/Api/assistant/chat"},
    ])
    issues.should be_empty
  end

  it "keeps the committed doc/api/openapi.json in sync with the generator output" do
    committed = File.read(File.join(__DIR__, "..", "..", "doc", "api", "openapi.json"))
    committed.should eq(Facet::HTTP::OpenAPI.spec_json)
  end
end
