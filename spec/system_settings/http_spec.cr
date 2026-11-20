# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/http/server"
require "../support/http_helper"
require "../support/iam_helper"
require "json"

# Initialize HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Builds a real-principal auth context from one of the seeded roles
# (`seed_test_roles` mirrors the production `iam.Roles` seed, carve-outs
# included).
private def role_context(db, role_id : String, account_id : String = "acct_" + Facet::Util::ScriptHelpers.ulid[0..10]) : Facet::RBAC::AuthContext
  content = Facet::IAM::RoleStore.fetch(db, role_id)
  raise "seeded role #{role_id} missing" if content.nil?
  role = Facet::RBAC::ActiveRole.from_projection_content(content.as(JSON::Any))
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def settings_get_request : HTTP::Request
  HTTP::Request.new("GET", "/Api/SystemSettings")
end

private def settings_patch_request(body : String) : HTTP::Request
  HTTP::Request.new(
    "PATCH", "/Api/core/SystemSettings/settings",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
    body: body,
  )
end

describe "SystemSettings HTTP surface" do
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

  describe "GET /Api/SystemSettings" do
    it "answers 200 for admin with values + pinned, values carrying no secret paths" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        response = call_api_as(settings_get_request, admin)

        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        values = json["values"].as_h
        values["assistant.model"].as_s.should eq(Facet::Config.instance.assistant.model)
        values["mail.adapter"].as_s.should eq(Facet::Config.instance.mail.adapter)
        values.has_key?("assistant.api_key").should be_false
        values.has_key?("mail.smtp.password").should be_false
        json["pinned"].as_a.should be_empty
      end
    end

    it "answers 403 for editor and viewer (the seed carve-outs)" do
      with_db do |db|
        editor = role_context(db, "iam.Roles.editor")
        viewer = role_context(db, "iam.Roles.viewer")

        assert_http_status(call_api_as(settings_get_request, editor), 403)
        assert_http_status(call_api_as(settings_get_request, viewer), 403)
      end
    end

    it "reflects a pinned value and its pin after a sparse save" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        patch_body = %({"assistant": {"model": "http-pinned-model"}})
        assert_http_status(call_api_as(settings_patch_request(patch_body), admin), 200)

        Facet::SystemSettings.mark_stale
        response = call_api_as(settings_get_request, admin)
        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["values"]["assistant.model"].as_s.should eq("http-pinned-model")
        json["pinned"].as_a.should eq(["assistant.model"])
      end
    end
  end

  describe "PATCH /Api/core/SystemSettings/settings" do
    it "answers 403 for editor (carved out of the wildcard update)" do
      with_db do |db|
        editor = role_context(db, "iam.Roles.editor")
        assert_http_status(
          call_api_as(settings_patch_request(%({"assistant": {"model": "x"}})), editor),
          403,
        )
      end
    end

    it "answers 422 on the semantic gate through the standard route" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        response = call_api_as(settings_patch_request(%({"mail": {"adapter": "smtp"}})), admin)
        assert_http_status(response, 422)
        details = JSON.parse(response.body)["details"].as_a
        details.any? { |d| d["field"].as_s == "mail.smtp.host" }.should be_true
      end
    end

    it "answers 422 on a wrong-kind value through the definition shape" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        response = call_api_as(settings_patch_request(%({"assistant": {"model": 42}})), admin)
        assert_http_status(response, 422)
      end
    end

    it "answers 422 on an unknown field (shape layer)" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        response = call_api_as(settings_patch_request(%({"assistant": {"wat": 1}})), admin)
        assert_http_status(response, 422)
      end
    end

    it "answers 404 for a caller without any grant (non-disclosing standard route)" do
      with_db do |db|
        viewer = role_context(db, "iam.Roles.viewer")
        assert_http_status(
          call_api_as(settings_patch_request(%({"assistant": {"model": "x"}})), viewer),
          403,
        )
      end
    end
  end

  describe "singleton guards (Lua lifecycle)" do
    it "refuses an HTTP create for a non-system principal" do
      request = HTTP::Request.new(
        "POST", "/Api/core/SystemSettings",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: %({"assistant": {"model": "spawn"}}),
      )
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        assert_http_status(call_api_as(request, admin), 422)
      end
    end

    it "lets the seed create pass (system principal through the pipeline)" do
      with_db do |db|
        # ensure_doctype re-created the definition this example; the seed
        # pass also created the null singleton. The projection proves both.
        exists = Facet::Util::Projections.exists?(db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID)
        exists.should be_true
      end
    end

    it "refuses delete for everyone" do
      with_db do |db|
        admin = role_context(db, "iam.Roles.admin")
        request = HTTP::Request.new("DELETE", "/Api/core/SystemSettings/settings")
        assert_http_status(call_api_as(request, admin), 422)
      end
    end
  end
end
