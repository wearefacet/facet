# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::Login do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "logs in with valid credentials (no MFA)" do
    with_db do |db|
      account_id = create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.account_id.should eq(account_id)
      token_result.active_role.should eq("iam.Roles.admin")
      token_result.available_roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
      token_result.access_token.should_not be_empty
      token_result.refresh_token.should_not be_empty
      token_result.cookie.should be_false

      # Verify a LoginEvent was written
      events = db.query_all(
        "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
        as: JSON::Any
      )
      events.any? { |e| e["event"]?.try(&.as_s) == "login" }.should be_true
    end
  end

  it "logs in with explicit role" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        role: "iam.Roles.editor",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.active_role.should eq("iam.Roles.editor")
    end
  end

  it "rejects invalid credentials with generic error" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "wrong-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Invalid credentials")
    end
  end

  it "rejects unknown email with generic error" do
    with_db do |db|
      result = Facet::IAM::Login.call(
        db,
        email: "unknown@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Invalid credentials")
    end
  end

  it "rejects login for suspended account" do
    with_db do |db|
      create_test_account(db, status: "suspended")

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("Account is suspended")
    end
  end

  it "rejects login for disabled account" do
    with_db do |db|
      create_test_account(db, status: "disabled")

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("Account is disabled")
    end
  end

  it "allows a pending account to log in with a correct password" do
    with_db do |db|
      account_id = create_test_account(db, status: "pending")

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      # Proceeds past pre_auth_checks — the invited account reaches the
      # normal token emission path.
      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.account_id.should eq(account_id)
    end
  end

  it "flips a pending account to active when tokens are emitted" do
    with_db do |db|
      account_id = create_test_account(db, status: "pending")

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )
      result.should be_a(Facet::IAM::Login::TokensEmitted)

      status = db.query_one(
        "SELECT content->>'status' FROM projections WHERE id = $1",
        account_id, as: String
      )
      status.should eq("active")
    end
  end

  it "routes a pending account with must_change_pw into the password bootstrap" do
    with_db do |db|
      account_id = create_test_account(db, status: "pending")
      Facet::IAM::AccountPatch.call(db, account_id,
        {"must_change_pw" => JSON::Any.new(true)})

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::PasswordChangeRequired)
    end
  end

  it "logs in a roleless account under the anonymous role (B-120)" do
    with_db do |db|
      # The anonymous role is a production seed; the lighter `seed_test_roles`
      # does not create it, so seed the full role set first.
      ensure_seed_roles_with_dependencies(db)
      create_test_account(db, roles: [] of String, default_role: nil)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.active_role.should eq(Facet::IAM::ANONYMOUS_ROLE_ID)
      token_result.available_roles.should be_empty
    end
  end

  it "rejects a roleless account that explicitly elects a role (B-120)" do
    with_db do |db|
      ensure_seed_roles_with_dependencies(db)
      create_test_account(db, roles: [] of String, default_role: nil)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        role: "iam.Roles.editor",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("No role assigned")
    end
  end

  it "logs in and creates a Redis session" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result

      # Verify session exists in Redis
      session = Facet::IAM::RedisSession.load(token_result.session_id)
      session.should_not be_nil
      session.try(&.account_id).should eq(token_result.account_id)
      session.try(&.active_role).should eq("iam.Roles.admin")
    end
  end

  it "handles email case-insensitively" do
    with_db do |db|
      create_test_account(db, email: "MixedCase@Example.COM")

      result = Facet::IAM::Login.call(
        db,
        email: "mixedcase@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
    end
  end

  it "rejects login when locked out" do
    with_db do |db|
      account_id = create_test_account(db)

      Facet::IAM::LoginThrottle.set_lockout(account_id)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(429)
      err.message.should eq("Too many attempts. Try again later.")
    end
  end

  it "rejects login after max password attempts" do
    with_db do |db|
      account_id = create_test_account(db)

      Facet::IAM::Login::MAX_PWD_ATTEMPTS.times do
        result = Facet::IAM::Login.call(
          db,
          email: "test@example.com",
          password: "wrong-password",
          cookie: false,
        )
        result.should be_a(Facet::ServiceError)
      end

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "wrong-password",
        cookie: false,
      )
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(429)
      err.message.should eq("Too many attempts. Try again later.")

      Facet::IAM::LoginThrottle.locked_out?(account_id).should be_true
    end
  end

  it "increments per-IP attempt counter on password failure" do
    with_db do |db|
      test_ip = "10.0.0.#{rand(200..254)}"
      # Create accounts with different emails so find_account_by_email doesn't
      # return multiple rows, but all share the same source IP for counting
      emails = ["ip-test-a@example.com", "ip-test-b@example.com", "ip-test-c@example.com"]
      emails.each { |em| create_test_account(db, email: em) }

      # Failed attempts from the same IP across different users
      3.times do |i|
        result = Facet::IAM::Login.call(
          db,
          email: emails[i],
          password: "wrong-password",
          cookie: false,
          ip: test_ip,
        )
        result.should be_a(Facet::ServiceError)
      end

      Facet::IAM::LoginThrottle.get_ip_attempts(test_ip).should eq(3)
    end
  end

  it "writes lockout event when password threshold is breached" do
    with_db do |db|
      create_test_account(db)

      Facet::IAM::Login::MAX_PWD_ATTEMPTS.times do
        Facet::IAM::Login.call(
          db,
          email: "test@example.com",
          password: "wrong-password",
          cookie: false,
        )
      end

      Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "wrong-password",
        cookie: false,
      )

      events = db.query_all(
        "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
        as: JSON::Any
      )
      events.any? { |e| e["event"]?.try(&.as_s) == "lockout" }.should be_true
    end
  end

  it "rejects login when the password slot is missing" do
    with_db do |db|
      doc_id = Facet::Util::ScriptHelpers.ulid
      content = {
        "email"        => "test@example.com",
        "name"         => "Test User",
        "status"       => "active",
        "roles"        => ["iam.Roles.admin"],
        "default_role" => "iam.Roles.admin",
        "mfa_enabled"  => false,
      }.to_json

      Facet::Mutation::Client.create(
        db,
        "iam",
        "Account",
        doc_id: doc_id,
        content: content,
        actioner_id: "system",
      )

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Invalid credentials")
    end
  end

  it "increments attempt counters on password failure" do
    with_db do |db|
      account_id = create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "wrong-password",
        cookie: false,
        ip: "10.0.0.1",
      )

      result.should be_a(Facet::ServiceError)

      Facet::IAM::LoginThrottle.get_pwd_attempts(account_id).should eq(1)
      Facet::IAM::LoginThrottle.get_ip_attempts("10.0.0.1").should eq(1)
    end
  end

  it "resets attempt counters on successful login" do
    with_db do |db|
      account_id = create_test_account(db)

      3.times do
        Facet::IAM::Login.call(
          db,
          email: "test@example.com",
          password: "wrong-password",
          cookie: false,
          ip: "10.0.0.1",
        )
      end

      Facet::IAM::LoginThrottle.get_pwd_attempts(account_id).should be > 0
      Facet::IAM::LoginThrottle.get_ip_attempts("10.0.0.1").should be > 0

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
        ip: "10.0.0.1",
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)

      Facet::IAM::LoginThrottle.get_pwd_attempts(account_id).should eq(0)
      Facet::IAM::LoginThrottle.get_ip_attempts("10.0.0.1").should eq(0)
    end
  end

  it "logs in with a role created through the generic document API (B-28)" do
    with_db do |db|
      # The IT-manager flow from the finding: create the role through the
      # document create service (the API path), assign it, log in. The
      # projection id must be the named form `iam.Roles.<name>` — the same
      # shape the seeds and the portable bundles use — so login, refresh,
      # and every per-request role load resolve it.
      seed_test_roles(db)
      unless db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Roles' AND deleted_at IS NULL", as: Int32)
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      end
      role_result = Facet::Document::Create.call(
        db, "iam", "Roles",
        %({"name": "field_tech", "level": 20, "description": "Field technicians", "visible_tags": ["default"], "permissions": [{"action": "read", "on": "*.*"}]}),
        Facet::RBAC::AuthContext.system,
      )
      role_result.should be_a(Facet::Document::Create::Result)
      role_id = role_result.as(Facet::Document::Create::Result).projection.id
      role_id.should eq("iam.Roles.field_tech")
      role_id.should_not match(/^[0-9A-HJKMNP-TV-Z]{26}$/)

      create_test_account(db, roles: [role_id], default_role: role_id)

      # Default election.
      result = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
      result.should be_a(Facet::IAM::Login::TokensEmitted)
      result.as(Facet::IAM::Login::TokensEmitted).result.active_role.should eq("iam.Roles.field_tech")

      # Explicit election, both spellings resolve to the same id.
      explicit = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", role: role_id, cookie: false)
      explicit.should be_a(Facet::IAM::Login::TokensEmitted)

      # The role content is reachable through the same funnel every
      # request-path role load uses.
      Facet::IAM::Helpers.find_role_content(db, role_id).should_not be_nil
    end
  end

  it "answers 422 when a role name is already taken (B-28; the name field is unique)" do
    with_db do |db|
      seed_test_roles(db)
      unless db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Roles' AND deleted_at IS NULL", as: Int32)
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      end
      first = Facet::Document::Create.call(
        db, "iam", "Roles",
        %({"name": "dispatcher", "level": 20, "permissions": []}),
        Facet::RBAC::AuthContext.system,
      )
      first.should be_a(Facet::Document::Create::Result)
      first.as(Facet::Document::Create::Result).projection.id.should eq("iam.Roles.dispatcher")

      # The `name` field is `unique: true` — the uniqueness validation
      # fires before the id derivation and answers the 422 detail naming
      # the value; the projection id never collides.
      second = Facet::Document::Create.call(
        db, "iam", "Roles",
        %({"name": "dispatcher", "level": 20, "permissions": []}),
        Facet::RBAC::AuthContext.system,
      )
      second.should be_a(Facet::ServiceError)
      err = second.as(Facet::ServiceError)
      err.status.should eq(422)
      # The detail names the failing field and the reason; the top-level
      # message is the generic validation failure.
      detail = err.details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).message.should contain("unique")
      detail.as(Facet::ValidationError).field.should eq("name")
    end
  end

  it "rejects login with explicit role not assigned to the account" do
    with_db do |db|
      create_test_account(db, roles: ["iam.Roles.admin"])

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        role: "iam.Roles.editor",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      # The account holds a role — the elected one is just not among
      # them, so the message names the election instead of the generic
      # no-roles shape (B-28).
      err.message.should eq("Role 'iam.Roles.editor' is not assigned to this account")
    end
  end

  it "rejects login when role document is missing" do
    with_db do |db|
      doc_id = Facet::Util::ScriptHelpers.ulid
      content = {
        "email"        => "test@example.com",
        "name"         => "Test User",
        "status"       => "active",
        "roles"        => ["iam.Roles.ghost_role"],
        "default_role" => "iam.Roles.ghost_role",
        "mfa_enabled"  => false,
      }.to_json

      Facet::Mutation::Client.create(
        db,
        "iam",
        "Account",
        doc_id: doc_id,
        content: content,
        actioner_id: "system",
      )

      Facet::Secrets.set(db, "iam.Account.#{doc_id}", "password", "test-password",
        mode: "hash", set_by: "system")

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("Role not found or disabled")
    end
  end

  it "returns MFARequired when the account has MFA enabled" do
    with_db do |db|
      account_id = create_test_account(db, mfa_enabled: true)
      doc_ref = "iam.Account.#{account_id}"

      Facet::Secrets.set(db, doc_ref, "mfa", "TEST",
        mode: "sealed", set_by: "system", meta: {"mfa_type" => "totp"})
      Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, 0_i64)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::MFARequired)
      mfa = result.as(Facet::IAM::Login::MFARequired)
      mfa.challenge_id.should_not be_empty
    end
  end

  it "logs in with cookie mode" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: true,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.cookie.should be_true
    end
  end

  it "passes user_agent and ip metadata to session" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        user_agent: "TestAgent/1.0",
        ip: "10.0.0.1",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result

      session = Facet::IAM::RedisSession.load(token_result.session_id)
      session.should_not be_nil
      session.try(&.user_agent).should eq("TestAgent/1.0")
      session.try(&.ip).should eq("10.0.0.1")
    end
  end

  it "includes permission manifest in result" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::TokensEmitted)
      token_result = result.as(Facet::IAM::Login::TokensEmitted).result
      token_result.permissions.should_not be_nil
      token_result.permissions.should be_a(Hash(String, Array(String)))
      token_result.permissions.should eq({"*.*" => ["*"], "iam.Account" => ["mfa_disable"]})
    end
  end

  it "returns PasswordChangeRequired with a one-shot change_token when must_change_pw is true" do
    with_db do |db|
      account_id = create_test_account(db)
      # Flip the must_change_pw flag on the account document
      # (create_test_account uses the default).
      Facet::IAM::AccountPatch.call(db, account_id,
        {"must_change_pw" => JSON::Any.new(true)})

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )

      result.should be_a(Facet::IAM::Login::PasswordChangeRequired)
      change = result.as(Facet::IAM::Login::PasswordChangeRequired)
      change.change_token.should_not be_empty

      # Token should be present in Redis and consumable (multi-attempt — the
      # user may mistype the new password, so the bootstrap token allows
      # several attempts before being exhausted).
      account_id_from_token = Facet::IAM::PwdChangeToken.consume_pwd_change_token(change.change_token)
      account_id_from_token.should eq(account_id)

      # Subsequent consume should still return the account_id (attempts are not yet exhausted).
      second_consume = Facet::IAM::PwdChangeToken.consume_pwd_change_token(change.change_token)
      second_consume.should eq(account_id)
    end
  end

  it "skips per-IP attempt increment when ip is nil" do
    with_db do |db|
      create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "wrong-password",
        cookie: false,
        ip: nil,
      )

      result.should be_a(Facet::ServiceError)

      # No "unknown" IP bucket should have been populated.
      Facet::IAM::LoginThrottle.get_ip_attempts("unknown").should eq(0)
    end
  end
end
