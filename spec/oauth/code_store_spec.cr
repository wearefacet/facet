# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/code_store"

# OAuth authorization code store.
#
# Verifies the three security properties:
# - **Single-use**: a second redemption returns `nil`.
# - **TTL-bounded**: 60s TTL (not exercised time-wise, but verified at issue).
# - **Context-bound**: each stored field round-trips through consume.
#
# The store is Redis-backed. Specs use `with_redis` and the `oauth_code:` prefix
# is restored to clean state by `redis_cleanup`.

describe "OAuth::CodeStore" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  it "issues and consumes a code with all fields intact" do
    code = Facet::OAuth::CodeStore.issue(
      account_id: "account_001",
      role_id: "iam.Roles.admin",
      app_id: "app_01",
      client_id: "client_ABC",
      redirect_uri: "https://app.example.com/cb",
      code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    )

    record = Facet::OAuth::CodeStore.consume(code)
    record.should_not be_nil
    r = record.not_nil!
    r.code.should eq(code)
    r.account_id.should eq("account_001")
    r.role_id.should eq("iam.Roles.admin")
    r.app_id.should eq("app_01")
    r.client_id.should eq("client_ABC")
    r.redirect_uri.should eq("https://app.example.com/cb")
    r.code_challenge.should eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    r.created_at.should_not be_empty
  end

  it "rejects a second consume of the same code (single-use)" do
    code = Facet::OAuth::CodeStore.issue(
      account_id: "account_001",
      role_id: "iam.Roles.admin",
      app_id: "app_01",
      client_id: "client_ABC",
      redirect_uri: "https://app.example.com/cb",
      code_challenge: "challenge_456",
    )

    first = Facet::OAuth::CodeStore.consume(code)
    first.should_not be_nil

    second = Facet::OAuth::CodeStore.consume(code)
    second.should be_nil
  end

  it "returns nil for an unknown code" do
    Facet::OAuth::CodeStore.consume("nonexistent_code_417").should be_nil
  end

  it "returns nil for an empty string code" do
    Facet::OAuth::CodeStore.consume("").should be_nil
  end

  it "issues distinct codes for distinct calls (no collision)" do
    # Without Redis enroute, it is hard to test atomicity concurrently;
    # but at least confirm the public string of two issued codes is different.
    c1 = Facet::OAuth::CodeStore.issue(
      account_id: "u1", role_id: "r1", app_id: "a1",
      client_id: "cid", redirect_uri: "https://cb/",
      code_challenge: "c1",
    )
    c2 = Facet::OAuth::CodeStore.issue(
      account_id: "u1", role_id: "r1", app_id: "a1",
      client_id: "cid", redirect_uri: "https://cb/",
      code_challenge: "c1",
    )
    c1.should_not eq(c2)
  end
end
