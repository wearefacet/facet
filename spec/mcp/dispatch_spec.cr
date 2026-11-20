# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/mcp/dispatch"
require "../../src/mcp"
require "../support/oauth_helper"

# MCP dispatch verification chain (`doc/backend/mcp.md`).
#
# Every rejection happens before any tool dispatch, before any DB read
# beyond the account/role lookups:
# - Missing token → 401.
# - Bad signature / garbage token → 401.
# - Wrong `aud` → 401 (exact string match, no prefix).
# - URL `:role_slug` ≠ token `role` → 401.
# - Suspended / disabled account → 401.
# - Deleted account → 401.
# - Happy path builds `AuthContext.authenticated` with the elected role.
# Signs an access token shaped like the one `OAuth::Token.call_mcp` mints:
# browser-session claims + `aud` + `role`, no `app` claim.
def sign_mcp_token(account_id : String, role : String, aud : String?, sid : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: sid,
    role: role,
    aud: aud,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

def sign_mcp_token(account_id : String, role : String, aud : String?) : String
  sign_mcp_token(account_id, role, aud, Random::Secure.hex(16))
end

describe "MCP::Dispatch" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "builds an authenticated context on the happy path" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.editor"))

      verified = Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      verified.auth_context.system?.should be_false
      verified.auth_context.account_id.should eq(account_id)
      verified.role_id.should eq("iam.Roles.editor")
      verified.session_id.should_not be_empty
    end
  end

  it "rejects a missing token" do
    ex = expect_raises(Facet::MCP::Dispatch::Unauthorized) do
      Facet::MCP::Dispatch.verify(nil, "iam.Roles.editor")
    end
    ex.www_authenticate.should contain("invalid_token")
  end

  it "rejects a garbage token" do
    expect_raises(Facet::MCP::Dispatch::Unauthorized, /verification failed/) do
      Facet::MCP::Dispatch.verify("not.a.jwt", "iam.Roles.editor")
    end
  end

  it "rejects a token whose aud names a different role's resource" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      # Token minted for the admin resource, replayed against the editor URL.
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.admin"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /audience/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  it "rejects a token without an aud claim" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      token = sign_mcp_token(account_id, "iam.Roles.editor", nil)

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /audience/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  it "rejects when the URL slug does not equal the token role" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor", "iam.Roles.viewer"],
        default_role: "iam.Roles.editor")
      # The token's aud matches the viewer URL (so the audience gate passes)
      # but its role claim is editor — the slug/role equality must reject it.
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.viewer"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /mounted URL/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.viewer")
      end
    end
  end

  it "rejects a suspended account" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"],
        default_role: "iam.Roles.editor", status: "suspended")
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.editor"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /not active/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  it "rejects a disabled account" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"],
        default_role: "iam.Roles.editor", status: "disabled")
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.editor"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /not active/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  it "rejects a deleted account" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      db.exec("UPDATE projections SET deleted_at = now() WHERE id = $1", account_id)
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.editor"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /not found/i) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  it "rejects when the role projection no longer exists" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      db.exec("DELETE FROM projections WHERE id = 'iam.Roles.editor'")
      token = sign_mcp_token(account_id, "iam.Roles.editor", Facet::MCP.resource_identifier("iam.Roles.editor"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized, /Role not found/) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      end
    end
  end

  describe "with_session_slot" do
    it "admits up to the configured cap concurrently and releases after" do
      cap = Facet::Config.instance.mcp.max_concurrency_per_sid
      entered = Channel(Nil).new(cap)
      release = Channel(Nil).new(1)
      done = Channel(Nil).new(cap)

      cap.times do
        spawn(name: "mcp-slot-test") do
          Facet::MCP::Dispatch.with_session_slot("spec-sid") do
            entered.send(nil)
            release.receive
            done.send(nil)
          end
        end
      end

      # All cap fibers enter.
      cap.times { entered.receive }

      # A cap+1-th fiber must NOT enter while all slots are held. Prove it by
      # checking it has not signaled within a short window.
      extra_entered = Channel(Nil).new(1)
      spawn(name: "mcp-slot-overflow") do
        Facet::MCP::Dispatch.with_session_slot("spec-sid") do
          extra_entered.send(nil)
        end
      end
      select
      when extra_entered.receive
        raise "overflow fiber entered despite full semaphore"
      when timeout(100.milliseconds)
        # Expected — the overflow fiber is waiting for a slot.
      end

      # Release everything; the overflow fiber then enters and completes.
      cap.times { release.send(nil) }
      cap.times { done.receive }
      extra_entered.receive.should be_nil
    end
  end
end
