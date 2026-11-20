# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../support/http_helper"
require "../support/webhook_helper"
require "../../src/webhook"
require "../../src/http/server"
require "../../src/mutation/client"
require "../../src/rbac"

# B-188 — the webhook AUTHORING connectivity gate over HTTP.
#
# Webhook authoring is open to every role by permission shape (B-76
# ownership arbitration), but a role whose `iam.Roles.connectivity` list
# excludes the `webhook` channel may not create one: the create hook
# (`data/seeds/core.Webhook/script.lua`) refuses with a 422 whose message
# names the missing channel. With the channel the create answers 201.
HTTPTest.init

private def channel_gate_actor(db, account_email : String, role_name : String, connectivity : Array(String)) : Facet::RBAC::AuthContext
  # The custom role projection needs only `iam.Roles` to be registered —
  # NOT the seeded role documents (their scope aliases validate against
  # registered doctypes this file does not use). The before_each already
  # registered everything; re-clear the definition cache so the projection
  # writes below see live definitions.
  role_id = "iam.Roles.#{role_name}"
  content = {
    "name"         => role_name,
    "description"  => "Connectivity-gate role #{role_name}",
    "visible_tags" => ["default"],
    "connectivity" => connectivity,
    "permissions"  => [{"action" => "create", "on" => "*.*"}],
  }.to_json
  existing = db.query_one?("SELECT 1 FROM projections WHERE id = $1 AND deleted_at IS NULL", role_id, as: Int32)
  Facet::Mutation::Client.create(
    db, "iam", "Roles", doc_id: role_id, content: content, actioner_id: "system") unless existing

  account_id = create_test_account(db, email: account_email, roles: [role_id], default_role: role_id)
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

private def post_webhook(auth_context : Facet::RBAC::AuthContext) : HTTP::Client::Response
  body = {
    "label"          => "Relay",
    "url"            => "https://receiver.test/hook",
    "source_doctype" => "core.DocType.iam.LoginEvent",
  }.to_json
  call_api_as(HTTP::Request.new("POST", "/Api/core/Webhook",
    headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body), auth_context)
end

module Facet
  describe "POST /Api/core/Webhook — authoring connectivity gate (B-188)" do
    around_each do |example|
      with_fake_resolver({"receiver.test" => ["93.184.216.34"]}) do
        example.run
      end
    end

    before_each do
      with_db do |db|
        # The global truncation wipes the seeded definitions — re-ensure the
        # ones this file touches. `ensure_seed_roles_with_dependencies`
        # registers `core.DocType` / `core.Webhook` (the fix site, with its
        # script.lua) plus the doctypes the seeded roles' scope aliases
        # validate against; `iam.LoginEvent` is the webhook's bound source.
        # Idempotent, scoped — no full-corpus re-seed.
        ensure_seed_roles_with_dependencies(db)
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "LoginEvent")
        Facet::Doctype::DefinitionStore.cache.clear
        seed_webhook_source(db)
      end
    end

    it "refuses a role without the webhook channel, naming the channel (422)" do
      with_db do |db|
        ctx = channel_gate_actor(db, "wh-gate-off@example.com", "wh_gate_off", ["api"])

        resp = post_webhook(ctx)
        resp.status_code.should eq(422)

        body = JSON.parse(resp.body)
        message = body["error"]?.try(&.as_s) || ""
        details = body["details"]?.try(&.as_a?.try(&.map { |d| d["message"]?.try(&.as_s) || "" })) || [] of String
        full = ([message] + details).join("; ")
        full.should contain("webhook")
        full.should contain("connectivity")
      end
    end

    it "creates the webhook when the role carries the channel (201)" do
      with_db do |db|
        ctx = channel_gate_actor(db, "wh-gate-on@example.com", "wh_gate_on", ["mcp", "webhook", "api", "assistant"])

        resp = post_webhook(ctx)
        resp.status_code.should eq(201)

        created_id = JSON.parse(resp.body)["meta"]["id"].as_s
        stored = db.query_one(
          "SELECT content->>'role_id' FROM projections WHERE domain = 'core' AND doc_type = 'Webhook' AND id = $1",
          created_id, as: String)
        stored.should eq("iam.Roles.wh_gate_on")
      end
    end
  end
end
