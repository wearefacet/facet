# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/http/server"
require "../../src/mcp"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# The MCP surface's skill loader (`read_skill`) end to end through the
# JSON-RPC routes:
# - `tools/list` appends the loader after the shared catalogue, its
#   description enumerating the surface's corpus (discovery without an
#   extra tool call).
# - `tools/call` answers with the `{skill, title, body}` envelope.
# - An unknown or surface-untagged name answers `not_found` whose data
#   names the surface's available skills (discovery on error).
# - The surface filter is hard end to end: the chat-only etiquette skill
#   and the domain-builder corpus resolve to `not_found`, never to a body.
private def sign_skills_token(account_id : String, role : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: Random::Secure.hex(16),
    role: role,
    aud: Facet::MCP.resource_identifier(role),
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

private def skills_mcp_request(role_slug : String, token : String, method : String, params : JSON::Any? = nil, id = 1) : HTTP::Client::Response
  body = JSON::Any.new({
    "jsonrpc" => JSON::Any.new("2.0"),
    "id"      => JSON::Any.new(id.to_i64),
    "method"  => JSON::Any.new(method),
  } of String => JSON::Any)
  if p = params
    body.as_h["params"] = p
  end
  headers = bearer_headers(token)
  headers["Content-Type"] = "application/json"
  call_api(HTTP::Request.new("POST", "#{Facet::MCP::PATH_PREFIX}/#{role_slug}", headers: headers, body: body.to_json))
end

private def skills_call_params(name : String, arguments_json : String) : JSON::Any
  JSON::Any.new({
    "name"      => JSON::Any.new(name),
    "arguments" => JSON.parse(arguments_json),
  } of String => JSON::Any)
end

describe "MCP read_skill" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "appends the skill loader to tools/list with the corpus in the description" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/list")
      resp.status_code.should eq(200)
      tools = JSON.parse(resp.body)["result"]["tools"].as_a
      loader = tools.find { |t| t.as_h["name"].as_s == "read_skill" }
      loader.should_not be_nil

      description = loader.not_nil!.as_h["description"].as_s
      description.should contain("filter-grammar")
      description.should contain("documents-workflow")
      # The chat-only skill is not part of this surface's corpus.
      description.should_not contain("chat-etiquette")
      # The names lead the description, so a client that truncates long
      # descriptions still forwards the valid values.
      description.should start_with("Read a Facet skill by name. Valid names:")

      schema = loader.not_nil!.as_h["inputSchema"].as_h
      schema["required"].as_a.map(&.as_s).should eq(["name"])
      # The `name` property enumerates the surface corpus — a
      # machine-readable list that survives description truncation.
      name_prop = schema["properties"].as_h["name"].as_h
      name_enum = name_prop["enum"].as_a.map(&.as_s)
      name_enum.should contain("filter-grammar")
      name_enum.should contain("aggregate-reference")
      name_enum.should contain("artifacts")
      name_enum.should_not contain("chat-etiquette")
      name_enum.should eq(name_enum.sort)
    end
  end

  it "returns the skill envelope for a surface skill" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/call",
        params: skills_call_params("read_skill", %({"name": "filter-grammar"})))
      resp.status_code.should eq(200)
      result = JSON.parse(resp.body)["result"]
      result["isError"].as_bool.should be_false

      content = result["structuredContent"]
      content["skill"].as_s.should eq("filter-grammar")
      content["title"].as_s.should eq("Filter Grammar")
      content["body"].as_s.should contain("# Filter Grammar")

      # The text block carries the same envelope serialized.
      result["content"].as_a.size.should eq(1)
      result["content"].as_a.first.as_h["type"].as_s.should eq("text")
    end
  end

  it "renders not_found for an unknown skill" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/call",
        params: skills_call_params("read_skill", %({"name": "nope"})))
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["error"]["code"].as_i.should eq(-32602)
      body["error"]["message"].as_s.should contain("nope")
      body["error"]["data"]["reason"].as_s.should eq("not_found")
      body["error"]["data"]["skill"].as_s.should eq("nope")
      # Discovery on error: the data names this surface's available skills.
      available = body["error"]["data"]["available"].as_a.map(&.as_s)
      available.should contain("filter-grammar")
      # The list is surface-filtered: it never names a skill this surface
      # does not serve.
      available.should_not contain("chat-etiquette")
    end
  end

  it "renders invalid_params when the name argument is missing" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/call",
        params: skills_call_params("read_skill", %({})))
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["error"]["code"].as_i.should eq(-32602)
      body["error"]["data"]["reason"].as_s.should eq("invalid_params")
      body["error"]["data"]["argument"].as_s.should eq("name")
    end
  end

  it "keeps the chat-only etiquette skill unreachable from mcp" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/call",
        params: skills_call_params("read_skill", %({"name": "chat-etiquette"})))
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["error"]["code"].as_i.should eq(-32602)
      body["error"]["data"]["reason"].as_s.should eq("not_found")
    end
  end

  it "keeps the domain-builder corpus unreachable from mcp" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_skills_token(account_id, "iam.Roles.editor")

      resp = skills_mcp_request("iam.Roles.editor", token, "tools/call",
        params: skills_call_params("read_skill", %({"name": "doctype-anatomy"})))
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["error"]["code"].as_i.should eq(-32602)
      body["error"]["data"]["reason"].as_s.should eq("not_found")
    end
  end
end
