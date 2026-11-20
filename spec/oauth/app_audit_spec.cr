# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/oauth"
require "../../src/iam"
require "../../src/rbac"
require "../support/app_helper"
require "../support/oauth_helper"
require "../support/redis_helper"
require "../support/http_helpers"

# App System — audit + observability.
#
# Covers:
#   1. Mutations made through an app record the `app` id in the typed
#      provenance columns.
#   2. Audit::List surfaces the app attribution (`mutations.app`) and filters
#      on `app__eq`.
#   3. OAuth events (consent_granted, refresh_failed) and Layer-1 denials are
#      written as `iam.LoginEvent` rows with a structured `app` field.
#   4. The current OpenTelemetry span carries the `app` attribute on
#      app-scoped requests.

# Builds a single RBAC permission line.
def p6_perm(action : String, on : String)
  parts = on.split('.')
  Facet::RBAC::Permission.new(
    action: action,
    domain: parts[0],
    path: parts[1..],
  )
end

# Builds an ActiveRole carrying the given permissions.
def p6_role(perms : Array(Facet::RBAC::Permission), role_id : String = "p6_role")
  Facet::RBAC::ActiveRole.new(
    role_id: role_id,
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: perms,
  )
end

# Resolves an EffectiveScope from a grants JSON literal + a role.
def p6_scope(grants_json : String, r : Facet::RBAC::ActiveRole, app_id : String)
  content = JSON.parse(%({"grants": #{grants_json}}))
  Facet::RBAC::GrantResolver.resolve(
    Facet::RBAC::AppScope.from_content(app_id, content), r)
end

# Creates a doctype with a single string `name` field. Mirrors the
# `create_test_doc` pattern in spec/audit/audit_spec.cr.
def p6_create_doctype(db, domain, doctype)
  ensure_domain(db, domain)
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: domain,
    fields: {"name" => Facet::Doctype::FieldDefinition.new(
      type: Facet::Doctype::FieldType.parse("string"))},
  )
  result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json,
    Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

# Returns the most recent `iam.LoginEvent` projection row matching the given
# event name and (optional) app id. Returns nil when no match exists.
def p6_last_login_event(db, event : String, app : String? = nil) : JSON::Any?
  if app
    db.query_one?(
      "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' " \
      "AND content->>'event' = $1 AND content->>'app' = $2 ORDER BY created_at DESC LIMIT 1",
      event, app, as: JSON::Any)
  else
    db.query_one?(
      "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' " \
      "AND content->>'event' = $1 ORDER BY created_at DESC LIMIT 1",
      event, as: JSON::Any)
  end
end

describe "App System Phase 6 — audit + observability" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    Facet::OAuth::OriginCache.reset
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      Facet::OAuth::OriginCache.reset
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  # ── 1. Mutation attribution ─────────────────────────────────────────────

  describe "mutation app attribution" do
    it "writes meta.app when the actioner carries an app_id" do
      with_db do |db|
        p6_create_doctype(db, "crm", "Widget")

        app_id, _ = create_test_app(db, "mut-app",
          grants: [oauth_grant("crm.Widget", [oauth_action("write", required: true)])])
        r = p6_role([p6_perm("create", "crm.Widget")])
        grant = p6_scope(
          %([{"target": "crm.Widget", "actions": [{"name": "write", "required": true}]}]),
          r, app_id)
        ctx = Facet::RBAC::AuthContext.app_scoped("alice", r, grant, app_id)

        result = Facet::Document::Create.call(db, "crm", "Widget", %({"name":"w1"}), ctx)
        result.should be_a(Facet::Document::Create::Result)
        mut_id = result.as(Facet::Document::Create::Result).mutation_id

        meta_app = db.query_one(
          "SELECT app FROM mutations WHERE id = $1",
          mut_id, as: String?)
        meta_app.should eq(app_id)
      end
    end

    it "leaves app absent for ordinary browser-session mutations" do
      with_db do |db|
        p6_create_doctype(db, "crm", "Gadget")

        result = Facet::Document::Create.call(db, "crm", "Gadget",
          %({"name":"g1"}), Facet::RBAC::AuthContext.system)
        mut_id = result.as(Facet::Document::Create::Result).mutation_id

        meta_app = db.query_one(
          "SELECT app FROM mutations WHERE id = $1",
          mut_id, as: String?)
        meta_app.should be_nil
      end
    end
  end

  # ── 2. Audit::List app attribution + filter ─────────────────────────────

  describe "Audit::List app attribution" do
    it "surfaces app on MutationRecord and supports app__eq filter" do
      with_db do |db|
        p6_create_doctype(db, "crm", "Thing")

        app_id, _ = create_test_app(db, "audit-app",
          grants: [oauth_grant("crm.Thing", [oauth_action("write", required: true)])])
        r = p6_role([p6_perm("create", "crm.Thing")])
        grant = p6_scope(
          %([{"target": "crm.Thing", "actions": [{"name": "write", "required": true}]}]),
          r, app_id)
        app_ctx = Facet::RBAC::AuthContext.app_scoped("alice", r, grant, app_id)

        # App-attributed create.
        Facet::Document::Create.call(db, "crm", "Thing", %({"name":"t1"}), app_ctx)
        # Non-app create.
        Facet::Document::Create.call(db, "crm", "Thing", %({"name":"t2"}),
          Facet::RBAC::AuthContext.system)

        # Unfiltered — both mutations present; only the first carries app.
        all = Facet::Audit::List.call(db, domain: "crm", doc_type: "Thing",
          auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
        all.items.any?(&.app.==(app_id)).should be_true
        all.items.any?(&.app.nil?).should be_true

        # Filtered by app__eq — only the app-attributed mutation.
        only_app = Facet::Audit::List.call(db, domain: "crm", doc_type: "Thing",
          filters: {"app__eq" => JSON::Any.new(app_id)},
          auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
        only_app.items.all?(&.app.==(app_id)).should be_true
        only_app.items.size.should eq(1)
      end
    end
  end

  # ── 3. OAuth + Layer-1 denial events ─────────────────────────────────────

  describe "app-attributed LoginEvents" do
    it "writes consent_granted on authorize confirm with the app id" do
      with_db do |db|
        app_id, client_id = create_test_app(db, "consent-app",
          grants: [oauth_grant("crm.Widget", [oauth_action("create", required: true)])])
        create_test_role(db, "writer", [oauth_perm("create", "crm.Widget")])
        account_id = create_test_account(db, roles: ["iam.Roles.writer"], default_role: "iam.Roles.writer")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.writer")

        ev = p6_last_login_event(db, "consent_granted", app: app_id)
        ev.should_not be_nil
        ev.not_nil!["app"].as_s.should eq(app_id)
      end
    end

    it "writes refresh_failed with app attribution when the app is disabled mid-session" do
      with_db do |db|
        app_id, client_id = create_test_app(db, "rfail-app",
          grants: [oauth_grant("crm.Widget", [oauth_action("write", required: true)])])
        create_test_role(db, "writer", [oauth_perm("create", "crm.Widget")])
        account_id = create_test_account(db, roles: ["iam.Roles.writer"], default_role: "iam.Roles.writer")

        # Create an app session directly so we can exercise the refresh path
        # without standing up the full HTTP authorize → token round trip.
        session_id, refresh_id = Facet::IAM::RedisSession.create_app_session(
          account_id: account_id, active_role: "iam.Roles.writer", app: app_id,
          client_id: client_id)

        # Disable the app — the next refresh must fail and write refresh_failed.
        # Backdate the refresh floor — the live-state check must be what fails.
        Facet::Document::Update.call(db, "app", "App", app_id,
          %({"status":"disabled"}), Facet::RBAC::AuthContext.system)
        backdate_refresh_issued_at("#{session_id}.#{refresh_id}")

        expect_raises(Facet::OAuth::Refresh::Error, /not active/) do
          Facet::OAuth::Refresh.call(db, "#{session_id}.#{refresh_id}", client_id: client_id)
        end

        ev = p6_last_login_event(db, "refresh_failed", app: app_id)
        ev.should_not be_nil
        ev.not_nil!["app"].as_s.should eq(app_id)
      end
    end

    it "writes layer1_denied when an app-scoped create is refused by the grant" do
      with_db do |db|
        p6_create_doctype(db, "crm", "Secret")

        # Grant on crm.Widget only; the role covers crm.Secret — so the role
        # would allow the create, but the app grant refuses it (Layer-1).
        app_id, _ = create_test_app(db, "deny-app",
          grants: [oauth_grant("crm.Widget", [oauth_action("write", required: true)])])
        r = p6_role([p6_perm("create", "crm.Secret")])
        grant = p6_scope(
          %([{"target": "crm.Widget", "actions": [{"name": "write", "required": true}]}]),
          r, app_id)
        ctx = Facet::RBAC::AuthContext.app_scoped("alice", r, grant, app_id)

        result = Facet::Document::Create.call(db, "crm", "Secret", %({"name":"s1"}), ctx)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)

        ev = p6_last_login_event(db, "layer1_denied", app: app_id)
        ev.should_not be_nil
        ev.not_nil!["app"].as_s.should eq(app_id)
        ev.not_nil!["details"].as_s.should contain("create")
      end
    end

    it "does not write layer1_denied for ordinary browser-session denials" do
      with_db do |db|
        p6_create_doctype(db, "crm", "Locked")

        # An authenticated context with no read permission on crm.Locked.
        ctx = Facet::RBAC::AuthContext.authenticated("alice",
          p6_role([p6_perm("read", "hr.Irrelevant")]))

        result = Facet::Document::Read.call(db, "crm", "Locked", "never-existed", ctx)
        result.should be_a(Facet::ServiceError)

        # No layer1_denied row — the denial is not app-attributed.
        p6_last_login_event(db, "layer1_denied").should be_nil
      end
    end
  end

  # ── 4. OpenTelemetry span attribute ──────────────────────────────────────

  describe "OpenTelemetry span app attribute" do
    around_each do |example|
      # Ensure telemetry is initialised (NullExporter is fine — the span
      # object still exists in-memory and carries attributes).
      Facet::Telemetry.init
      example.run
    end

    it "attaches app/role to the current span on app-scoped auth" do
      with_db do |db|
        app_id, _ = create_test_app(db, "span-app",
          grants: [oauth_grant("crm.Widget", [oauth_action("write", required: true)])])
        create_test_role(db, "writer", [oauth_perm("create", "crm.Widget")])
        account_id = create_test_account(db, roles: ["iam.Roles.writer"], default_role: "iam.Roles.writer")

        token = sign_app_token(account_id, "iam.Roles.writer", app_id)
        headers = bearer_headers(token)

        # Drive AuthHandler inside an OTel trace so the root span is open
        # when build_app_auth_context runs.
        captured_app = nil
        captured_role = nil
        OpenTelemetry.trace "test.request" do |_span|
          Facet::HTTP::AuthHandler.auth_context_from_request(
            HTTP::Server::Context.new(
              request: HTTP::Request.new("GET", "/Api/iam/me", headers: headers),
              response: HTTP::Server::Response.new(IO::Memory.new),
            )
          )
          if inner = OpenTelemetry.current_span
            captured_app = inner["app"]?
            captured_role = inner["role"]?
          end
        end

        captured_app.should eq(app_id)
        captured_role.should eq("iam.Roles.writer")
      end
    end
  end
end
