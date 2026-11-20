# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/app/api_keys"
require "../../src/app/service_accounts"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"
require "../support/app_helper"

HTTPTest.init

# App-owned API keys — Part B of the app-system finalization plan.
#
# An app API key is a row in the existing `api_keys` table issued against
# the app's service account, tagged with the app id. Verification gates the
# app's liveness; the request path builds the same `app_scoped` context an
# OAuth app token gets (grant ∩ pinned role). One active key per app is
# route-level policy: issuing rotates, revoking kills.

# Seeds the role set the fixtures reference (iam.Roles.admin et al).
def seed_app_key_roles(db)
  seed_test_roles(db)
end

# Creates a backend app (confidential, service role pinned, active) with a
# wildcard read grant on the crm domain. Returns {id, slug}.
def create_backend_app(db, slug = "backend-app-#{unique_suffix}", status = "active")
  body = %({
    "slug": "#{slug}",
    "name": "Backend CRM",
    "client_type": "confidential",
    "service_role_id": "iam.Roles.admin",
    "status": "#{status}",
    "grants": [
      {"target": "crm.Contact", "actions": [{"name": "read", "required": true}, {"name": "create", "required": true}]}
    ]
  })
  result = Facet::Document::Create.call(db, "app", "App", body, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  {id: result.as(Facet::Document::Create::Result).projection.id, slug: slug}
end

# Creates a backend app (confidential, service role pinned, active) with the
# given grants. Returns the projection id.
def create_backend_app_with_role(db, role_id, grants : Array(String))
  body = %({
    "slug": "app-role-#{unique_suffix}",
    "name": "Role App",
    "client_type": "confidential",
    "service_role_id": "#{role_id}",
    "status": "active",
    "grants": [#{grants.join(",")}]
  })
  result = Facet::Document::Create.call(db, "app", "App", body, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

# Creates the crm.Contact doctype and one row so the enforcement round-trip
# has a target. Returns the document projection.
def create_crm_contact(db)
  ensure_domain(db, "crm")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Contact",
    domain: "crm",
    fields: {"name" => Facet::Doctype::FieldDefinition.new(
      type: Facet::Doctype::FieldType.parse("string"),
    )},
  )
  result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json,
    Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  row = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "Ada"}),
    Facet::RBAC::AuthContext.system)
  row.should be_a(Facet::Document::Create::Result)
  row.as(Facet::Document::Create::Result).projection
end

# Builds the app-scoped AuthContext the request path builds for a verified
# app key (the exact `build_api_key_auth_context` sequence).
def app_key_context(verified : Facet::IAM::ApiKey::Verified)
  app_id = verified.app_id.not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(verified.role_content)
  app_scope = Facet::RBAC::AppScope.from_content(app_id, verified.app_content.not_nil!)
  effective = Facet::RBAC::GrantResolver.resolve(app_scope, active_role)
  effective.empty?.should be_false
  Facet::RBAC::AuthContext.app_scoped(verified.account_id, active_role, effective, app_id)
end

# Logs in an operator and returns an Authorization header (browser-session
# channel, JSON body tokens — no cookie needed for the API surface).
def operator_headers(db) : HTTP::Headers
  create_test_account(db, password: "op-pass")
  body = %({"email": "test@example.com", "password": "op-pass", "cookie": false})
  resp = call_api(HTTP::Request.new("POST", "/Api/iam/login", headers: HTTP::Headers{
    "Content-Type"     => "application/json",
    "X-Requested-With" => "XMLHttpRequest",
  }, body: body))
  assert_http_status(resp, 200)
  token = JSON.parse(resp.body)["token"].as_s
  with_xrw(bearer_headers(token))
end

describe "App::ApiKeys" do
  # The per-example TRUNCATE wipes projections, so the doctype definitions
  # the fixtures write through must be re-registered before each example.
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "issues against a provisioned service account and verifies app-scoped" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      issued = Facet::App::ApiKeys.issue(db, app[:id])
      issued.should be_a(Facet::App::ApiKeys::Issued)
      key = issued.as(Facet::App::ApiKeys::Issued)

      key.key.starts_with?("fct_").should be_true
      key.role_id.should eq("iam.Roles.admin")

      # The service account: a real iam.Account, no login capability.
      svc = Facet::IAM::Helpers.find_account_by_id(db, key.service_account_id)
      svc.should_not be_nil
      svc = svc.not_nil!
      svc[:service_account].should be_true
      svc[:status].should eq("active")
      svc[:email].should eq(Facet::App::ServiceAccounts.email_for(app[:slug]))

      # The app links back to the account (references normalize to the
      # qualified form on persistence).
      app_content = db.query_one(
        "SELECT content FROM projections WHERE id = $1", app[:id], as: JSON::Any)
      app_content.as_h["service_account_id"]?.try(&.as_s?)
        .should eq("iam.Account.#{key.service_account_id}")

      # Verification carries the app pair.
      verified = Facet::IAM::ApiKey.verify(db, key.key)
      verified.should_not be_nil
      v = verified.not_nil!
      v.app_id.should eq(app[:id])
      v.app_content.should_not be_nil
      v.account_id.should eq(key.service_account_id)
    end
  end

  it "round-trips enforcement: granted reads succeed, outside-grant reads deny" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)
      contact = create_crm_contact(db)

      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      verified = Facet::IAM::ApiKey.verify(db, key.key).not_nil!
      ctx = app_key_context(verified)

      # Inside the grant: crm.* read.
      read = Facet::Document::Read.call(db, "crm", "Contact", contact.id, ctx)
      read.should be_a(Facet::Document::Read::Result)

      # Outside the grant: an iam.Account read is refused by Layer 1.
      target = create_test_account(db)
      denied = Facet::Document::Read.call(db, "iam", "Account", target, ctx)
      denied.should be_a(Facet::ServiceError)
    end
  end

  it "attributes mutations to the app and the service account" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)
      create_crm_contact(db)

      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      verified = Facet::IAM::ApiKey.verify(db, key.key).not_nil!
      ctx = app_key_context(verified)

      result = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "Grace"}), ctx)
      mut_id = result.as(Facet::Document::Create::Result).mutation_id

      app_col, actioner = db.query_one(
        "SELECT app, actioner_id FROM mutations WHERE id = $1",
        mut_id, as: {String?, String})
      app_col.should eq(app[:id])
      actioner.should eq(key.service_account_id)
    end
  end

  it "rotates: issuing a second time kills the first key" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      first = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      second = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      second.id.should_not eq(first.id)

      Facet::IAM::ApiKey.verify(db, first.key).should be_nil
      Facet::IAM::ApiKey.verify(db, second.key).should_not be_nil
    end
  end

  it "re-reuses the linked service account across rotations" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      first = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      second = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      second.service_account_id.should eq(first.service_account_id)
    end
  end

  it "re-syncs the service account's single role when the service role changes" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      first = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)

      # Repoint the app at the viewer role.
      upd = Facet::Document::Update.call(db, "app", "App", app[:id],
        %({"service_role_id": "iam.Roles.viewer"}), Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)

      second = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      second.role_id.should eq("iam.Roles.viewer")
      second.service_account_id.should eq(first.service_account_id)

      account = Facet::IAM::Helpers.find_account_by_id(db, first.service_account_id).not_nil!
      account[:roles].should eq(["iam.Roles.viewer"])
    end
  end

  it "revokes; revocation is idempotent" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      Facet::App::ApiKeys.revoke(db, app[:id]).should be_true
      Facet::App::ApiKeys.revoke(db, app[:id]).should be_false
      Facet::IAM::ApiKey.verify(db, key.key).should be_nil
      Facet::App::ApiKeys.active_key(db, app[:id]).should be_nil
    end
  end

  it "rejects a non-backend app and a missing service role" do
    with_db do |db|
      seed_app_key_roles(db)

      public_body = %({
        "slug": "public-app-#{unique_suffix}",
        "name": "Public App",
        "client_type": "public",
        "status": "active",
        "grants": []
      })
      result = Facet::Document::Create.call(db, "app", "App", public_body,
        Facet::RBAC::AuthContext.system)
      public_id = result.as(Facet::Document::Create::Result).projection.id

      err = Facet::App::ApiKeys.issue(db, public_id)
      err.should be_a(Facet::ServiceError)
      err.as(Facet::ServiceError).status.should eq(422)

      no_role_body = %({
        "slug": "no-role-#{unique_suffix}",
        "name": "No Role",
        "client_type": "confidential",
        "status": "active",
        "grants": []
      })
      result = Facet::Document::Create.call(db, "app", "App", no_role_body,
        Facet::RBAC::AuthContext.system)
      no_role_id = result.as(Facet::Document::Create::Result).projection.id

      err = Facet::App::ApiKeys.issue(db, no_role_id)
      err.should be_a(Facet::ServiceError)
      err.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "refuses issuance when the service role's connectivity excludes the api channel" do
    with_db do |db|
      seed_app_key_roles(db)

      # A browser-only service role: the service account authenticates as
      # exactly this role, so issuance refuses before provisioning anything.
      role_id = "iam.Roles.noapi-#{unique_suffix}"
      Facet::Mutation::Client.create(
        db, "iam", "Roles", doc_id: role_id,
        content: %({"name": "noapi-#{unique_suffix}", "description": "Browser-only role", "visible_tags": ["default"], "connectivity": [], "permissions": [{"action": "read", "on": "*.*"}]}),
        actioner_id: "system",
      )
      body = %({
        "slug": "noapi-app-#{unique_suffix}",
        "name": "No API App",
        "client_type": "confidential",
        "service_role_id": "#{role_id}",
        "status": "active",
        "grants": []
      })
      result = Facet::Document::Create.call(db, "app", "App", body,
        Facet::RBAC::AuthContext.system)
      app_id = result.as(Facet::Document::Create::Result).projection.id

      err = Facet::App::ApiKeys.issue(db, app_id)
      err.should be_a(Facet::ServiceError)
      denial = err.as(Facet::ServiceError)
      denial.status.should eq(422)
      denial.message.should contain("connectivity")
    end
  end

  it "refuses an auth context when the service role misses a required grant action" do
    # The run-48 fixture: the app demands `create` (required) on crm.Contact,
    # the pinned service role is read-only. The key verifies — the credential
    # is fine — but the auth-context build returns nil, which the request
    # path answers as the opaque 401. The diagnostics helper names the gap
    # the operator sees in the WARN log; the response still names nothing.
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      # Repoint the app at the read-only viewer role.
      upd = Facet::Document::Update.call(db, "app", "App", app[:id],
        %({"service_role_id": "iam.Roles.viewer"}), Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)

      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      verified = Facet::IAM::ApiKey.verify(db, key.key)
      verified.should_not be_nil
      v = verified.not_nil!

      active_role = Facet::RBAC::ActiveRole.from_projection_content(v.role_content)
      app_scope = Facet::RBAC::AppScope.from_content(v.app_id.not_nil!, v.app_content.not_nil!)

      Facet::RBAC::GrantResolver.role_usable?(app_scope, active_role).should be_false
      missing = Facet::RBAC::GrantResolver.missing_required_actions(app_scope, active_role)
      missing.should contain("create on crm.Contact")

      # The request path refuses at the usability gate — the WARN log names
      # `missing` — and answers 401 without a scope. (`resolve` alone would
      # still emit the covered `read` entry; the gate runs first.)
      Facet::RBAC::GrantResolver.missing_required_actions(app_scope, active_role)
        .should eq(["create on crm.Contact"])
    end
  end
end

describe "App API-key routes" do
  # Login + the AuthHandler JWT path need a live handler and Redis sessions.
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "issues, reports status, rotates, and revokes over HTTP as an operator" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)
      headers = operator_headers(db)

      # Issue → 201 with the one-time key.
      resp = call_api(HTTP::Request.new("POST", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 201)
      issued = JSON.parse(resp.body)
      issued["key"].as_s.starts_with?("fct_").should be_true
      first_key = issued["key"].as_s

      # Status → active with the display prefix, no secret.
      resp = call_api(HTTP::Request.new("GET", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 200)
      status_role = JSON.parse(resp.body)
      status_role["active"].as_bool.should be_true
      status_role["display_prefix"].as_s.should eq(first_key[0, 10])
      status_role["role_id"].as_s.should eq("iam.Roles.admin")
      resp.body.includes?(first_key).should be_false

      # Rotate → the old key dies.
      resp = call_api(HTTP::Request.new("POST", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 201)
      with_db do |vdb|
        Facet::IAM::ApiKey.verify(vdb, first_key).should be_nil
      end

      # Revoke → idempotent, key dead.
      resp = call_api(HTTP::Request.new("DELETE", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["revoked"].as_bool.should be_true

      resp = call_api(HTTP::Request.new("DELETE", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["revoked"].as_bool.should be_false

      resp = call_api(HTTP::Request.new("GET", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["active"].as_bool.should be_false
    end
  end

  it "refuses a state-changing request without the CSRF header" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)
      headers = operator_headers(db)
      # A cookie session is the ambient credential the CSRF defense
      # exists for — the header is required. A Bearer-only request would
      # be exempt (non-ambient credential).
      token = headers["Authorization"].sub(/^Bearer /, "")
      headers.delete("Authorization")
      headers.delete("X-Requested-With")
      headers["Cookie"] = "auth_token=#{token}"

      resp = call_api_raw(HTTP::Request.new("POST", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 403)
    end
  end

  it "refuses an API-key caller — a key can never mint or revoke itself" do
    with_db do |db|
      seed_app_key_roles(db)
      app = create_backend_app(db)

      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      headers = with_xrw(bearer_headers(key.key))

      resp = call_api(HTTP::Request.new("POST", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 403)

      resp = call_api(HTTP::Request.new("DELETE", "/Api/app/#{app[:id]}/api-key", headers: headers))
      assert_http_status(resp, 403)
    end
  end

  it "refuses issuance when a domain-wide role line misses the app's grants (422 + remedy)" do
    with_db do |db|
      seed_app_key_roles(db)
      # A backend app granted one concrete doctype, pinned to a role whose
      # only line is the domain-wide form — its empty path never covers a
      # concrete grant target.
      role_id = "iam.Roles.domain-wide-#{unique_suffix}"
      Facet::Mutation::Client.create(
        db, "iam", "Roles", doc_id: role_id,
        content: %({"name": "domain-wide-#{unique_suffix}", "description": "Domain-wide role", "visible_tags": ["default"], "connectivity": ["api"], "permissions": [{"action": "*", "on": "crm"}]}),
        actioner_id: "system",
      )
      app_id = create_backend_app_with_role(db, role_id, [
        %({"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}),
      ])

      result = Facet::App::ApiKeys.issue(db, app_id)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("do not intersect")
      err.message.should contain(%({"on": "crm.Contact", "action": "*"}))

      # No key row exists — the refusal precedes issuance.
      db.query_one(
        "SELECT COUNT(*) FROM api_keys WHERE app_id = $1", app_id, as: Int64
      ).should eq(0)
    end
  end

  it "issues when the role line repeats the grant target" do
    with_db do |db|
      seed_app_key_roles(db)
      role_id = "iam.Roles.concrete-#{unique_suffix}"
      Facet::Mutation::Client.create(
        db, "iam", "Roles", doc_id: role_id,
        content: %({"name": "concrete-#{unique_suffix}", "description": "Concrete role", "visible_tags": ["default"], "connectivity": ["api"], "permissions": [{"action": "*", "on": "crm.Contact"}]}),
        actioner_id: "system",
      )
      app_id = create_backend_app_with_role(db, role_id, [
        %({"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}),
      ])

      issued = Facet::App::ApiKeys.issue(db, app_id)
      issued.should be_a(Facet::App::ApiKeys::Issued)
      issued.as(Facet::App::ApiKeys::Issued).role_id.should eq(role_id)
    end
  end

  it "returns 404 for an unknown app" do
    with_db do |db|
      headers = operator_headers(db)
      missing = Facet::Util::ScriptHelpers.ulid

      resp = call_api(HTTP::Request.new("GET", "/Api/app/#{missing}/api-key", headers: headers))
      assert_http_status(resp, 404)
    end
  end
end

# Seeds a `ledger.Invoice` doctype with one named action (`approve`), so the
# attribution specs can drive both the flat create route and a named action
# through the full HTTP chain. Re-registered per example — the global
# TRUNCATE wipes `projections`.
private def seed_invoice_doctype(db)
  ensure_domain(db, "ledger")
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.approve(ctx, args)
      ctx.root.status = args.status
    end
    return export
  LUA
  defn = %({
    "doctype": "Invoice",
    "domain": "ledger",
    "fields": {"status": {"type": "string"}},
    "actions": {"approve": {"args": {"status": {"type": "string", "required": true}}}},
    "script": #{script.to_json}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

# Creates an active confidential backend app whose grants cover
# `ledger.Invoice` (read, write) plus the optional `approve` action the
# named-action spec drives. Returns {id, slug}.
private def create_ledger_app(db)
  slug = "ledger-sync-#{unique_suffix}"
  body = %({
    "slug": "#{slug}",
    "name": "Ledger Sync",
    "client_type": "confidential",
    "service_role_id": "iam.Roles.admin",
    "status": "active",
    "grants": [
      {"target": "ledger.Invoice", "actions": [
        {"name": "read", "required": true},
        {"name": "write", "required": true},
        {"name": "approve", "required": false}
      ]}
    ]
  })
  result = Facet::Document::Create.call(db, "app", "App", body, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  {id: result.as(Facet::Document::Create::Result).projection.id, slug: slug}
end

# Reads the provenance columns of the single `mutations` row matching the
# pin (one document per example, so one row per action kind).
private def mutation_provenance(db, domain, doc_type, doc_id, action)
  db.query_one(
    <<-SQL,
      SELECT actioner_id, app, channel, api_key, cause_name
      FROM mutations
      WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = $4
    SQL
    domain, doc_type, doc_id, action,
    as: {String, String?, String, String?, String?},
  )
end

# Logs in an operator and returns the raw access JWT (browser-session
# channel) so a spec can build a Cookie header for fallback scenarios.
private def session_token(db) : String
  create_test_account(db, password: "op-pass")
  body = %({"email": "test@example.com", "password": "op-pass", "cookie": false})
  resp = call_api(HTTP::Request.new("POST", "/Api/iam/login", headers: HTTP::Headers{
    "Content-Type"     => "application/json",
    "X-Requested-With" => "XMLHttpRequest",
  }, body: body))
  assert_http_status(resp, 200)
  JSON.parse(resp.body)["token"].as_s
end

describe "App-key mutation attribution over HTTP" do
  # The flat create / action routes run through the full Kemal chain, so the
  # AuthHandler JWT/api-key path must be live for these examples.
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "attributes an app-key create to the service account, the app, and the app_api_key channel" do
    with_db do |db|
      seed_app_key_roles(db)
      seed_invoice_doctype(db)
      app = create_ledger_app(db)
      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice",
        headers: bearer_headers(key.key),
        body: %({"status": "draft"}),
      ))
      assert_http_status(resp, 201)

      doc_id = db.query_one(
        "SELECT id FROM projections WHERE domain = 'ledger' AND doc_type = 'Invoice' AND deleted_at IS NULL",
        as: String,
      )
      actioner, app_col, channel, api_key_col, cause_name = mutation_provenance(db, "ledger", "Invoice", doc_id, "create")
      actioner.should eq(key.service_account_id)
      app_col.should eq(app[:id])
      channel.should eq("app_api_key")
      api_key_col.should eq(key.id)
      cause_name.should be_nil
    end
  end

  it "keeps app attribution on a named action through an app key" do
    with_db do |db|
      seed_app_key_roles(db)
      seed_invoice_doctype(db)
      app = create_ledger_app(db)
      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice",
        headers: bearer_headers(key.key),
        body: %({"status": "draft"}),
      ))
      assert_http_status(resp, 201)
      doc_id = db.query_one(
        "SELECT id FROM projections WHERE domain = 'ledger' AND doc_type = 'Invoice' AND deleted_at IS NULL",
        as: String,
      )

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice/#{doc_id}/approve",
        headers: bearer_headers(key.key),
        body: %({"status": "paid"}),
      ))
      assert_http_status(resp, 200)

      actioner, app_col, channel, _api_key_col, cause_name = mutation_provenance(db, "ledger", "Invoice", doc_id, "update")
      actioner.should eq(key.service_account_id)
      app_col.should eq(app[:id])
      channel.should eq("app_api_key")
      cause_name.should eq("approve")
    end
  end

  it "keeps self-service (non-app) API-key attribution unchanged" do
    with_db do |db|
      seed_app_key_roles(db)
      seed_invoice_doctype(db)
      account_id = create_test_account(db, password: "key-pass")
      created = Facet::IAM::ApiKey.generate(db, account_id, "iam.Roles.admin", "self-#{unique_suffix}")

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice",
        headers: bearer_headers(created.key),
        body: %({"status": "draft"}),
      ))
      assert_http_status(resp, 201)

      doc_id = db.query_one(
        "SELECT id FROM projections WHERE domain = 'ledger' AND doc_type = 'Invoice' AND deleted_at IS NULL",
        as: String,
      )
      actioner, app_col, channel, api_key_col, _cause_name = mutation_provenance(db, "ledger", "Invoice", doc_id, "create")
      actioner.should eq(account_id)
      app_col.should be_nil
      channel.should eq("api_key")
      api_key_col.should eq(created.id)
    end
  end

  it "answers 401 when the request presents a broken Authorization header beside a session cookie" do
    # The B-36 integrity rule: an app-key request whose explicit credential
    # fails to parse (an empty bearer token — the shape a client sends when
    # the key variable is unset) must fail closed instead of inheriting the
    # ambient human session. The cookie fallback serves a request that
    # presents NO credential; a broken explicit one never downgrades, or
    # the mutation would land in the audit log as the human's session write.
    with_db do |db|
      seed_app_key_roles(db)
      seed_invoice_doctype(db)
      admin_jwt = session_token(db)

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice",
        headers: HTTP::Headers{
          "Authorization" => "Bearer ",
          "Cookie"        => "auth_token=#{admin_jwt}",
        },
        body: %({"status": "draft"}),
      ))
      assert_http_status(resp, 401)

      rows = db.query_one(
        "SELECT count(*) FROM mutations WHERE domain = 'ledger' AND doc_type = 'Invoice'",
        as: Int64,
      )
      rows.should eq(0)
    end
  end

  it "keeps app-key attribution when a session cookie rides beside the key" do
    # The dashboard origin always ships its ambient session; a well-formed
    # Authorization header must stay authoritative so the mutation keeps the
    # service-account actioner instead of the cookie's human.
    with_db do |db|
      seed_app_key_roles(db)
      seed_invoice_doctype(db)
      app = create_ledger_app(db)
      key = Facet::App::ApiKeys.issue(db, app[:id]).as(Facet::App::ApiKeys::Issued)
      admin_jwt = session_token(db)

      resp = call_api(HTTP::Request.new(
        "POST", "/Api/ledger/Invoice",
        headers: HTTP::Headers{
          "Authorization" => "Bearer #{key.key}",
          "Cookie"        => "auth_token=#{admin_jwt}",
        },
        body: %({"status": "draft"}),
      ))
      assert_http_status(resp, 201)

      doc_id = db.query_one(
        "SELECT id FROM projections WHERE domain = 'ledger' AND doc_type = 'Invoice' AND deleted_at IS NULL",
        as: String,
      )
      actioner, app_col, channel, _api_key_col, _cause_name = mutation_provenance(db, "ledger", "Invoice", doc_id, "create")
      actioner.should eq(key.service_account_id)
      app_col.should eq(app[:id])
      channel.should eq("app_api_key")
    end
  end
end
