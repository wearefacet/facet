# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/token"
require "../../src/oauth/code_store"
# The MCP branch of `Token.call` dispatches through `authorize.cr` →
# `mcp/protected_resource.cr`, which reads `MCP.base_url` — defined in
# `src/mcp.cr`. The full suite pulls it via the MCP specs; a single-file
# run needs it here.
require "../../src/mcp"
require "../support/oauth_helper"

# OAuth token endpoint.
#
# Service-level tests (no HTTP): exercises `OAuth::Token.call` directly.
# Brief's acceptance:
# - Happy path: code + verifier yields an app JWT (`typ: "app"`).
# - Code replay fails (`invalid_grant`).
# - Wrong verifier fails (`invalid_grant`).
# - Mismatched `redirect_uri` at token fails (`invalid_grant`).
# - `client_id` mismatch at token fails (`invalid_grant`).
# - Disabled app between authorize and token fails (`invalid_grant`).
# - Unsupported `grant_type` fails (`unsupported_grant_type`).
#
# Shared builders (`create_test_app`, `create_test_role`, `grant`, `action`,
# `perm`, `make_authorize_params`, `s256_challenge`) live in
# `spec/support/oauth_helper.cr`.

describe "OAuth::Token" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "issues an app JWT on the happy path" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: "st")
      issued_code = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      result = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: "https://app.example.com/cb",
        code_verifier: verifier,
        client_id: client_id,
      )

      result.token_type.should eq("Bearer")
      result.expires_in.should be > 0
      result.access_token.should_not be_empty

      # JWT claims carry the user, the elected role, the app, and `typ: "app"`.
      decoded = Facet::IAM::JWT.decode(result.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["sub"].as_s.should eq(account_id)
      decoded.payload["role"].as_s.should eq("iam.Roles.reader")
      decoded.payload["typ"].as_s.should eq("app")
      decoded.payload["app"]?.should_not be_nil
      decoded.payload["sid"]?.should_not be_nil
    end
  end

  it "answers 400 invalid_request — not a 500 — when a required parameter is missing (B-24)" do
    with_db do |db|
      # Every required parameter of the authorization_code grant, one at a
      # time. The raise escapes as the module's own `Token::Error` (400),
      # never the base `EndpointError` that used to bypass the route's
      # rescue and surface as `500 {"error": "Missing 'client_id'"}`.
      ex = expect_raises(Facet::OAuth::Token::Error, /Missing 'client_id'/) do
        Facet::OAuth::Token.call(db, grant_type: "authorization_code", code: "x", redirect_uri: "x", code_verifier: "x", client_id: nil)
      end
      ex.error_code.should eq("invalid_request")
      ex.status.should eq(400)

      ex2 = expect_raises(Facet::OAuth::Token::Error, /Missing 'client_id'/) do
        Facet::OAuth::Token.call(db, grant_type: "authorization_code", code: "x", redirect_uri: "x", code_verifier: "x", client_id: "")
      end
      ex2.status.should eq(400)

      ex3 = expect_raises(Facet::OAuth::Token::Error, /Missing 'code'/) do
        Facet::OAuth::Token.call(db, grant_type: "authorization_code", code: nil, redirect_uri: "x", code_verifier: "x", client_id: "x")
      end
      ex3.status.should eq(400)

      ex4 = expect_raises(Facet::OAuth::Token::Error, /Missing 'redirect_uri'/) do
        Facet::OAuth::Token.call(db, grant_type: "authorization_code", code: "x", redirect_uri: nil, code_verifier: "x", client_id: "x")
      end
      ex4.status.should eq(400)

      ex5 = expect_raises(Facet::OAuth::Token::Error, /Missing 'code_verifier'/) do
        Facet::OAuth::Token.call(db, grant_type: "authorization_code", code: "x", redirect_uri: "x", code_verifier: nil, client_id: "x")
      end
      ex5.status.should eq(400)
    end
  end

  it "rejects code replay with invalid_grant" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_one"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      call_args = ->(ver : String) {
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: ver, client_id: client_id)
      }
      # First redemption succeeds; the code is consumed atomically.
      call_args.call(verifier).access_token.should_not be_empty

      # Second redemption must fail — the code no longer exists in the store.
      ex = expect_raises(Facet::OAuth::Token::Error) { call_args.call(verifier) }
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "rejects wrong verifier with invalid_grant" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_correct"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: "verifier_wrong", client_id: client_id)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "rejects a redirect_uri mismatch at token with invalid_grant" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_redirect"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://attacker.example.com/cb",
          code_verifier: verifier, client_id: client_id)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "rejects a client_id mismatch at token with invalid_grant" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_client"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: "client_someone_else")
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "rejects unsupported grant_type" do
    with_db do |db|
      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "refresh_token", code: "c", redirect_uri: "u",
          code_verifier: "v", client_id: "cid")
      end
      ex.error_code.should eq("unsupported_grant_type")
    end
  end

  it "rejects a disabled app at token time" do
    with_db do |db|
      app_id, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_disable"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      # Disable the app between authorize and token. `Document::Update.call`
      # merges the patch over the existing projection (running the app.App
      # `update` Lua hook that enforces `slug` / `client_id` immutability).
      Facet::Document::Update.call(
        db, "app", "App", app_id,
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: client_id)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "rejects when the elected role is no longer usable after a grant change" do
    with_db do |db|
      app_id, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_widen"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      # Narrow the grant post-authorize so the role no longer satisfies the
      # required action — `role_usable?` returns false at token time. The
      # patch replaces `grants` wholesale (Document::Update merges over the
      # projection content but the new field overwrites the old).
      narrowed_json = [oauth_grant("hr.Employee", [oauth_action("read", required: true)])].to_json
      Facet::Document::Update.call(
        db, "app", "App", app_id,
        %({"grants": #{narrowed_json}}),
        Facet::RBAC::AuthContext.system,
      )

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: client_id)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  # B-270: `grants` is optional on `app.App`. At token time the shared helper
  # must answer `[]` for an app whose content has no `grants` key — the same
  # answer it gives for `grants: []` — instead of failing on the SQL NULL
  # column.
  it "treats a missing grants key exactly like grants: [] at token time (B-270)" do
    with_db do |db|
      _, control_client = create_test_app(db, "grants-empty")
      missing_id, missing_client = create_test_app(db, "grants-absent")
      db.exec(
        "UPDATE projections SET content = content - 'grants' " \
        "WHERE id = $1 AND deleted_at IS NULL",
        missing_id,
      )
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_no_grants_key"
      challenge = s256_challenge(verifier)

      # Control: an empty grants array resolves an empty effective scope, so
      # the redemption answers invalid_grant (400).
      control_code = Facet::OAuth::Authorize.issue_code(db, account_id,
        make_authorize_params(control_client, "https://app.example.com/cb",
          code_challenge: challenge, state: nil), "iam.Roles.reader")
      ex_control = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: control_code.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: control_client)
      end
      ex_control.error_code.should eq("invalid_grant")
      ex_control.status.should eq(400)

      # The missing-key app must answer the same way — never a 500.
      missing_code = Facet::OAuth::Authorize.issue_code(db, account_id,
        make_authorize_params(missing_client, "https://app.example.com/cb",
          code_challenge: challenge, state: nil), "iam.Roles.reader")
      ex_missing = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: missing_code.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: missing_client)
      end
      ex_missing.error_code.should eq("invalid_grant")
      ex_missing.status.should eq(400)
    end
  end

  it "does not consume the code when the DPoP proof fails — the same code exchanges after a corrected proof (B-55)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_dpop_recover"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      htu = "https://localhost:3000/OAuth/token"
      pair = dpop_key_pair

      # First attempt: the proof names a different URL — the `htu` claim
      # fails (`invalid_claim`) and the code must survive the failure.
      wrong_proof = sign_dpop_proof(pair, htm: "POST", htu: "https://attacker.example.com/OAuth/token")
      ex = expect_raises(Facet::OAuth::Token::Error, /htu mismatch/) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: client_id,
          dpop_proof: wrong_proof, htu: htu)
      end
      ex.error_code.should eq("invalid_claim")
      ex.status.should eq(400)

      # Retry with the same code and a correct proof — the exchange
      # succeeds and the token is DPoP-bound to the proof's key.
      good_proof = sign_dpop_proof(pair, htm: "POST", htu: htu)
      result = Facet::OAuth::Token.call(db,
        grant_type: "authorization_code", code: issued.code,
        redirect_uri: "https://app.example.com/cb",
        code_verifier: verifier, client_id: client_id,
        dpop_proof: good_proof, htu: htu)
      result.token_type.should eq("DPoP")

      decoded = Facet::IAM::JWT.decode(result.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["cnf"].as_h["jkt"].as_s.should eq(pair.jkt)
    end
  end

  it "does not consume an MCP resource-bound code when the DPoP proof fails — the same code exchanges after a corrected proof (B-55)" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      resource = Facet::MCP.resource_identifier("iam.Roles.editor")
      verifier = "verifier_mcp_recover"
      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client",
        redirect_uri: "http://localhost:4004/callback",
        state: nil,
        code_challenge: s256_challenge(verifier),
        code_challenge_method: "S256",
        scope: nil,
        resource: resource,
      )
      issued = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")

      htu = "https://localhost:3000/OAuth/token"
      pair = dpop_key_pair

      wrong_proof = sign_dpop_proof(pair, htm: "POST", htu: "https://attacker.example.com/OAuth/token")
      ex = expect_raises(Facet::OAuth::Token::Error, /htu mismatch/) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "http://localhost:4004/callback",
          code_verifier: verifier, client_id: "mcp-client",
          dpop_proof: wrong_proof, htu: htu)
      end
      ex.error_code.should eq("invalid_claim")

      good_proof = sign_dpop_proof(pair, htm: "POST", htu: htu)
      result = Facet::OAuth::Token.call(db,
        grant_type: "authorization_code", code: issued.code,
        redirect_uri: "http://localhost:4004/callback",
        code_verifier: verifier, client_id: "mcp-client",
        dpop_proof: good_proof, htu: htu)
      result.token_type.should eq("DPoP")

      # The MCP access token carries `aud` = resource; the threaded
      # thumbprint lands on the session (the MCP payload itself carries no
      # `cnf` claim).
      decoded = Facet::IAM::JWT.decode(result.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["aud"].as_s.should eq(resource)
      session_id = result.refresh_token.split('.', 2)[0]
      loaded = Facet::IAM::RedisSession.load(session_id).not_nil!
      loaded.dpop_jkt.should eq(pair.jkt)
    end
  end

  it "marks the proof at the hoisted verification — a reused jti on a later exchange fails as a replay (B-55)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_dpop_replay"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)

      htu = "https://localhost:3000/OAuth/token"
      pair = dpop_key_pair
      proof = sign_dpop_proof(pair, htm: "POST", htu: htu)

      exchange = ->(code : String) {
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: client_id,
          dpop_proof: proof, htu: htu)
      }

      # The first exchange consumes its code with the proof; the hoisted
      # verification marks `(jkt, jti)` in the replay cache.
      issued1 = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")
      exchange.call(issued1.code).token_type.should eq("DPoP")

      # A second exchange reusing the same proof (same `jti`) fails as a
      # replay — the hoisted pass is the only verification, and it registers.
      issued2 = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")
      ex = expect_raises(Facet::OAuth::Token::Error, /replay/) do
        exchange.call(issued2.code)
      end
      ex.error_code.should eq("invalid_dpop_proof")
    end
  end

  it "answers 500 when a proof is presented but the caller provides no htu (contract unchanged, B-55)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      verifier = "verifier_no_htu"
      challenge = s256_challenge(verifier)
      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: challenge, state: nil)
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      # A caller contract violation — the route always reconstructs `htu`,
      # so a missing one is a 500, not an RFC 6749 error. With the B-55
      # hoist the check now runs before the code is looked up.
      pair = dpop_key_pair
      proof = sign_dpop_proof(pair, htm: "POST", htu: "https://localhost:3000/OAuth/token")
      ex = expect_raises(Facet::OAuth::Token::Error, /htu not provided/) do
        Facet::OAuth::Token.call(db,
          grant_type: "authorization_code", code: issued.code,
          redirect_uri: "https://app.example.com/cb",
          code_verifier: verifier, client_id: client_id,
          dpop_proof: proof, htu: nil)
      end
      ex.status.should eq(500)
    end
  end
end
