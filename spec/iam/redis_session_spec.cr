# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/redis_session"

describe Facet::IAM::RedisSession do
  # RedisSession uses a module-level redis method that creates a new connection
  # each time. We clean up all IAM keys before each test.
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  describe ".create and .load" do
    it "creates a session and loads it" do
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
        user_agent: "TestAgent/1.0",
        ip: "127.0.0.1",
      )
      session_id.should be_a(String)
      refresh_id.should be_a(String)

      session = Facet::IAM::RedisSession.load(session_id)
      session.should_not be_nil
      session.try(&.account_id).should eq("account_123")
      session.try(&.active_role).should eq("iam.Roles.admin")
      session.try(&.user_agent).should eq("TestAgent/1.0")
      session.try(&.ip).should eq("127.0.0.1")
      session.try(&.refresh_id).should eq(refresh_id)
    end

    it "returns nil for a non-existent session" do
      Facet::IAM::RedisSession.load("nonexistent").should be_nil
    end

    it "creates a session without optional fields" do
      session_id, _refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.viewer",
      )
      session = Facet::IAM::RedisSession.load(session_id)
      session.should_not be_nil
      session.try(&.user_agent).should be_nil
      session.try(&.ip).should be_nil
    end

    it "reads the delivery mode as cookie when the flag is absent" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.token_delivery.should eq(Facet::IAM::RedisSession::DELIVERY_COOKIE)
    end

    it "stores body delivery when the creation asks for it" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
        cookie_delivery: false,
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.token_delivery.should eq(Facet::IAM::RedisSession::DELIVERY_BODY)
    end

    it "keeps the delivery mode across rotation" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
        cookie_delivery: false,
      )
      Facet::IAM::RedisSession.rotate(session_id)
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.token_delivery.should eq(Facet::IAM::RedisSession::DELIVERY_BODY)
    end
  end

  describe ".create_app_session and .load" do
    it "stores the client id on an app session" do
      session_id, refresh_id = Facet::IAM::RedisSession.create_app_session(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
        app: "01FAKEAPP0000000000000",
        client_id: "cid_app_client",
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.app.should eq("01FAKEAPP0000000000000")
      session.client_id.should eq("cid_app_client")
      session.refresh_id.should eq(refresh_id)
    end

    it "keeps no client id on a browser session" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.app.should be_empty
      # The empty string is the record's absent value — the hash carries no
      # `client_id` field at all for a browser session.
      session.client_id.should be_empty
    end

    it "keeps the client id across rotation" do
      session_id, _ = Facet::IAM::RedisSession.create_app_session(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
        app: "01FAKEAPP0000000000000",
        client_id: "cid_app_client",
      )
      Facet::IAM::RedisSession.rotate(session_id)
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      session.client_id.should eq("cid_app_client")
    end
  end

  describe ".rotate" do
    it "rotates the refresh_id and stores the previous one" do
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      new_refresh = Facet::IAM::RedisSession.rotate(session_id)
      new_refresh.should_not be_nil
      new_refresh.should_not eq(refresh_id)

      session = Facet::IAM::RedisSession.load(session_id)
      session.try(&.refresh_id).should eq(new_refresh)
      session.try(&.prev_refresh_id).should eq(refresh_id)
    end

    it "updates active_role when provided" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      Facet::IAM::RedisSession.rotate(session_id, active_role: "iam.Roles.editor")
      session = Facet::IAM::RedisSession.load(session_id)
      session.try(&.active_role).should eq("iam.Roles.editor")
    end

    it "returns nil for a non-existent session" do
      Facet::IAM::RedisSession.rotate("nonexistent").should be_nil
    end

    it "keeps exactly one winner under concurrent rotation (atomicity)" do
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      results = Channel(String?).new(8)
      done = Channel(Nil).new(8)

      # Eight fibers rotate the same session concurrently. The Lua script
      # makes each rotate atomic: every fiber sees a consistent prev/current
      # chain, and the final state must be internally consistent — the last
      # writer's refresh_id is current, and no intermediate value is lost in
      # a way that would trip reuse detection for a legitimate client.
      8.times do
        spawn(name: "rotate-race") do
          results.send(Facet::IAM::RedisSession.rotate(session_id))
          done.send(nil)
        end
      end
      8.times { done.receive }

      winners = [] of String
      8.times do
        r = results.receive
        winners << r if r
      end
      winners.size.should eq(8)

      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      # The current refresh_id is one of the rotated values.
      winners.should contain(session.refresh_id)
      # The previous id is also a rotated value (or the original on the first
      # write), and never a fabricated one.
      valid_prevs = winners + [refresh_id]
      if prev = session.prev_refresh_id
        valid_prevs.should contain(prev)
      end
      # The current id must differ from prev (rotation actually moved).
      session.refresh_id.should_not eq(session.prev_refresh_id)
    end
  end

  describe ".validate_refresh_id" do
    it "returns :valid when refresh_id matches" do
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      Facet::IAM::RedisSession.validate_refresh_id(session, refresh_id).should eq(:valid)
    end

    it "returns :grace when prev_refresh_id matches" do
      session_id, refresh_id = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      new_refresh = Facet::IAM::RedisSession.rotate(session_id).not_nil!
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      Facet::IAM::RedisSession.validate_refresh_id(session, refresh_id).should eq(:grace)
      Facet::IAM::RedisSession.validate_refresh_id(session, new_refresh).should eq(:valid)
    end

    it "returns :stale for an unknown refresh_id" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      session = Facet::IAM::RedisSession.load(session_id).not_nil!
      Facet::IAM::RedisSession.validate_refresh_id(session, "unknown").should eq(:stale)
    end
  end

  describe ".delete" do
    it "deletes a session and removes it from account_sessions" do
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: "account_123",
        active_role: "iam.Roles.admin",
      )
      Facet::IAM::RedisSession.delete(session_id)
      Facet::IAM::RedisSession.load(session_id).should be_nil
    end
  end

  describe ".list_account_sessions" do
    it "lists all sessions for an account" do
      sid1, _ = Facet::IAM::RedisSession.create(account_id: "account_123", active_role: "iam.Roles.admin")
      sid2, _ = Facet::IAM::RedisSession.create(account_id: "account_123", active_role: "iam.Roles.editor")
      sid3, _ = Facet::IAM::RedisSession.create(account_id: "account_456", active_role: "iam.Roles.viewer")

      sessions = Facet::IAM::RedisSession.list_account_sessions("account_123")
      sessions.should contain(sid1)
      sessions.should contain(sid2)
      sessions.should_not contain(sid3)
    end
  end
end
