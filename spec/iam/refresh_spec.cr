# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

# A body-mode session: login delivered the tokens in the JSON body
# (`cookie: false`). Mirrors `create_session_and_refresh_token`, which
# cannot carry the delivery flag (sessions it creates read as cookie mode).
private def create_body_mode_session(db)
  account_id = create_test_account(db)
  session_id, refresh_id = Facet::IAM::RedisSession.create(
    account_id: account_id,
    active_role: "iam.Roles.admin",
    cookie_delivery: false,
  )
  {account_id: account_id, session_id: session_id, refresh_token: "#{session_id}.#{refresh_id}"}
end

private def assert_delivery_mismatch(result : Facet::IAM::Refresh::TokensEmitted | Facet::ServiceError) : Nil
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(422)
  err.message.should contain("delivery mismatch")
end

describe Facet::IAM::Refresh do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "refreshes tokens with valid refresh token" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db)
      result = Facet::IAM::Refresh.call(db, ctx[:refresh_token])

      result.should be_a(Facet::IAM::Refresh::TokensEmitted)
      token_result = result.as(Facet::IAM::Refresh::TokensEmitted).result
      token_result.account_id.should eq(ctx[:account_id])
      token_result.active_role.should eq("iam.Roles.admin")
      token_result.access_token.should_not be_empty
      token_result.refresh_token.should_not be_empty
      token_result.cookie.should be_true
    end
  end

  it "rotates the refresh token" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db)

      result = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
      new_refresh = result.as(Facet::IAM::Refresh::TokensEmitted).result.refresh_token

      # The new refresh token should be different
      new_refresh.should_not eq(ctx[:refresh_token])

      # The old refresh token should still work during the grace window
      result2 = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
      result2.should be_a(Facet::IAM::Refresh::TokensEmitted)
    end
  end

  it "changes active role when requested" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db, roles: ["iam.Roles.admin", "iam.Roles.editor"], active_role: "iam.Roles.admin")

      result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], role: "iam.Roles.editor")
      result.should be_a(Facet::IAM::Refresh::TokensEmitted)
      token_result = result.as(Facet::IAM::Refresh::TokensEmitted).result
      token_result.active_role.should eq("iam.Roles.editor")
    end
  end

  it "refreshes a roleless account's session under the anonymous role (B-120)" do
    with_db do |db|
      # The anonymous role is a production seed; the lighter `seed_test_roles`
      # does not create it, so seed the full role set first.
      ensure_seed_roles_with_dependencies(db)
      ctx = create_session_and_refresh_token(db, roles: [] of String,
        active_role: Facet::IAM::ANONYMOUS_ROLE_ID)

      result = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
      result.should be_a(Facet::IAM::Refresh::TokensEmitted)
      token_result = result.as(Facet::IAM::Refresh::TokensEmitted).result
      token_result.active_role.should eq(Facet::IAM::ANONYMOUS_ROLE_ID)
      token_result.available_roles.should be_empty
    end
  end

  it "rejects refresh with invalid token format" do
    with_db do |db|
      result = Facet::IAM::Refresh.call(db, "invalid-token")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Invalid refresh token format")
    end
  end

  it "rejects refresh with expired session" do
    with_db do |db|
      result = Facet::IAM::Refresh.call(db, "nonexistent.unknown")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Session expired or not found")
    end
  end

  it "rejects refresh with unassigned role" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db, roles: ["iam.Roles.admin"], active_role: "iam.Roles.admin")

      result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], role: "iam.Roles.editor")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("Role not assigned")
    end
  end

  it "detects refresh token reuse (theft)" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db)

      # First refresh rotates the token
      Facet::IAM::Refresh.call(db, ctx[:refresh_token])

      # Wait for grace window to expire (we can't easily wait, so simulate by
      # rotating again and then presenting a stale token)
      result1 = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
      # After two rotations, the original refresh_id is no longer prev_refresh_id
      # of the current session. The session should be deleted as theft detection.
      result1.should be_a(Facet::IAM::Refresh::TokensEmitted)

      # Now try the original token again — it's stale
      result2 = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
      result2.should be_a(Facet::ServiceError)
      err = result2.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should contain("Session revoked")
    end
  end

  it "writes no refresh LoginEvent (the backend log carries the trace)" do
    with_db do |db|
      ctx = create_session_and_refresh_token(db)

      Facet::IAM::Refresh.call(db, ctx[:refresh_token])

      events = db.query_all(
        "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
        as: JSON::Any
      )
      events.any? { |e| e["event"]?.try(&.as_s) == "refresh" }.should be_false
    end
  end

  it "refuses an app-scoped session — no upgrade to a full user token (S2)" do
    with_db do |db|
      account_id = create_test_account(db)
      session_id, refresh_id = Facet::IAM::RedisSession.create_app_session(
        account_id: account_id, active_role: "iam.Roles.admin",
        app: "01FAKEAPP0000000000000", client_id: "cid_fake_app")

      result = Facet::IAM::Refresh.call(db, "#{session_id}.#{refresh_id}")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should contain("App sessions cannot refresh")

      # The session survives — the holder still refreshes it on the OAuth path.
      session = Facet::IAM::RedisSession.load(session_id)
      session.should_not be_nil
      session.not_nil!.refresh_id.should eq(refresh_id)
    end
  end

  it "answers the app-session refusal before rotating (theft path untouched)" do
    with_db do |db|
      account_id = create_test_account(db)
      session_id, _refresh_id = Facet::IAM::RedisSession.create_app_session(
        account_id: account_id, active_role: "iam.Roles.admin",
        app: "01FAKEAPP0000000000000", client_id: "cid_fake_app")

      # A stale refresh id would normally trip reuse detection and delete the
      # session. The app gate runs first, so the session stays.
      result = Facet::IAM::Refresh.call(db, "#{session_id}.stale-id")
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
      Facet::IAM::RedisSession.load(session_id).should_not be_nil
    end
  end

  describe "token delivery mode (B-278)" do
    it "refreshes a body-mode session with cookie: false and returns both tokens" do
      with_db do |db|
        ctx = create_body_mode_session(db)

        result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: false)
        result.should be_a(Facet::IAM::Refresh::TokensEmitted)
        emitted = result.as(Facet::IAM::Refresh::TokensEmitted).result
        emitted.cookie.should be_false
        emitted.access_token.should_not be_empty
        emitted.refresh_token.should_not be_empty
        emitted.refresh_token.should_not eq(ctx[:refresh_token])
      end
    end

    it "answers 422 to an absent flag on a body-mode session and rotates nothing" do
      with_db do |db|
        ctx = create_body_mode_session(db)

        result = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
        assert_delivery_mismatch(result)

        session = Facet::IAM::RedisSession.load(ctx[:session_id]).not_nil!
        session.refresh_id.should eq(ctx[:refresh_token].split('.', 2)[1])
        session.prev_refresh_id.should be_nil
      end
    end

    it "answers 422 to cookie: true on a body-mode session and rotates nothing" do
      with_db do |db|
        ctx = create_body_mode_session(db)

        result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: true)
        assert_delivery_mismatch(result)

        session = Facet::IAM::RedisSession.load(ctx[:session_id]).not_nil!
        session.refresh_id.should eq(ctx[:refresh_token].split('.', 2)[1])
        session.prev_refresh_id.should be_nil
      end
    end

    it "answers 422 to cookie: false on a cookie-mode session and rotates nothing" do
      with_db do |db|
        ctx = create_session_and_refresh_token(db)

        result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: false)
        assert_delivery_mismatch(result)

        session = Facet::IAM::RedisSession.load(ctx[:session_id]).not_nil!
        session.refresh_id.should eq(ctx[:refresh_token].split('.', 2)[1])
        session.prev_refresh_id.should be_nil
      end
    end

    it "refreshes a cookie-mode session with cookie: true" do
      with_db do |db|
        ctx = create_session_and_refresh_token(db)

        result = Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: true)
        result.should be_a(Facet::IAM::Refresh::TokensEmitted)
        result.as(Facet::IAM::Refresh::TokensEmitted).result.cookie.should be_true
      end
    end

    it "accepts the same refresh token again after a body-mode 422 (trap gone)" do
      with_db do |db|
        ctx = create_body_mode_session(db)

        Facet::IAM::Refresh.call(db, ctx[:refresh_token]).should be_a(Facet::ServiceError)

        corrected = Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: false)
        corrected.should be_a(Facet::IAM::Refresh::TokensEmitted)
      end
    end

    it "accepts the same refresh token again after a cookie-mode 422" do
      with_db do |db|
        ctx = create_session_and_refresh_token(db)

        Facet::IAM::Refresh.call(db, ctx[:refresh_token], cookie: false).should be_a(Facet::ServiceError)

        corrected = Facet::IAM::Refresh.call(db, ctx[:refresh_token])
        corrected.should be_a(Facet::IAM::Refresh::TokensEmitted)
      end
    end
  end
end
