# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../support/http_helper"
require "../support/iam_helper"
require "../../src/http/server"
require "json"

# The assistant probe. Two layers are covered:
#
# - `Facet::SystemSettings::AssistantTest` directly — the resolution (saved
#   endpoint, key, model), the `422` for the unconfigured posture (no API
#   key resolves), and the `502` mapping for a provider or transport
#   failure. The `probe` seam replaces the HTTP dial, so no provider is
#   involved.
# - The HTTP route — the write gate, the CSRF check, and the JSON shapes.
#   The 200 example points the saved endpoint at a locally bound mock
#   provider, the same pattern the assistant hot-change spec uses.
#
# The suite's file tier leaves `assistant.api_key` unset (config.test.yml),
# so the unconfigured examples run against the real default posture; the
# configured examples pin the key the way a settings save does (one stage
# handle adopted into the sealed slot).

HTTPTest.init

# One-request mock provider: records the Authorization header and the
# requested model, answers one canned JSON body.
private class ProbeMockLLM
  getter port : Int32
  getter auth_header : String?
  getter model : String?
  getter path : String?
  @server : HTTP::Server

  def initialize(@status : Int32, @body : String)
    @server = HTTP::Server.new do |ctx|
      @auth_header = ctx.request.headers["Authorization"]?
      @path = ctx.request.path
      body = begin
        ctx.request.body.try(&.gets_to_end) || "{}"
      rescue
        "{}"
      end
      @model = JSON.parse(body)["model"]?.try(&.as_s?)
      ctx.response.status_code = @status
      ctx.response.content_type = "application/json"
      ctx.response.print(@body)
    end
    @port = @server.bind_tcp(0).port
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

private def role_context(db, role_id : String, account_id : String = "acct_" + Facet::Util::ScriptHelpers.ulid[0..10]) : Facet::RBAC::AuthContext
  content = Facet::IAM::RoleStore.fetch(db, role_id)
  raise "seeded role #{role_id} missing" if content.nil?
  role = Facet::RBAC::ActiveRole.from_projection_content(content.as(JSON::Any))
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def pin_assistant(db, patch : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch, Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

# Stages and adopts an API key the way the settings page does: one stage
# handle in the patch, adopted into the sealed slot by the write pipeline.
private def pin_assistant_key(db, key : String) : Nil
  handle = "sh_" + Facet::Util::ScriptHelpers.ulid
  payload = Facet::Secrets::Codec.seal(key, Facet::Secrets::Staging.doc_ref(handle), "assistant.api_key")
  Facet::Secrets::Staging.insert(db, "sealed", payload, "core", "SystemSettings", "assistant.api_key", "system", handle: handle)
  pin_assistant(db, %({"assistant": {"api_key": "#{handle}"}}))
end

private def assistant_test_request : HTTP::Request
  HTTP::Request.new(
    "POST", "/Api/SystemSettings/assistant/test",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
  )
end

describe Facet::SystemSettings::AssistantTest do
  before_each do
    Facet::SystemSettings.reset_cache!
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "dials the saved endpoint, key, and model and reports the reply" do
    with_db do |db|
      pin_assistant_key(db, "sk-spec-key")
      pin_assistant(db, %({"assistant": {"api_endpoint": "https://provider.example/v1", "model": "probe-model"}}))

      requests = [] of {String, String?, String}
      probe = ->(endpoint : String, key : String?, model : String) {
        requests << {endpoint, key, model}
        {200, %({"choices":[{"message":{"content":"pong"}}]})}
      }

      result = Facet::SystemSettings::AssistantTest.call(db, probe)

      result = result.as(Facet::SystemSettings::AssistantTest::Result)
      result.model.should eq("probe-model")
      result.endpoint.should eq("https://provider.example/v1")
      result.reply.should eq("pong")

      requests.size.should eq(1)
      requests.first[0].should eq("https://provider.example/v1")
      requests.first[1].should eq("sk-spec-key")
      requests.first[2].should eq("probe-model")
    end
  end

  it "answers 422 with the api_key field when no key resolves" do
    with_db do |db|
      # config.test.yml leaves assistant.api_key unset and nothing is pinned.
      result = Facet::SystemSettings::AssistantTest.call(db, ->(_e : String, _k : String?, _m : String) { {200, "{}"} })

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.details.not_nil!.any? { |d| d.field == "assistant.api_key" }.should be_true
    end
  end

  it "answers 502 carrying the provider message when the status is an error" do
    with_db do |db|
      pin_assistant_key(db, "sk-spec-key")

      probe = ->(_e : String, _k : String?, _m : String) {
        {401, %({"error": {"message": "invalid_api_key"}})}
      }

      result = Facet::SystemSettings::AssistantTest.call(db, probe)

      error = result.as(Facet::ServiceError)
      error.status.should eq(502)
      error.message.should contain("HTTP 401")
      error.message.should contain("invalid_api_key")
    end
  end

  it "answers 502 carrying the transport message when the dial raises" do
    with_db do |db|
      pin_assistant_key(db, "sk-spec-key")

      probe = ->(_e : String, _k : String?, _m : String) {
        raise "connection refused"
      }

      result = Facet::SystemSettings::AssistantTest.call(db, probe)

      error = result.as(Facet::ServiceError)
      error.status.should eq(502)
      error.message.should contain("connection refused")
    end
  end

  it "keeps the reply nil when the body shape carries no content" do
    with_db do |db|
      pin_assistant_key(db, "sk-spec-key")

      probe = ->(_e : String, _k : String?, _m : String) {
        {200, %({"choices":[]})}
      }

      result = Facet::SystemSettings::AssistantTest.call(db, probe)

      result = result.as(Facet::SystemSettings::AssistantTest::Result)
      result.reply.should be_nil
    end
  end

  it "builds the chat-completions path from the endpoint" do
    server = ProbeMockLLM.new(200, %({"choices":[{"message":{"content":"pong"}}]}))
    begin
      with_db do |db|
        pin_assistant_key(db, "sk-spec-key")
        pin_assistant(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1"}}))

        result = Facet::SystemSettings::AssistantTest.call(db)

        result.as(Facet::SystemSettings::AssistantTest::Result).reply.should eq("pong")
        server.path.should eq("/v1/chat/completions")
        server.auth_header.should eq("Bearer sk-spec-key")
        server.model.should eq("gpt-4o")
      end
    ensure
      server.close
    end
  end
end

describe "POST /Api/SystemSettings/assistant/test" do
  before_each do
    Facet::SystemSettings.reset_cache!
    with_db do |db|
      %w[core.DocType core.Domain core.SystemSettings].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
      seed_test_roles(db)
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "answers 403 for editor and viewer (the settings write gate)" do
    with_db do |db|
      assert_http_status(call_api_as(assistant_test_request, role_context(db, "iam.Roles.editor")), 403)
      assert_http_status(call_api_as(assistant_test_request, role_context(db, "iam.Roles.viewer")), 403)
    end
  end

  it "answers 422 when no API key resolves (the unconfigured posture)" do
    with_db do |db|
      admin = role_context(db, "iam.Roles.admin")

      response = call_api_as(assistant_test_request, admin)

      assert_http_status(response, 422)
      details = JSON.parse(response.body)["details"].as_a
      details.any? { |d| d["field"].as_s == "assistant.api_key" }.should be_true
    end
  end

  it "answers 200 with the model and reply when the provider is healthy" do
    server = ProbeMockLLM.new(200, %({"choices":[{"message":{"content":"pong"}}]}))
    begin
      with_db do |db|
        pin_assistant_key(db, "sk-spec-key")
        pin_assistant(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1"}}))
        admin = role_context(db, "iam.Roles.admin")

        response = call_api_as(assistant_test_request, admin)

        assert_http_status(response, 200)
        body = JSON.parse(response.body)
        body["model"].as_s.should eq("gpt-4o")
        body["endpoint"].as_s.should eq("http://localhost:#{server.port}/v1")
        body["reply"].as_s.should eq("pong")
      end
    ensure
      server.close
    end
  end

  it "answers 403 without the CSRF header" do
    with_db do |db|
      admin = role_context(db, "iam.Roles.admin")

      assert_http_status(call_api_raw_as(assistant_test_request, admin), 403)
    end
  end
end
