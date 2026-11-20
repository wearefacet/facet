# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"
require "../support/app_helper"

HTTPTest.init

# API access keys (`IAM::ApiKey`, `AuthHandler` `fct_` branch,
# `/Api/iam/keys` routes, service-account login gate, mutation provenance).
#
# Locked decisions (see `doc/backend/iam.md` → `Facet::IAM::ApiKey`):
# `Authorization: Bearer fct_…`; a key dies with its `{account, role}` pair;
# hash-only storage; `last_used_at` throttled to one write per minute; every
# mutation carries an `api_key` provenance tag in the `mutations.api_key` column.

PREFIX = Facet::IAM::ApiKey::PREFIX

# Generates a key directly for `{account, role}` and returns the record.
def gen_key(db, account_id, role = "iam.Roles.admin", name = "ci", expires_at = nil)
  Facet::IAM::ApiKey.generate(db, account_id, role, name, expires_at)
end

describe "IAM::ApiKey" do
  it "generates a 30-char token with the fct_ prefix and a Crockford body" do
    token = Facet::IAM::ApiKey.generate_token
    token.size.should eq(30)
    token.starts_with?(PREFIX).should be_true

    body = token[PREFIX.size..]
    body.size.should eq(26)
    body.chars.all? { |c| Facet::Util::ScriptHelpers::CROCKFORD.includes?(c) }.should be_true
  end

  it "recognizes well-formed tokens via token?" do
    Facet::IAM::ApiKey.token?("#{PREFIX}#{"A" * 26}").should be_true
    Facet::IAM::ApiKey.token?("eyJhbGciOiJFUzI1NiJ9.a.b").should be_false
    Facet::IAM::ApiKey.token?("fct_short").should be_false
  end

  it "verifies a freshly generated key and reports the pair" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)

      verified = Facet::IAM::ApiKey.verify(db, created.key)
      verified.should_not be_nil
      v = verified.not_nil!
      v.key_id.should eq(created.id)
      v.account_id.should eq(account_id)
      v.role_id.should eq("iam.Roles.admin")
    end
  end

  it "stores only the hash — the raw token never lands in the table" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)

      raw_count = db.query_one?("SELECT COUNT(*) FROM api_keys WHERE account_id = $1 AND secret_hash = $2",
        account_id, created.key, as: Int64)
      raw_count.should eq(0)

      hash_count = db.query_one?("SELECT COUNT(*) FROM api_keys WHERE secret_hash = $1",
        Facet::Util::ScriptHelpers.sha256(created.key), as: Int64)
      hash_count.should eq(1)
    end
  end

  it "rejects an unknown token" do
    with_db do |db|
      Facet::IAM::ApiKey.verify(db, "#{PREFIX}#{"B" * 26}").should be_nil
    end
  end

  it "rejects a revoked key, and revocation is idempotent" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)

      Facet::IAM::ApiKey.revoke(db, account_id, created.id).should be_true
      Facet::IAM::ApiKey.revoke(db, account_id, created.id).should be_false
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "rejects an expired key but accepts a future expiry" do
    with_db do |db|
      account_id = create_test_account(db)
      past = gen_key(db, account_id, expires_at: (Time.utc - 1.minute).to_rfc3339)
      future = gen_key(db, account_id, name: "later", expires_at: (Time.utc + 1.hour).to_rfc3339)

      Facet::IAM::ApiKey.verify(db, past.key).should be_nil
      Facet::IAM::ApiKey.verify(db, future.key).should_not be_nil
    end
  end

  it "rejects a suspended or deleted account" do
    with_db do |db|
      account_id = create_test_account(db, status: "suspended")
      created = gen_key(db, account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil

      db.exec("UPDATE projections SET deleted_at = now() WHERE id = $1", account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "kills an app-owned key when the app is disabled or deleted" do
    with_db do |db|
      # The per-example TRUNCATE wipes the app.App + iam.* definitions.
      seed_app_doctypes(db)
      seed_iam_doctypes(db)

      account_id = create_test_account(db)
      app_body = %({
        "slug": "gate-app-#{unique_suffix}",
        "name": "Gate App",
        "client_type": "confidential",
        "status": "active",
        "grants": []
      })
      result = Facet::Document::Create.call(db, "app", "App", app_body,
        Facet::RBAC::AuthContext.system)
      app_id = result.as(Facet::Document::Create::Result).projection.id

      created = Facet::IAM::ApiKey.generate(db, account_id, "iam.Roles.admin", "app-key", nil, app_id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil

      # A disabled app's key is dead — same gate the OAuth branch enforces.
      upd = Facet::Document::Update.call(db, "app", "App", app_id,
        %({"status": "disabled"}), Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil

      # A deleted app's key is dead too.
      db.exec("UPDATE projections SET deleted_at = now() WHERE id = $1", app_id)
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "dies when the pinned role is unassigned from the account or the role document is deleted" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil

      # Role removed from the account.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{roles}', '[]'::jsonb) WHERE id = $1", account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil

      # Role document deleted.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{roles}', '[\"iam.Roles.admin\"]'::jsonb) WHERE id = $1", account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil
      db.exec("UPDATE projections SET deleted_at = now() WHERE id = 'iam.Roles.admin'")
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "dies when the pinned role's connectivity drops the api channel" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil

      # Flip the role down to browser-only. Verify is uncached, so every
      # key pinned to the role dies on its next use — derive, never mark.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.admin' AND deleted_at IS NULL")
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "fails closed when the pinned role's connectivity is malformed" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil

      # A list that cannot be read carries no channels — the key is dead.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '\"api\"'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.admin' AND deleted_at IS NULL")
      Facet::IAM::ApiKey.verify(db, created.key).should be_nil
    end
  end

  it "throttles last_used_at to one write per minute" do
    with_db do |db|
      account_id = create_test_account(db)
      created = gen_key(db, account_id)

      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil
      first_touch = db.query_one("SELECT last_used_at FROM api_keys WHERE id = $1", created.id, as: Time?)

      # A second verify inside the throttle window must not write.
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil
      second_touch = db.query_one("SELECT last_used_at FROM api_keys WHERE id = $1", created.id, as: Time?)
      second_touch.should eq(first_touch)

      # Backdate past the window — the next verify writes again.
      db.exec("UPDATE api_keys SET last_used_at = now() - interval '2 minutes' WHERE id = $1", created.id)
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil
      third_touch = db.query_one("SELECT last_used_at FROM api_keys WHERE id = $1", created.id, as: Time?)
      third_touch.should_not eq(second_touch)
    end
  end

  it "lists keys without the secret and scopes them to the owner" do
    with_db do |db|
      owner = create_test_account(db, email: "keys-owner@example.com")
      other = create_test_account(db, email: "keys-other@example.com")
      created = gen_key(db, owner, name: "deploy")
      gen_key(db, other, name: "foreign")

      rows = Facet::IAM::ApiKey.list(db, owner)
      rows.size.should eq(1)
      rows.first.id.should eq(created.id)
      rows.first.name.should eq("deploy")
      rows.first.display_prefix.should eq(created.display_prefix)
      rows.first.display_prefix.starts_with?(PREFIX).should be_true

      # Ownership gate: another account cannot see or revoke the key.
      Facet::IAM::ApiKey.find_owned(db, other, created.id).should be_nil
      Facet::IAM::ApiKey.revoke(db, other, created.id).should be_false
      Facet::IAM::ApiKey.verify(db, created.key).should_not be_nil
    end
  end

  it "refuses password login for a service account" do
    with_db do |db|
      account_id = create_test_account(db, email: "svc@example.com", password: "pw-pw-pw")
      db.exec("UPDATE projections SET content = jsonb_set(content, '{service_account}', 'true'::jsonb) WHERE id = $1", account_id)

      result = Facet::IAM::Login.call(db, email: "svc@example.com", password: "pw-pw-pw", cookie: false)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.status.should eq(403)
      error.message.should contain("Service accounts")
    end
  end
end

describe "IAM::ApiKey — HTTP surface" do
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
    with_db { |db| seed_iam_doctypes(db) }
  end

  it "creates a key, shows it once, and the key itself authenticates the list route" do
    with_db do |db|
      create_test_account(db, email: "keys-flow@example.com", password: "pw-pw-pw")
      token = login_token("keys-flow@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "iam.Roles.admin"})))
      assert_http_status(resp, 201)

      created = JSON.parse(resp.body)
      raw_key = created["key"].as_s
      raw_key.starts_with?(PREFIX).should be_true
      raw_key.size.should eq(30)
      created["display_prefix"].as_s.should eq(raw_key[0, 10])
      created["id"].as_s.should_not be_empty

      # The raw key works as a Bearer credential on a protected route —
      # the AuthHandler fct_ branch builds the same auth context.
      key_headers = bearer_headers(raw_key)

      list_resp = call_api(HTTP::Request.new("GET", "/Api/iam/keys", headers: key_headers))
      assert_http_status(list_resp, 200)
      rows = JSON.parse(list_resp.body).as_a
      rows.size.should eq(1)
      rows.first["name"].as_s.should eq("ci")
      rows.first["display_prefix"].as_s.should eq(created["display_prefix"].as_s)
      rows.first["revoked_at"].raw.nil?.should be_true

      # A malformed key is a bare 401.

      bad = call_api(HTTP::Request.new("GET", "/Api/iam/keys",

        headers: bearer_headers("#{PREFIX}#{"A" * 26}")))

      assert_http_status(bad, 401)
    end
  end

  it "rejects a role that is not assigned to the caller (422)" do
    with_db do |db|
      create_test_account(db, email: "keys-role@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      token = login_token("keys-role@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "iam.Roles.admin"})))
      assert_http_status(resp, 422)
      # The reference is well-formed; the caller simply does not hold it.
      JSON.parse(resp.body)["error"].as_s.should contain("is not assigned to this account")
    end
  end

  it "names a non-existent qualified role as missing (422)" do
    with_db do |db|
      # The account must hold the reference to reach the existence check;
      # a role that is assigned but missing from the store exercises it.
      create_test_account(db, email: "keys-missing@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.admin", "iam.Roles.nope"], default_role: "iam.Roles.admin")
      token = login_token("keys-missing@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "iam.Roles.nope"})))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("does not exist")
    end
  end

  it "rejects a bare role name with the qualified-reference requirement (B-326)" do
    with_db do |db|
      create_test_account(db, email: "keys-bare@example.com", password: "pw-pw-pw")
      token = login_token("keys-bare@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "admin"})))
      assert_http_status(resp, 422)
      # The message names the real requirement — the qualified reference —
      # not the assignment (the caller holds the role).
      JSON.parse(resp.body)["error"].as_s.should contain("fully-qualified role reference")
    end
  end

  it "rejects a role whose connectivity excludes the api channel (422)" do
    with_db do |db|
      create_test_account(db, email: "keys-channel@example.com", password: "pw-pw-pw")
      # Strip every channel from the role the caller would pin — the route
      # refuses before the key row exists, with the same 422 shape.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.admin' AND deleted_at IS NULL")
      token = login_token("keys-channel@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "iam.Roles.admin"})))
      assert_http_status(resp, 422)
    end
  end

  it "answers 422 when a required body field is missing or not a string" do
    with_db do |db|
      create_test_account(db, email: "keys-type@example.com", password: "pw-pw-pw")
      token = login_token("keys-type@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"

      missing = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"role": "iam.Roles.admin"})))
      assert_http_status(missing, 422)
      JSON.parse(missing.body)["error"].as_s.should contain("Missing 'name' field")

      non_string = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": 123, "role": "iam.Roles.admin"})))
      assert_http_status(non_string, 422)
      JSON.parse(non_string.body)["error"].as_s.should contain("Missing 'name' field")
    end
  end

  it "rejects a past or invalid expires_at (422)" do
    with_db do |db|
      create_test_account(db, email: "keys-exp@example.com", password: "pw-pw-pw")
      token = login_token("keys-exp@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      past = call_api(HTTP::Request.new("POST", "/Api/iam/keys", headers: headers,
        body: %({"name": "ci", "role": "iam.Roles.admin", "expires_at": "2020-01-01T00:00:00Z"})))
      assert_http_status(past, 422)

      garbage = call_api(HTTP::Request.new("POST", "/Api/iam/keys", headers: headers,
        body: %({"name": "ci", "role": "iam.Roles.admin", "expires_at": "not-a-date"})))
      assert_http_status(garbage, 422)
    end
  end

  it "skips the CSRF header for API-key callers but requires it for cookie sessions" do
    with_db do |db|
      create_test_account(db, email: "keys-csrf@example.com", password: "pw-pw-pw")
      token = login_token("keys-csrf@example.com", "pw-pw-pw")

      # First key: session Bearer + CSRF header (existing convention).

      session_headers = bearer_headers(token)
      session_headers["X-Requested-With"] = "XMLHttpRequest"
      session_headers["Content-Type"] = "application/json"
      first = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: session_headers, body: %({"name": "ci", "role": "iam.Roles.admin"})))
      assert_http_status(first, 201)
      raw_key = JSON.parse(first.body)["key"].as_s

      # Second key: API-key Bearer only, no CSRF header — skipped. The
      # non-ambient exemption covers every Bearer credential without a
      # session cookie, static API keys included.

      key_headers = bearer_headers(raw_key)
      key_headers["Content-Type"] = "application/json"
      second = call_api_raw(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: key_headers, body: %({"name": "ci-2", "role": "iam.Roles.admin"})))
      assert_http_status(second, 201)

      # Cookie session without the header stays CSRF-checked: the cookie
      # is the ambient credential the defense exists for. Raw dispatch —
      # `call_api` would add the browser default header.
      cookie_headers = HTTP::Headers{
        "Cookie"       => "auth_token=#{token}",
        "Content-Type" => "application/json",
      }
      cookie_resp = call_api_raw(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: cookie_headers, body: %({"name": "ci-3", "role": "iam.Roles.admin"})))
      JSON.parse(cookie_resp.body.to_s)["error"]?.to_s.should contain("CSRF")
    end
  end

  it "revokes a key, is idempotent, and the key stops working" do
    with_db do |db|
      create_test_account(db, email: "keys-revoke@example.com", password: "pw-pw-pw")
      token = login_token("keys-revoke@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      headers["Content-Type"] = "application/json"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: headers, body: %({"name": "ci", "role": "iam.Roles.admin"})))
      key_id = JSON.parse(resp.body)["id"].as_s

      delete_resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/keys/#{key_id}", headers: headers))
      assert_http_status(delete_resp, 200)

      # Idempotent second delete.
      again = call_api(HTTP::Request.new("DELETE", "/Api/iam/keys/#{key_id}", headers: headers))
      assert_http_status(again, 200)

      # Revoked key no longer authenticates.

      denied = call_api(HTTP::Request.new("GET", "/Api/iam/keys",

        headers: bearer_headers(JSON.parse(resp.body)["key"].as_s)))

      assert_http_status(denied, 401)

      # A foreign or missing key is a non-disclosing 404.
      foreign = call_api(HTTP::Request.new("DELETE", "/Api/iam/keys/nonexistent", headers: headers))
      assert_http_status(foreign, 404)
    end
  end
end

describe "IAM::ApiKey — mutation provenance" do
  before_each do
    with_db { |db| seed_iam_doctypes(db) }
  end

  it "stamps mutations.api_key on creates and deletes" do
    with_db do |db|
      seed_test_roles(db)
      account_id = create_test_account(db)

      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      key_id = Facet::Util::ScriptHelpers.ulid
      context = Facet::RBAC::AuthContext.api_key(account_id, active_role, key_id)

      result = Facet::Document::Create.call(db, "iam", "Account",
        %({"email": "provenance@example.com", "name": "Provenance", "roles": []}),
        context)
      expect_create_success(result)

      doc_id = result.as(Facet::Document::Create::Result).projection.id
      meta = db.query_one(
        "SELECT api_key FROM mutations WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND action = 'create'",
        doc_id, as: String?)
      meta.should eq(key_id)

      # Delete through the same key context — the tombstone carries the tag.
      Facet::Document::Delete.call(db, "iam", "Account", doc_id, context)
      delete_meta = db.query_one(
        "SELECT api_key FROM mutations WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND action = 'delete'",
        doc_id, as: String?)
      delete_meta.should eq(key_id)
    end
  end

  it "leaves mutations.api_key null for session and system contexts" do
    with_db do |db|
      seed_test_roles(db)
      result = Facet::Document::Create.call(db, "iam", "Account",
        %({"email": "plain@example.com", "name": "Plain", "roles": []}),
        Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_id = result.as(Facet::Document::Create::Result).projection.id
      meta = db.query_one(
        "SELECT api_key FROM mutations WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND action = 'create'",
        doc_id, as: String?)
      meta.should be_nil
    end
  end

  it "fail-closes provenance: api_key_id cannot combine with other channels" do
    role_content = JSON.parse(%({"name": "admin", "permissions": []}))
    active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)

    # api_key + acting_role is rejected.
    expect_raises(ArgumentError) do
      Facet::RBAC::AuthContext.new(
        Facet::RBAC::Principal::Real.new("acct", active_role),
        nil, nil, "iam.Roles.admin", "key_123",
      )
    end

    # api_key + app_grant/app_id is rejected.
    expect_raises(ArgumentError) do
      Facet::RBAC::AuthContext.new(
        Facet::RBAC::Principal::Real.new("acct", active_role),
        nil, "app_123", nil, "key_123",
      )
    end
  end
end
