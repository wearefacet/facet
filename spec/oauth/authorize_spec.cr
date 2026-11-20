# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam"
require "../../src/document"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/app_helper"

HTTPTest.init

# Authorize service.
#
# Service-level tests (no HTTP): exercises `Authorize.build_consent` and
# `Authorize.issue_code` directly with constructed `AuthContext`, role, and
# `AppScope`. Covers:
# - Zero usable roles → `access_denied`.
# - One usable role → consent payload with that single role.
# - Multiple usable roles → consent payload with the picker.
# - `redirect_uri` mismatch → `InvalidRequest` (never redirected).
# - `code_challenge_method` must be S256; `plain` rejected.
#
# HTTP integration (full flow) lives in `oauth_flow_spec.cr`. Shared test
# builders (`create_test_app`, `create_test_role`, `grant`, `action`, `perm`,
# `make_authorize_params`, `s256_challenge`) live in `spec/support/oauth_helper.cr`.
#
# The `HTTP endpoint errors` block drives the route handlers through the
# Kemal chain: a missing required parameter must answer the RFC 6749 error
# body (400 `invalid_request`), never a 500 — the authorize handlers rescue
# the shared `EndpointError` base (B-151).

describe "OAuth::Authorize" do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  describe "parse_params" do
    it "accepts a well-formed S256 request" do
      p = make_authorize_params("client_1", "https://app.example.com/cb")
      p.client_id.should eq("client_1")
      p.redirect_uri.should eq("https://app.example.com/cb")
      p.state.should eq("state_xyz")
      p.code_challenge.should eq("challenge_abc")
      p.scope.should be_nil
    end

    it "rejects missing client_id" do
      expect_raises(Facet::OAuth::EndpointError) do
        Facet::OAuth::Authorize.parse_params(
          client_id: nil, redirect_uri: "https://cb/",
          state: nil, code_challenge: "c", code_challenge_method: "S256", scope: nil,
        )
      end
    end

    it "rejects missing redirect_uri" do
      expect_raises(Facet::OAuth::EndpointError) do
        Facet::OAuth::Authorize.parse_params(
          client_id: "cid", redirect_uri: nil,
          state: nil, code_challenge: "c", code_challenge_method: "S256", scope: nil,
        )
      end
    end

    it "rejects missing code_challenge" do
      expect_raises(Facet::OAuth::EndpointError) do
        Facet::OAuth::Authorize.parse_params(
          client_id: "cid", redirect_uri: "https://cb/",
          state: nil, code_challenge: nil, code_challenge_method: "S256", scope: nil,
        )
      end
    end

    it "rejects plain code_challenge_method" do
      expect_raises(Facet::OAuth::EndpointError) do
        Facet::OAuth::Authorize.parse_params(
          client_id: "cid", redirect_uri: "https://cb/",
          state: nil, code_challenge: "c", code_challenge_method: "plain", scope: nil,
        )
      end
    end

    it "rejects missing code_challenge_method" do
      expect_raises(Facet::OAuth::EndpointError) do
        Facet::OAuth::Authorize.parse_params(
          client_id: "cid", redirect_uri: "https://cb/",
          state: nil, code_challenge: "c", code_challenge_method: nil, scope: nil,
        )
      end
    end

    it "treats empty state as nil" do
      p = Facet::OAuth::Authorize.parse_params(
        client_id: "cid", redirect_uri: "https://cb/",
        state: "", code_challenge: "c", code_challenge_method: "S256", scope: nil,
      )
      p.state.should be_nil
    end
  end

  describe "load_app" do
    it "rejects an unknown client_id with InvalidRequest" do
      with_db do |db|
        params = make_authorize_params("unknown_client", "https://app.example.com/cb")
        # B-339 — the description points at the Credentials screen and does
        # not echo the submitted value. B-388 — it also names the MCP branch,
        # where a `register` client without an app.App row is valid.
        ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /Credentials screen/) do
          Facet::OAuth::Authorize.load_app(db, params)
        end
        ex.message.to_s.should contain("document id")
        ex.message.to_s.should contain("MCP branch")
        ex.message.to_s.should_not contain("unknown_client")
      end
    end

    it "rejects redirect_uri mismatch (never redirected)" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app", redirect_uris: ["https://app.example.com/cb"])
        params = make_authorize_params(client_id, "https://attacker.com/cb")
        ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /redirect_uri/) do
          Facet::OAuth::Authorize.load_app(db, params)
        end
        ex.status.should eq(400)
      end
    end

    it "rejects a non-active app" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app", status: "draft")
        params = make_authorize_params(client_id, "https://app.example.com/cb")
        ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /not active/) do
          Facet::OAuth::Authorize.load_app(db, params)
        end
        ex.status.should eq(403)
      end
    end

    it "loads an active app with matching redirect_uri" do
      with_db do |db|
        app_id, client_id = create_test_app(db, "test-app")
        params = make_authorize_params(client_id, "https://app.example.com/cb")
        app = Facet::OAuth::Authorize.load_app(db, params)
        app.id.should eq(app_id)
        app.status.should eq("active")
        app.redirect_uris.should eq(["https://app.example.com/cb"])
      end
    end

    it "loads an app whose registered loopback wildcard matches the presented port" do
      with_db do |db|
        app_id, client_id = create_test_app(db, "cli-app", redirect_uris: ["http://localhost:*"])
        params = make_authorize_params(client_id, "http://localhost:49152/callback")
        app = Facet::OAuth::Authorize.load_app(db, params)
        app.id.should eq(app_id)
      end
    end

    it "rejects a presented URI the loopback wildcard does not cover" do
      with_db do |db|
        _, client_id = create_test_app(db, "cli-app", redirect_uris: ["http://localhost:*"])
        params = make_authorize_params(client_id, "http://127.0.0.1:49152/callback")
        expect_raises(Facet::OAuth::Authorize::InvalidRequest, /redirect_uri/) do
          Facet::OAuth::Authorize.load_app(db, params)
        end
      end
    end
  end

  describe "build_consent" do
    it "returns zero usable roles when the user holds none matching the app's required actions → access_denied via issue_code" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "narrow", [oauth_perm("read", "hr.Employee")])
        account_id = create_test_account(db, roles: ["iam.Roles.narrow"], default_role: "iam.Roles.narrow")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        screen = Facet::OAuth::Authorize.build_consent(db, account_id, params)
        screen.roles.size.should eq(0)

        # And issuing the code with the (only) role the user has yields access_denied.
        expect_raises(Facet::OAuth::Authorize::AccessDenied) do
          Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.narrow")
        end
      end
    end

    it "returns one usable role when exactly one role satisfies the app's required actions" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
        create_test_role(db, "no_match", [oauth_perm("read", "hr.Employee")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.reader", "iam.Roles.no_match"],
          default_role: "iam.Roles.reader")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        screen = Facet::OAuth::Authorize.build_consent(db, account_id, params)
        screen.roles.size.should eq(1)
        screen.roles[0].role_id.should eq("iam.Roles.reader")
        screen.roles[0].effective_scope.empty?.should be_false
      end
    end

    it "returns multiple usable roles (picker) when more than one satisfies the required actions" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "sales", [oauth_perm("read", "crm.Contact")])
        create_test_role(db, "support", [oauth_perm("read", "crm.Ticket"), oauth_perm("read", "crm.Contact")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.sales", "iam.Roles.support"],
          default_role: "iam.Roles.sales")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        screen = Facet::OAuth::Authorize.build_consent(db, account_id, params)
        role_ids = screen.roles.map(&.role_id).sort!
        role_ids.should eq(["iam.Roles.sales", "iam.Roles.support"])
      end
    end
  end

  describe "issue_code" do
    it "issues a single-use code when the elected role is usable" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")
        issued.code.should_not be_empty
        issued.redirect_uri.should eq("https://app.example.com/cb")
        issued.state.should eq("state_xyz")
        issued.role_id.should eq("iam.Roles.reader")
        issued.app_id.should_not be_empty

        # Verifies the code is in the store and consumable once.
        record = Facet::OAuth::CodeStore.consume(issued.code)
        record.should_not be_nil
        record.not_nil!.account_id.should eq(account_id)
        record.not_nil!.role_id.should eq("iam.Roles.reader")

        # Second consume returns nil (single-use).
        Facet::OAuth::CodeStore.consume(issued.code).should be_nil
      end
    end

    it "raises AccessDenied when the elected role is not among the user's assigned roles" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
        create_test_role(db, "admin_role", [oauth_perm("*", "*.*")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        # user holds only `reader`, attempts to elect `admin_role` — denied.
        expect_raises(Facet::OAuth::Authorize::AccessDenied) do
          Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.admin_role")
        end
      end
    end

    it "raises AccessDenied when the elected role is assigned but not usable" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "hr_only", [oauth_perm("read", "hr.Employee")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.hr_only"], default_role: "iam.Roles.hr_only")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        expect_raises(Facet::OAuth::Authorize::AccessDenied) do
          Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.hr_only")
        end
      end
    end

    it "issues for a role whose connectivity excludes every channel (delegated app tokens are never gated)" do
      with_db do |db|
        _, client_id = create_test_app(db, "test-app",
          grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
        create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
        account_id = create_test_account(db,
          roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

        # The connectivity field gates the programmatic channels (mcp,
        # webhook, api, assistant) — not the delegated app branch.
        db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
                "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.reader' AND deleted_at IS NULL")

        params = make_authorize_params(client_id, "https://app.example.com/cb")
        issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")
        issued.role_id.should eq("iam.Roles.reader")
      end
    end
  end

  # B-270: `grants` is optional on `app.App` — a REST-created app may omit
  # the key, and `content->'grants'` is then SQL NULL. The helper must answer
  # `[]` for that case, exactly as it does for `grants: []`.
  describe "missing grants key (B-270)" do
    it "reads a missing grants key as an empty array" do
      with_db do |db|
        app_id, _client_id = create_test_app(db, "grants-absent")
        db.exec(
          "UPDATE projections SET content = content - 'grants' " \
          "WHERE id = $1 AND deleted_at IS NULL",
          app_id,
        )

        Facet::OAuth::Authorize.content_grants_or_empty(db, app_id).should eq("[]")
      end
    end

    it "keeps the empty-Hash (Lua round-trip) tolerance" do
      with_db do |db|
        app_id, _client_id = create_test_app(db, "grants-empty-hash")
        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{grants}', '{}'::jsonb) " \
          "WHERE id = $1 AND deleted_at IS NULL",
          app_id,
        )

        Facet::OAuth::Authorize.content_grants_or_empty(db, app_id).should eq("[]")
      end
    end

    it "treats a missing grants key exactly like grants: [] in build_consent and issue_code" do
      with_db do |db|
        _, control_client = create_test_app(db, "grants-empty")
        missing_id, missing_client = create_test_app(db, "grants-absent-flow")
        db.exec(
          "UPDATE projections SET content = content - 'grants' " \
          "WHERE id = $1 AND deleted_at IS NULL",
          missing_id,
        )
        create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
        account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

        # Consent: the same zero-usable-roles answer an empty grants array gives.
        control_screen = Facet::OAuth::Authorize.build_consent(db, account_id,
          make_authorize_params(control_client, "https://app.example.com/cb"))
        missing_screen = Facet::OAuth::Authorize.build_consent(db, account_id,
          make_authorize_params(missing_client, "https://app.example.com/cb"))
        missing_screen.roles.size.should eq(control_screen.roles.size)

        # Issuance: the role stays usable, the code is issued.
        issued = Facet::OAuth::Authorize.issue_code(db, account_id,
          make_authorize_params(missing_client, "https://app.example.com/cb"), "iam.Roles.reader")
        issued.app_id.should eq(missing_id)
      end
    end
  end

  describe "HTTP endpoint errors (B-151)" do
    before_each { redis_cleanup }
    after_each { redis_cleanup }

    it "POST without code_challenge answers 400 invalid_request" do
      with_db do |db|
        _, client_id = create_test_app(db, "ep-app")
        create_test_account(db, email: "ep-post@example.com", password: "ep-post-pw")
        token = login_token("ep-post@example.com", "ep-post-pw")

        body = URI::Params.encode({
          "response_type" => "code",
          "client_id"     => client_id,
          "redirect_uri"  => "https://app.example.com/cb",
          "role"          => "iam.Roles.viewer",
        })
        resp = call_api(HTTP::Request.new("POST", "/OAuth/authorize",
          headers: with_form_auth(bearer_headers(token)), body: body))
        assert_http_status(resp, 400)
        JSON.parse(resp.body)["error"].as_s.should eq("invalid_request")
        JSON.parse(resp.body)["error_description"].as_s.should contain("code_challenge")
      end
    end

    it "GET (JSON Accept) without client_id answers 400 invalid_request" do
      with_db do |db|
        create_test_account(db, email: "ep-get@example.com", password: "ep-get-pw")
        token = login_token("ep-get@example.com", "ep-get-pw")

        headers = bearer_headers(token)
        headers["Accept"] = "application/json"
        resp = call_api(HTTP::Request.new("GET",
          "/OAuth/authorize?redirect_uri=https://app.example.com/cb&code_challenge=challenge_abc&code_challenge_method=S256",
          headers: headers))
        assert_http_status(resp, 400)
        JSON.parse(resp.body)["error"].as_s.should eq("invalid_request")
        JSON.parse(resp.body)["error_description"].as_s.should contain("client_id")
      end
    end

    it "code_challenge_method=plain still answers 400 invalid_request" do
      with_db do |db|
        _, client_id = create_test_app(db, "ep-plain-app")
        create_test_account(db, email: "ep-plain@example.com", password: "ep-plain-pw")
        token = login_token("ep-plain@example.com", "ep-plain-pw")

        body = URI::Params.encode({
          "response_type"         => "code",
          "client_id"             => client_id,
          "redirect_uri"          => "https://app.example.com/cb",
          "code_challenge"        => "challenge_abc",
          "code_challenge_method" => "plain",
        })
        resp = call_api(HTTP::Request.new("POST", "/OAuth/authorize",
          headers: with_form_auth(bearer_headers(token)), body: body))
        assert_http_status(resp, 400)
        JSON.parse(resp.body)["error"].as_s.should eq("invalid_request")
        JSON.parse(resp.body)["error_description"].as_s.should contain("S256")
      end
    end
  end
end
