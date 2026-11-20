# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/app/api_keys"
require "../../src/app/service_accounts"
require "../support/app_helper"
require "../support/iam_helper"
require "../support/result_helper"

# The `facet-cli` seed: the first-party CLI app registration, the Lua
# self-grant guard on `app.App`, and the redirect-URI / headless hook
# validation.
#
# Files covered:
#   - `data/seeds/app.App/documents.yml` — the seeded app document
#   - `data/seeds/app.App/script.lua` — the update-hook guard, the
#     redirect-URI shape rule, and the no_asset/host coherence rule
#
# The seed helper (`seed_facet_cli_app`) runs the same create pipeline
# `Doctype::Seed` uses, so the round-trip asserts what a fresh seed
# produces: hook-assigned `client_id`, verbatim grant storage, the
# loopback redirect patterns, and the headless flags.

# An app-scoped principal carrying `update` on `app.App` in its grant
# ceiling and role — the shape AuthHandler builds for an OAuth app token.
def cli_app_scoped_ctx(account_id : String, app_id : String) : Facet::RBAC::AuthContext
  permission = Facet::RBAC::Permission.new(action: "update", domain: "app", path: ["App"])
  role = Facet::RBAC::ActiveRole.new(
    role_id: "deploy_role",
    visible_tags: Set{"default"},
    permissions: [permission],
  )
  Facet::RBAC::AuthContext.app_scoped(account_id, role, Facet::RBAC::EffectiveScope.from_active_role(role), app_id)
end

# An ActiveRole carrying exactly the CLI actions — what a deploy-capable
# user role looks like against the seeded grant ceiling.
def cli_actions_role : Facet::RBAC::ActiveRole
  Facet::RBAC::ActiveRole.new(
    role_id: "cli_actions",
    visible_tags: Set{"default"},
    permissions: [
      Facet::RBAC::Permission.new(action: "read", domain: "app", path: ["App"]),
      Facet::RBAC::Permission.new(action: "create", domain: "app", path: ["App"]),
      Facet::RBAC::Permission.new(action: "update", domain: "app", path: ["App"]),
      Facet::RBAC::Permission.new(action: "delete", domain: "app", path: ["App"]),
      Facet::RBAC::Permission.new(action: "deploy", domain: "app", path: ["App"]),
      Facet::RBAC::Permission.new(action: "read", domain: "app", path: ["Deployment"]),
    ],
  )
end

# Creates an app with the given redirect_uris JSON through the document
# pipeline, as the system principal.
def create_app_with_redirect_uris(db, uris_json : String)
  Facet::Document::Create.call(
    db, "app", "App",
    %({"slug": "uris-#{unique_suffix}", "name": "URI App", "status": "active", "redirect_uris": #{uris_json}}),
    Facet::RBAC::AuthContext.system,
  )
end

describe "facet-cli seed" do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
      seed_test_roles(db)
    end
  end

  describe "seed round-trip" do
    it "creates the app through the document pipeline" do
      app = with_db { |db| seed_facet_cli_app(db) }

      app.id.should eq("facet-cli")
      content = app.content.as_h
      content["slug"].as_s.should eq("facet-cli")
      content["name"].as_s.should eq("Facet CLI")
      content["client_type"].as_s.should eq("public")
      content["status"].as_s.should eq("active")
      content["no_launcher"].as_bool.should be_true
      content["no_asset"].as_bool.should be_true

      # The create hook assigned the public client id (the seed content
      # never carries one — the hook is the only writer).
      content["client_id"].as_s.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)

      # No service identity: the CLI signs in through OAuth, the elected
      # role comes from the consent screen.
      content["service_role_id"]?.should be_nil
      content["service_account_id"]?.should be_nil

      # The loopback redirect patterns (RFC 8252 — the port is never
      # pinned).
      redirect_uris = content["redirect_uris"].as_a.map(&.as_s)
      redirect_uris.should contain("http://localhost:*")
      redirect_uris.should contain("http://127.0.0.1:*")
      redirect_uris.should contain("http://[::1]:*")

      # Grants store verbatim: two entries; `write` is not pre-expanded.
      grants = content["grants"].as_a
      grants.size.should eq(2)
      grants[0]["target"].as_s.should eq("app.App")
      grants[0]["actions"].as_a.map(&.["name"].as_s).sort!.should eq(%w[delete deploy read write])
      grants[0]["actions"].as_a.all?(&.["required"].as_bool).should be_true
      grants[1]["target"].as_s.should eq("app.Deployment")
      grants[1]["actions"].as_a.map(&.["name"].as_s).should eq(%w[read])
    end

    it "intersects with a deploy-capable role to exactly the CLI actions" do
      app = with_db { |db| seed_facet_cli_app(db) }
      with_db do
        active_role = cli_actions_role
        app_scope = Facet::RBAC::AppScope.from_projection(app)

        Facet::RBAC::GrantResolver.role_usable?(app_scope, active_role).should be_true

        effective = Facet::RBAC::GrantResolver.resolve(app_scope, active_role)
        app_entry = effective.entries.find { |e| e.domain == "app" && e.path == ["App"] }
        app_entry.should_not be_nil
        app_entry.not_nil!.actions.should eq(%w[read create update delete deploy].to_set)

        deployment_entry = effective.entries.find { |e| e.domain == "app" && e.path == ["Deployment"] }
        deployment_entry.should_not be_nil
        deployment_entry.not_nil!.actions.should eq(%w[read].to_set)
      end
    end

    it "rejects a role without deploy (the required action floor)" do
      app = with_db { |db| seed_facet_cli_app(db) }
      with_db do |db|
        role_content = Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.viewer")
        active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
        app_scope = Facet::RBAC::AppScope.from_projection(app)

        Facet::RBAC::GrantResolver.role_usable?(app_scope, active_role).should be_false
      end
    end

    it "refuses API-key issuance: a public app is not a backend app" do
      app = with_db { |db| seed_facet_cli_app(db) }
      issued = with_db { |db| Facet::App::ApiKeys.issue(db, app.id) }
      issued.should be_a(Facet::ServiceError)
      issued.as(Facet::ServiceError).status.should eq(422)
    end
  end

  describe "app-scoped guard (update hook)" do
    it "lets an operator patch grants" do
      app = with_db { |db| seed_facet_cli_app(db) }
      operator = Facet::RBAC::AuthContext.authenticated(
        "operator-#{unique_suffix}",
        Facet::RBAC::ActiveRole.new(
          role_id: "app_admin",
          visible_tags: Set{"default"},
          permissions: [Facet::RBAC::Permission.new(action: "update", domain: "app", path: ["App"])],
        ),
      )
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"grants": [{"target": "app.App", "actions": [{"name": "read"}]}]}),
          operator,
        )
        result.should be_a(Facet::Document::Update::Result)
        content = Facet::Mutation::Client.fetch_content(db, "app", "App", app.id)
        content["grants"].as_a.size.should eq(1)
      end
    end

    it "rejects an app-scoped patch carrying grants" do
      app = with_db { |db| seed_facet_cli_app(db) }
      app_scoped = cli_app_scoped_ctx("svc-#{unique_suffix}", app.id)
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"grants": [{"target": "app.App", "actions": [{"name": "read"}, {"name": "write"}]}]}),
          app_scoped,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.any?(&.message.matches?(/app-scoped caller/)).should be_true
      end
    end

    it "rejects an app-scoped patch carrying service_role_id" do
      app = with_db { |db| seed_facet_cli_app(db) }
      app_scoped = cli_app_scoped_ctx("svc-#{unique_suffix}", app.id)
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"service_role_id": "iam.Roles.admin"}),
          app_scoped,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "lets an app-scoped caller patch unguarded fields" do
      app = with_db { |db| seed_facet_cli_app(db) }
      app_scoped = cli_app_scoped_ctx("svc-#{unique_suffix}", app.id)
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"name": "Facet CLI (edited)"}),
          app_scoped,
        )
        result.should be_a(Facet::Document::Update::Result)
        content = Facet::Mutation::Client.fetch_content(db, "app", "App", app.id)
        content["name"].as_s.should eq("Facet CLI (edited)")
      end
    end
  end

  describe "redirect-URI shape (create/update hook)" do
    it "accepts the loopback port pattern and a pinned https URI" do
      with_db do |db|
        result = create_app_with_redirect_uris(
          db,
          %(["http://localhost:*", "http://facet.localhost:*", "http://127.0.0.1:*", "http://[::1]:*", "https://app.example.com/cb"]),
        )
        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "accepts a wildcard entry with a pinned path" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %(["http://localhost:*/auth/cb"]))
        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "accepts http on loopback hosts" do
      with_db do |db|
        result = create_app_with_redirect_uris(
          db,
          %(["http://localhost:5173/cb", "http://facet.localhost:5173/cb", "http://127.0.0.1/cb", "http://[::1]:5173/cb"]),
        )
        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "rejects http on a non-loopback host (B-154)" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %(["http://public.example.com/cb"]))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a wildcard on a non-loopback host" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %(["https://app.example.com:*"]))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a wildcard outside the port position" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %(["https://*.example.com/cb"]))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a fragment and a query" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %(["https://app.example.com/cb#x", "https://app.example.com/cb?a=1"]))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a non-string entry" do
      with_db do |db|
        result = create_app_with_redirect_uris(db, %([42]))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "re-validates on update" do
      app = with_db { |db| seed_facet_cli_app(db) }
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"redirect_uris": ["https://app.example.com:*"]}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end
  end

  describe "headless flags (no_asset / host coherence)" do
    it "rejects a host on a no_asset app at create" do
      with_db do |db|
        result = Facet::Document::Create.call(
          db, "app", "App",
          %({"slug": "headless-#{unique_suffix}", "name": "Headless", "status": "active", "no_asset": true, "host": "tool.example.com"}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a host PATCH onto a no_asset app" do
      app = with_db { |db| seed_facet_cli_app(db) }
      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"host": "tool.example.com"}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "rejects a no_asset PATCH onto an app with a host" do
      with_db do |db|
        created = Facet::Document::Create.call(
          db, "app", "App",
          %({"slug": "hosted-#{unique_suffix}", "name": "Hosted", "status": "active", "host": "hr.app.example.com"}),
          Facet::RBAC::AuthContext.system,
        )
        created.should be_a(Facet::Document::Create::Result)
        app = created.as(Facet::Document::Create::Result).projection

        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"no_asset": true}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end
  end
end
