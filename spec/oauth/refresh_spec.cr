# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/oauth"
require "../../src/oauth/refresh"
require "../../src/oauth/token"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/iam/redis_session"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/document"
require "../support/oauth_helper"
require "../support/app_helper"

# `OAuth::Refresh` (service-level, no HTTP).
#
# Covers:
# - Refresh rotates and the old token is rejected.
# - Reuse of a consumed refresh token kills the session.
# - Revoking the user's role mid-session causes the next refresh to fail.
# - Disabling the app makes the next refresh fail (the in-flight access token
#   remains valid until its ≤15-min TTL).
# - Live-state revalidation axes: user disabled, role unassigned, role
#   missing, app draft, app disabled, grant narrowed.
# - Refresh never changes the role (no `role` parameter on the call).
# - A refresh presented inside the `REFRESH_FLOOR_S` floor fails with
#   `slow_down` (429) and does not revoke the session.
# - Client binding (B-150): the refresh grant must present the `client_id`
#   the code was exchanged with; a wrong or missing value answers 401 and
#   the session survives.

# Issues an app token via the token endpoint (authorization_code grant) and
# returns `{access_token, refresh_token, app_id, account_id}`. The flow is the
# same the production HTTP path walks; we drive it at the service layer
# (no Kemal) to keep the spec focused on the refresh logic.
def issue_app_token(db, grants, role_perms)
  app_id, client_id = create_test_app(db, "test-app", grants: grants)
  create_test_role(db, "reader", role_perms)
  account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

  verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  challenge = s256_challenge(verifier)
  params = make_authorize_params(client_id, "https://app.example.com/cb",
    code_challenge: challenge, state: "st")
  issued_code = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

  issued = Facet::OAuth::Token.call(
    db,
    grant_type: "authorization_code",
    code: issued_code.code,
    redirect_uri: "https://app.example.com/cb",
    code_verifier: verifier,
    client_id: client_id,
  )
  {app_id: app_id, client_id: client_id, account_id: account_id,
   access_token: issued.access_token, refresh_token: issued.refresh_token}
end

describe "OAuth::Refresh" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "refreshes and rotates the refresh token" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      # The floor requires a backdated stamp — the token was issued just now.
      backdate_refresh_issued_at(ctx[:refresh_token])
      issued = Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])

      issued.token_type.should eq("Bearer")
      issued.expires_in.should be > 0
      issued.access_token.should_not be_empty
      # The new refresh token differs from the presented one.
      issued.refresh_token.should_not eq(ctx[:refresh_token])
      # The access token carries the original `sub`, `role`, `app`, and the
      # same `sid` (session id is preserved across refresh).
      decoded = Facet::IAM::JWT.decode(issued.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["sub"].as_s.should eq(ctx[:account_id])
      decoded.payload["role"].as_s.should eq("iam.Roles.reader")
      decoded.payload["app"].as_s.should eq(ctx[:app_id])
      decoded.payload["typ"].as_s.should eq("app")
      # `sid` survives refresh — it's the same session id.
      original_sid = Facet::IAM::JWT.decode(ctx[:access_token],
        Facet::IAM::TokenEmitter.keys).payload["sid"].as_s
      decoded.payload["sid"].as_s.should eq(original_sid)
    end
  end

  it "rejects a refresh presented inside the refresh floor (slow_down)" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      # No backdate — the token was issued just now, inside the floor. The
      # correct client_id passes the binding check; the floor is what fires.
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("slow_down")
      ex.status.should eq(429)

      # The floor is a pacing guard, not a revocation — the session lives on.
      sid = ctx[:refresh_token].split('.', 2)[0]
      Facet::IAM::RedisSession.load(sid).should_not be_nil
    end
  end

  it "accepts a refresh after the floor (backdated stamp) and rotates" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      backdate_refresh_issued_at(ctx[:refresh_token])
      issued = Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      issued.access_token.should_not be_empty
      issued.refresh_token.should_not eq(ctx[:refresh_token])
    end
  end

  it "rotates and rejects the old refresh id after the grace window" do
    with_zero_grace_window do
      with_db do |db|
        ctx = issue_app_token(db,
          [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
          [oauth_perm("read", "crm.Contact")])

        backdate_refresh_issued_at(ctx[:refresh_token])
        first = Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        # Drive the second refresh with the freshly-rotated id — it must
        # still succeed. Rotation re-stamps the floor, so backdate again.
        backdate_refresh_issued_at(first.refresh_token)
        second_with_new = Facet::OAuth::Refresh.call(db, first.refresh_token, client_id: ctx[:client_id])
        second_with_new.access_token.should_not be_empty

        # The original refresh id now sits in `prev_refresh_id`. With
        # `refresh_grace_window: 0`, presentation of the old id is always
        # `:stale` — the check is `Time.utc - last_used_at <= 0.seconds`, and
        # `last_used_at` is stamped at rotation time, strictly before this
        # check runs. Backdate the floor first — rotation re-stamped it.
        backdate_refresh_issued_at(ctx[:refresh_token])
        ex = expect_raises(Facet::OAuth::Refresh::Error) do
          Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        end
        ex.error_code.should eq("invalid_grant")
      end
    end
  end

  it "reuse of a consumed refresh token kills the session" do
    with_zero_grace_window do
      with_db do |db|
        ctx = issue_app_token(db,
          [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
          [oauth_perm("read", "crm.Contact")])

        # First refresh succeeds and rotates.
        backdate_refresh_issued_at(ctx[:refresh_token])
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])

        # Second presentation with the original id. With
        # `refresh_grace_window: 0` the id is `:stale` at once — no sleep
        # needed → kills the session, writes `refresh_reuse`, returns 401.
        # Backdate the floor — rotation re-stamped it.
        backdate_refresh_issued_at(ctx[:refresh_token])
        ex = expect_raises(Facet::OAuth::Refresh::Error) do
          Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        end
        ex.error_code.should eq("invalid_grant")

        # The session row is gone — subsequent refreshes also fail.
        ex2 = expect_raises(Facet::OAuth::Refresh::Error) do
          Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        end
        ex2.error_code.should eq("invalid_grant")

        # The `refresh_reuse` audit event was written.
        count = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent'
            AND deleted_at IS NULL AND content->>'event' = 'refresh_reuse'
            AND content->>'account_id' = $1",
          ctx[:account_id],
          as: Int64,
        )
        count.should be > 0
      end
    end
  end

  it "fails refresh when the user's role was revoked mid-session" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      # Strip the role off the user.
      Facet::Document::Update.call(
        db, "iam", "Account", ctx[:account_id],
        %({"roles": []}),
        Facet::RBAC::AuthContext.system,
      )

      backdate_refresh_issued_at(ctx[:refresh_token])
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("Role is no longer assigned")
    end
  end

  it "fails refresh when the role was deleted mid-session" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      # The role projection id is the qualified role reference `iam.Roles.reader`.
      # Tombstone it directly: the public `Document::Delete` guard refuses to
      # delete a role still assigned to an account, and this spec only needs
      # the projection gone so refresh's live-state check sees the role vanish.
      role_id = "iam.Roles.reader"
      Facet::Mutation::Client.delete(db, "iam", "Roles", role_id)

      backdate_refresh_issued_at(ctx[:refresh_token])
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("Role no longer exists")
    end
  end

  it "fails refresh when the app was disabled mid-session" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      Facet::Document::Update.call(
        db, "app", "App", ctx[:app_id],
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )

      backdate_refresh_issued_at(ctx[:refresh_token])
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("App is not active")
    end
  end

  it "fails refresh when the app grant was narrowed mid-session" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      # Narrow the grant so `reader` no longer satisfies the required action.
      narrowed = [oauth_grant("hr.Employee", [oauth_action("read", required: true)])].to_json
      Facet::Document::Update.call(
        db, "app", "App", ctx[:app_id],
        %({"grants": #{narrowed}}),
        Facet::RBAC::AuthContext.system,
      )

      backdate_refresh_issued_at(ctx[:refresh_token])
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("Role is no longer usable")
    end
  end

  it "fails refresh when the user was disabled mid-session" do
    with_db do |db|
      ctx = issue_app_token(db,
        [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
        [oauth_perm("read", "crm.Contact")])

      Facet::Document::Update.call(
        db, "iam", "Account", ctx[:account_id],
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )

      backdate_refresh_issued_at(ctx[:refresh_token])
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("Account is not active")
    end
  end

  it "rejects a browser-session refresh token (no app field) with invalid_grant" do
    with_db do |db|
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: account_id, active_role: "iam.Roles.reader",
      )
      browser_refresh = "#{session_id}.#{refresh_id}"

      # A presented client_id changes nothing here — the app-session check
      # precedes the client-binding check, so a browser-session token is
      # rejected with the same answer either way.
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, browser_refresh, client_id: "cid_any_client")
      end
      ex.error_code.should eq("invalid_grant")
      ex.message.to_s.should contain("not an app session")
    end
  end

  it "rejects a malformed refresh token with invalid_grant" do
    with_db do |db|
      # The format check precedes the client-binding check — the client_id
      # value is never read.
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, "no-dot-here", client_id: "cid_any_client")
      end
      ex.error_code.should eq("invalid_grant")
      ex.status.should eq(401)
    end
  end

  it "rejects an unknown session with invalid_grant" do
    with_db do |db|
      # The session load precedes the client-binding check.
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call(db, "unknown_session.some_refresh_id", client_id: "cid_any_client")
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  describe "client binding (B-150)" do
    it "refreshes with the bound client_id" do
      with_db do |db|
        ctx = issue_app_token(db,
          [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
          [oauth_perm("read", "crm.Contact")])

        backdate_refresh_issued_at(ctx[:refresh_token])
        issued = Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        issued.access_token.should_not be_empty
        issued.refresh_token.should_not eq(ctx[:refresh_token])
      end
    end

    it "rejects a wrong client_id with invalid_grant and keeps the session" do
      with_db do |db|
        ctx = issue_app_token(db,
          [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
          [oauth_perm("read", "crm.Contact")])

        backdate_refresh_issued_at(ctx[:refresh_token])
        ex = expect_raises(Facet::OAuth::Refresh::Error) do
          Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: "cid_other_client")
        end
        ex.error_code.should eq("invalid_grant")
        ex.status.should eq(401)
        ex.message.to_s.should contain("not bound to this client")

        # The wrong-client attempt ran before reuse detection — the session
        # survived, and the real client refreshes right after.
        backdate_refresh_issued_at(ctx[:refresh_token])
        issued = Facet::OAuth::Refresh.call(db, ctx[:refresh_token], client_id: ctx[:client_id])
        issued.access_token.should_not be_empty
      end
    end

    it "rejects a refresh without client_id before the floor fires" do
      with_db do |db|
        ctx = issue_app_token(db,
          [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
          [oauth_perm("read", "crm.Contact")])

        # No backdate — the token was issued just now, inside the floor. The
        # 401 (not the floor's 429) proves the binding check runs first.
        ex = expect_raises(Facet::OAuth::Refresh::Error) do
          Facet::OAuth::Refresh.call(db, ctx[:refresh_token])
        end
        ex.error_code.should eq("invalid_grant")
        ex.status.should eq(401)
        ex.message.to_s.should contain("Missing 'client_id'")

        # The session survived.
        sid = ctx[:refresh_token].split('.', 2)[0]
        Facet::IAM::RedisSession.load(sid).should_not be_nil
      end
    end
  end
end

# ── Spec helpers ────────────────────────────────────────────────────────

# `IAM::RedisSession.validate_refresh_id` reads
# `Config.instance.iam.jwt.refresh_grace_window`. The two grace-window specs
# above swap in a `JWTConfig` with `refresh_grace_window: 0` (all other JWT
# fields kept), so presenting the previous refresh id is `:stale` at once —
# no fixed sleep. The default window stays 10 s for every other spec.
private def with_zero_grace_window(&)
  original = Facet::Config.instance
  temp = Facet::Config::IAMConfig.new(jwt: Facet::Config::JWTConfig.new(
    access_token_ttl: original.iam.jwt.access_token_ttl,
    refresh_token_ttl: original.iam.jwt.refresh_token_ttl,
    refresh_grace_window: 0,
    dpop_iat_future_tolerance: original.iam.jwt.dpop_iat_future_tolerance,
    dpop_iat_past_tolerance: original.iam.jwt.dpop_iat_past_tolerance,
  ))
  Facet::Config.instance = config_with_iam(original, temp)
  yield
ensure
  Facet::Config.instance = original if original
end
