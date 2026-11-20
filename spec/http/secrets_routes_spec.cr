# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/http_helper"
require "json"
require "pg"
require "../../src/http/server"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/secrets/store"
require "../../src/secrets/staging"
require "../../src/system_settings/service"
require "../../src/mutation/client"

# ── Fixture helpers ──────────────────────────────────────────────────────

STAGE_DOMAIN  = "stagedocs"
STAGE_DOCTYPE = "Widget"

def stage_create_doctype(db) : Nil
  ensure_domain(db, STAGE_DOMAIN)
  Facet::Doctype::DefinitionStore.cache.clear

  body = %({
    "doctype": "#{STAGE_DOCTYPE}",
    "domain": "#{STAGE_DOMAIN}",
    "schema_version": 1,
    "search": "{{ name }}",
    "fields": {
      "name": { "type": "string" },
      "pw":   { "type": "secret", "mode": "hash", "min": 8, "pattern": "^[A-Za-z0-9]+$" },
      "key":  { "type": "secret", "mode": "sealed" },
      "otp":  { "type": "secret", "mode": "token", "ttl_seconds": 3600 },
      "tagged": { "type": "secret", "mode": "hash", "tags": ["confidential"] },
      "plain": { "type": "string" }
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
  raise "stage spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
end

def stage_auth(db, account_id : String, actions : Array(String), view_tags = ["default"]) : Facet::RBAC::AuthContext
  role_id = "stage_role_#{account_id}"
  perms = actions.map { |a| permission_json(a, "#{STAGE_DOMAIN}.#{STAGE_DOCTYPE}") }
  content = JSON::Any.new({
    "name"         => JSON::Any.new(role_id),
    "permissions"  => JSON::Any.new(perms),
    "visible_tags" => JSON::Any.new(view_tags.map { |t| JSON::Any.new(t) }),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Role",
    doc_id: role_id,
    content: content.to_json,
    actioner_id: "system",
  )
  account = JSON::Any.new({
    "roles" => JSON::Any.new([JSON::Any.new(role_id)]),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: account_id,
    content: account.to_json,
    actioner_id: "system",
  )
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def stage_request(body : String) : HTTP::Request
  HTTP::Request.new("POST", "/Api/secrets/stage", body: body)
end

# Sends the request with the given principal pinned on the fiber.
def stage_call(body : String, ctx : Facet::RBAC::AuthContext) : HTTP::Client::Response
  call_api_as(stage_request(body), ctx)
end

# ── Specs ────────────────────────────────────────────────────────────────

module Facet
  describe HTTP::SecretsRoutes do
    HTTPTest.init

    before_each do
      with_db do |db|
        stage_create_doctype(db)
      end
    end

    it "stages a hash plaintext and returns a shaped handle" do
      ctx = with_db { |db| stage_auth(db, "stager-a", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "abc12345"}),
        ctx,
      )

      assert_http_status(response, 201)
      body = JSON.parse(response.body)
      handle = body["handle"].as_s
      handle.matches?(/^sh_[0-9A-HJKMNP-TV-Z]{26}$/).should be_true
      body.as_h.has_key?("token").should be_false

      with_db do |db|
        row = Facet::Secrets::Staging.load(db, handle)
        row.should_not be_nil
        row.as(Facet::Secrets::Staging::Row).mode.should eq("hash")
        row.as(Facet::Secrets::Staging::Row).created_by.should eq("stager-a")
        row.as(Facet::Secrets::Staging::Row).field_path.should eq("pw")
      end
    end

    it "stages a sealed plaintext" do
      ctx = with_db { |db| stage_auth(db, "stager-b", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "key", "value": "sk-live-123"}),
        ctx,
      )
      assert_http_status(response, 201)
      handle = JSON.parse(response.body)["handle"].as_s

      with_db do |db|
        row = Facet::Secrets::Staging.load(db, handle).as(Facet::Secrets::Staging::Row)
        row.mode.should eq("sealed")
        # Sealed under the staging binding — adoption re-seals.
        Facet::Secrets::Codec.open(
          row.value, Facet::Secrets::Staging.doc_ref(handle), "key",
        ).should eq("sk-live-123")
      end
    end

    it "generates the token itself and returns the plaintext exactly once" do
      ctx = with_db { |db| stage_auth(db, "stager-c", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "otp"}),
        ctx,
      )

      assert_http_status(response, 201)
      body = JSON.parse(response.body)
      raw_token = body["token"].as_s
      raw_token.size.should eq(16)
      raw_token.each_char.all? { |c| "23456789ABCDEFGHJKMNPQRSTVWXYZ".includes?(c) }.should be_true

      with_db do |db|
        row = Facet::Secrets::Staging.load(db, body["handle"].as_s).as(Facet::Secrets::Staging::Row)
        # The digest is stored, never the raw token.
        row.value.should_not contain(raw_token)
        row.value.should eq(Facet::Secrets::Codec.token_payload(raw_token))
      end
    end

    it "rejects a caller-supplied value in token mode" do
      ctx = with_db { |db| stage_auth(db, "stager-c", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "otp", "value": "user-chosen"}),
        ctx,
      )
      assert_http_status(response, 422)
    end

    it "applies min and pattern to the plaintext" do
      ctx = with_db { |db| stage_auth(db, "stager-d", ["create"]) }

      too_short = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "short"}),
        ctx,
      )
      assert_http_status(too_short, 422)

      bad_pattern = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "has a space"}),
        ctx,
      )
      assert_http_status(bad_pattern, 422)
    end

    it "rejects a missing plaintext for hash mode" do
      ctx = with_db { |db| stage_auth(db, "stager-e", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw"}),
        ctx,
      )
      assert_http_status(response, 422)
    end

    it "answers 404 for an unknown doctype, an unknown field, and a non-secret field" do
      ctx = with_db { |db| stage_auth(db, "stager-f", ["create"]) }

      unknown_doctype = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "Nope", "field_path": "pw", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(unknown_doctype, 404)

      unknown_field = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "missing", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(unknown_field, 404)

      non_secret = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "name", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(non_secret, 404)
    end

    it "answers 404 for tag paths the caller cannot see" do
      # The `tagged` field carries tags: ["confidential"]; the caller only
      # sees the default tag — the field is invisible to them.
      ctx = with_db { |db| stage_auth(db, "stager-g", ["create"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "tagged", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(response, 404)
    end

    it "stages a confidential field when the role can see the tag" do
      ctx = with_db { |db| stage_auth(db, "stager-h", ["create"], view_tags: ["default", "confidential"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "tagged", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(response, 201)
    end

    it "rejects a caller without create or update permission" do
      ctx = with_db { |db| stage_auth(db, "stager-i", ["read"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "whatever0"}),
        ctx,
      )
      assert_http_status(response, 403)
    end

    it "accepts a caller with update-only permission when doc_id is present" do
      doc = with_db do |db|
        Facet::Document::Create.call(
          db, STAGE_DOMAIN, STAGE_DOCTYPE, %({"name": "w1"}),
          Facet::RBAC::AuthContext.system,
        )
      end
      doc = doc.should be_a(Facet::Document::Create::Result)

      ctx = with_db { |db| stage_auth(db, "stager-j", ["update"]) }
      response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "whatever0", "doc_id": "#{doc.projection.id}"}),
        ctx,
      )
      assert_http_status(response, 201)
    end

    it "rejects the system principal and API keys" do
      system_response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "whatever0"}),
        Facet::RBAC::AuthContext.system,
      )
      assert_http_status(system_response, 403)

      api_role = with_db do |_db|
        role = Facet::RBAC::ActiveRole.new(
          role_id: "api-role",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "*", "on": "*.*"})))],
        )
        Facet::RBAC::AuthContext.api_key("key-holder", role, "01APIKEYROW0000000000000X")
      end
      api_response = stage_call(
        %({"domain": "#{STAGE_DOMAIN}", "doctype": "#{STAGE_DOCTYPE}", "field_path": "pw", "value": "whatever0"}),
        api_role,
      )
      assert_http_status(api_response, 403)
    end

    it "stages a nested secret leaf under an object field" do
      with_db { |db| ensure_settings_doc(db) }
      ctx = with_db { |db| stage_auth_on(db, "stager-settings", "update", "core.SystemSettings") }

      response = stage_call(
        %({"domain": "core", "doctype": "SystemSettings", "field_path": "mail.smtp.password", "doc_id": "settings", "value": "smtp-secret"}),
        ctx,
      )
      assert_http_status(response, 201)
      handle = JSON.parse(response.body)["handle"].as_s
      handle.matches?(/^sh_[0-9A-HJKMNP-TV-Z]{26}$/).should be_true

      # The handle PATCHes into the nested position; adoption seals it under
      # the settings slot, which is the dotted path.
      patched = with_db do |db|
        Facet::Document::Update.call(
          db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
          %({"mail": {"smtp": {"password": "#{handle}"}}}),
          Facet::RBAC::AuthContext.system,
        )
      end
      patched.should be_a(Facet::Document::Update::Result)

      with_db do |db|
        Facet::SystemSettings.reset_cache!
        Facet::SystemSettings.reveal_secret(db, "mail.smtp.password").should eq("smtp-secret")
      end
    ensure
      with_db { |db| Facet::Secrets.clear(db, Facet::SystemSettings::DOC_REF, "mail.smtp.password") }
      Facet::SystemSettings.reset_cache!
    end

    it "answers 404 for a nested non-secret leaf" do
      with_db { |db| ensure_settings_doc(db) }
      ctx = with_db { |db| stage_auth_on(db, "stager-settings-host", "update", "core.SystemSettings") }

      response = stage_call(
        %({"domain": "core", "doctype": "SystemSettings", "field_path": "mail.smtp.host", "doc_id": "settings", "value": "smtp.example.tld"}),
        ctx,
      )
      assert_http_status(response, 404)
    end
  end
end

# Like `stage_auth`, but for a doctype outside the widget fixture — the
# nested-secret examples stage against `core.SystemSettings`.
def stage_auth_on(db, account_id : String, action : String, on : String) : Facet::RBAC::AuthContext
  role_id = "stage_role_#{account_id}"
  content = JSON::Any.new({
    "name"        => JSON::Any.new(role_id),
    "permissions" => JSON::Any.new([permission_json(action, on)]),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Role",
    doc_id: role_id,
    content: content.to_json,
    actioner_id: "system",
  )
  account = JSON::Any.new({
    "roles" => JSON::Any.new([JSON::Any.new(role_id)]),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: account_id,
    content: account.to_json,
    actioner_id: "system",
  )
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end
