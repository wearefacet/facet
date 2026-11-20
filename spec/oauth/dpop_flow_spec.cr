# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam"
require "../../src/iam/redis_session"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/oauth/dpop"
require "../../src/oauth/origin_cache"
require "../../src/oauth/rate_limiter"
require "../../src/oauth/replay_cache"
require "../support/http_helper"
require "../support/oauth_helper"
require "../support/doctype_helper"
require "../support/app_helper"
require "./oauth_flow_spec"
require "./oauth_refresh_flow_spec"

HTTPTest.init

# DPoP (RFC 9449) end-to-end flow.
#
# Builds on `oauth_flow_spec.cr` and `oauth_refresh_flow_spec.cr`: the
# existing authorize → token → refresh pipeline is exercised
# with a DPoP proof on every step. Sad paths cover:
# - stolen-proof replay (same `jti` rejected on the second request)
# - mismatched-key refresh (different key pair on refresh)
# - missing proof on a bound token (refresh + API)
# - `Bearer` presented instead of `DPoP` on a `cnf`-bearing token
# - `htu` mismatch (proof signed against an internal URL)
#
# All proofs use the helpers in `spec/support/oauth_helper.cr`. The host
# origin in `config.test.yml` is `localhost:3000`; `OAuth::HTU.reconstruct`
# prepends `https://`, so every `htu` in this spec is
# `https://localhost:3000/...` — matching what the server verifies.

# Token endpoint URL as the server's `OAuth::HTU.reconstruct` builds it.
# `Config.instance.host` is `localhost:3000` in `config.test.yml`.
private def token_htu : String
  "https://localhost:3000/OAuth/token"
end

# API URL for an arbitrary Facet endpoint — used to assert `htu` for an API
# request matches the proof the client signed. The actual API endpoint here
# is `/Api/iam/me`; the path is stable and AuthHandler-protected.
private def api_htu(path : String) : String
  "https://localhost:3000#{path}"
end

# Runs a full authorize → token flow WITH a DPoP proof on the token endpoint.
# Returns the issued access+refresh token and the DPoP key pair the proof
# was signed with, so subsequent specs (refresh, API calls) can sign further
# proofs with the same key. Mirrors `oauth_full_token_flow` but adds the
# `DPoP` header on the final token-exchange request.
private def dpop_full_flow(email = "dpop@example.com", password = "dpop-password")
  grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
  perm = [oauth_perm("read", "crm.Contact")]

  # First, drive the bearer-token flow so the user/app/code flow exists.
  # The bearer token it returns is discarded — we re-issue a fresh code
  # with a DPoP header on the token endpoint.
  ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
    email: email, password: password)

  with_db do |_|
    session = login_token(email, password)
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = s256_challenge(verifier)
    redirect_uri = "https://app.example.com/cb"
    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => ctx[:client_id],
      "redirect_uri"          => redirect_uri,
      "state"                 => "dpop_state",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
    })
    consent = call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}",
      headers: bearer_headers(session)))
    assert_http_status(consent, 200)

    body = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => ctx[:client_id],
      "redirect_uri"          => redirect_uri,
      "state"                 => "dpop_state",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
      "role"                  => "iam.Roles.reader",
    })
    issued_code = call_api(HTTP::Request.new("POST", "/OAuth/authorize",
      headers: HTTP::Headers{
        "Authorization" => "Bearer #{session}",
        "Content-Type"  => "application/x-www-form-urlencoded",
      }, body: body))
    assert_http_status(issued_code, 200)
    code = JSON.parse(issued_code.body)["code"].as_s

    # DPoP proof for the token endpoint — `htm=POST`, `htu=token_htu`, no `ath`
    # (no access token at issuance; `OAuth::DPoP.verify` is invoked with
    # `ath: nil`).
    pair = dpop_key_pair
    dpop_proof = sign_dpop_proof(pair, htm: "POST", htu: token_htu)

    token_body = URI::Params.encode({
      "grant_type"    => "authorization_code",
      "code"          => code,
      "redirect_uri"  => redirect_uri,
      "code_verifier" => verifier,
      "client_id"     => ctx[:client_id],
    })
    token_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => dpop_proof,
      }, body: token_body))
    assert_http_status(token_resp, 200)
    token_json = JSON.parse(token_resp.body)

    token_json["token_type"].as_s.should eq("DPoP")
    access_token = token_json["access_token"].as_s
    refresh_token = token_json["refresh_token"].as_s

    # `cnf.jkt` matches the proof's JWK thumbprint; the bound key is persisted
    # on the RedisSession so refresh can enforce a matching proof.
    decoded = Facet::IAM::JWT.decode(access_token, Facet::IAM::TokenEmitter.keys)
    cnf = decoded.payload["cnf"]?.try(&.as_h?).not_nil!
    cnf["jkt"].as_s.should eq(pair.jkt)

    session_id = refresh_token.split('.', 2)[0]
    loaded = Facet::IAM::RedisSession.load(session_id).not_nil!
    loaded.dpop_jkt.should eq(pair.jkt)

    {
      client_id:     ctx[:client_id],
      app_id:        ctx[:app_id],
      account_id:    ctx[:account_id],
      access_token:  access_token,
      refresh_token: refresh_token,
      key_pair:      pair,
    }
  end
end

describe "OAuth — DPoP flow (Phase 7)" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    Facet::OAuth::OriginCache.reset
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      Facet::OAuth::OriginCache.reset
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "issues a DPoP-bound token when a proof is presented at the token endpoint" do
    ctx = dpop_full_flow
    ctx[:access_token].should_not be_empty
  end

  it "rejects a stolen-proof replay at the API surface" do
    ctx = dpop_full_flow(email: "replay-api@example.com", password: "replay-api-pw")
    # Build a proof for /Api/iam/me and submit it on the first request — it
    # verifies and marks the (jkt, jti) in the replay cache. A second request
    # with the SAME proof must be rejected as a replay.
    ath = Facet::OAuth::DPoP.compute_ath(ctx[:access_token])
    proof = sign_dpop_proof(ctx[:key_pair], htm: "GET", htu: api_htu("/Api/iam/me"),
      ath: ath)
    h = HTTP::Headers{
      "Authorization" => "DPoP #{ctx[:access_token]}",
      "DPoP"          => proof,
    }
    resp1 = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp1, 200)
    resp2 = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp2, 401)
  end

  it "rejects refresh of a bound session without a DPoP proof" do
    ctx = dpop_full_flow(email: "no-proof@example.com", password: "no-proof-pw")
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(resp, 401)
    error_json = JSON.parse(resp.body)
    error_json["error"].as_s.should eq("invalid_grant")
  end

  it "rejects refresh with a DPoP proof signed by a different key pair" do
    ctx = dpop_full_flow(email: "wrong-key@example.com", password: "wrong-key-pw")
    other_pair = dpop_key_pair
    wrong_proof = sign_dpop_proof(other_pair, htm: "POST", htu: token_htu)
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => wrong_proof,
      }, body: refresh_body))
    assert_http_status(resp, 401)
  end

  it "rotates a DPoP-bound refresh token when a matching proof is presented" do
    ctx = dpop_full_flow(email: "rotate-dpop@example.com", password: "rotate-dpop-pw")
    proof = sign_dpop_proof(ctx[:key_pair], htm: "POST", htu: token_htu)
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => proof,
      }, body: refresh_body))
    assert_http_status(resp, 200)
    body_json = JSON.parse(resp.body)
    body_json["token_type"].as_s.should eq("DPoP")
    body_json["refresh_token"].as_s.should_not eq(ctx[:refresh_token])

    # The rotated access token MUST still carry `cnf.jkt` matching the bound
    # key — a downgrade to bearer on rotation is impossible.
    decoded = Facet::IAM::JWT.decode(body_json["access_token"].as_s, Facet::IAM::TokenEmitter.keys)
    cnf = decoded.payload["cnf"]?.try(&.as_h?).not_nil!
    cnf["jkt"].as_s.should eq(ctx[:key_pair].jkt)

    # The rotated refresh must still be bound — a refresh of the rotated
    # refresh with a matching proof succeeds. Rotation re-stamps the floor,
    # so backdate again.
    rotated_refresh = body_json["refresh_token"].as_s
    backdate_refresh_issued_at(rotated_refresh)
    body2 = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => rotated_refresh,
      "client_id"     => ctx[:client_id],
    })

    proof2 = sign_dpop_proof(ctx[:key_pair], htm: "POST", htu: token_htu)
    resp3 = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => proof2,
      }, body: body2))
    assert_http_status(resp3, 200)
  end

  it "rejects a Bearer-presented bound access token at the API surface" do
    ctx = dpop_full_flow(email: "bearer-rejected@example.com", password: "bearer-rejected-pw")
    # Build a valid proof (we want to confirm the failure is the scheme, not
    # a missing or malformed proof).
    proof = sign_dpop_proof(ctx[:key_pair], htm: "GET", htu: api_htu("/Api/iam/me"),
      ath: Facet::OAuth::DPoP.compute_ath(ctx[:access_token]))
    # Present under the `Bearer` scheme — the downgrade guard rejects.
    h = HTTP::Headers{
      "Authorization" => "Bearer #{ctx[:access_token]}",
      "DPoP"          => proof,
    }
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp, 401)
  end

  it "rejects an htu mismatch (proof signed against an internal URL)" do
    ctx = dpop_full_flow(email: "htu-mismatch@example.com", password: "htu-mismatch-pw")
    # Sign the proof against `http://localhost:3000/...` — the server
    # reconstructs `https://localhost:3000/...` from `Config.host`, so the
    # `htu` claim fails comparison.
    wrong_htu = "http://localhost:3000/Api/iam/me"
    proof = sign_dpop_proof(ctx[:key_pair], htm: "GET", htu: wrong_htu,
      ath: Facet::OAuth::DPoP.compute_ath(ctx[:access_token]))
    h = HTTP::Headers{
      "Authorization" => "DPoP #{ctx[:access_token]}",
      "DPoP"          => proof,
    }
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp, 401)
  end

  it "accepts a non-bound access token (bearer fallback)" do
    # Issue a token WITHOUT a DPoP proof — the token has no `cnf`, refresh
    # does not require a proof, and the access token stays a plain bearer.
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]
    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "bearer-fallback@example.com", password: "bearer-fallback-pw")

    # Access token has no `cnf` — bearer fallback.
    decoded = Facet::IAM::JWT.decode(ctx[:access_token], Facet::IAM::TokenEmitter.keys)
    decoded.payload["cnf"]?.should be_nil

    # Refresh works without a DPoP header — bearer refresh. Backdate the
    # refresh floor first — the token was issued just now.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(resp, 200)
    body_json = JSON.parse(resp.body)
    body_json["token_type"].as_s.should eq("Bearer")
  end

  it "rejects the DPoP scheme on an unbound access token (B-338)" do
    # Issue a token WITHOUT a DPoP proof — no `cnf`, so the token is a plain
    # bearer and the server signaled `token_type: Bearer`.
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]
    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "dpop-scheme-unbound@example.com", password: "dpop-scheme-unbound-pw")

    # The same token under its real `Bearer` scheme authenticates normally.
    h = HTTP::Headers{"Authorization" => "Bearer #{ctx[:access_token]}"}
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp, 200)

    # Under the `DPoP` scheme it is a scheme mismatch — the strict gate
    # answers 401 and challenges with the Bearer scheme the client holds.
    h = HTTP::Headers{"Authorization" => "DPoP #{ctx[:access_token]}"}
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: h))
    assert_http_status(resp, 401)
    resp.headers["WWW-Authenticate"].should eq("Bearer")
  end

  it "rejects a stolen-proof replay at the token endpoint" do
    ctx = dpop_full_flow(email: "replay-token@example.com", password: "replay-token-pw")
    # Refresh once with a fresh `jti` — succeeds. Backdate the floor first.
    proof = sign_dpop_proof(ctx[:key_pair], htm: "POST", htu: token_htu)
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => proof,
      }, body: refresh_body))
    assert_http_status(resp, 200)
    rotated_refresh = JSON.parse(resp.body)["refresh_token"].as_s

    # Reuse the SAME `jti` on a refresh of the rotated token — the replay
    # cache rejects, even though the proof signature is still valid.
    # Use the same `jti` as `proof` — we need to extract it from above. Easier
    # path: reuse `proof` directly; the cache key is `(jkt, jti)` and the
    # replay is detected regardless of which refresh token we present.
    # Rotation re-stamped the floor, so backdate before the second refresh.
    refresh_body2 = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => rotated_refresh,
      "client_id"     => ctx[:client_id],
    })
    backdate_refresh_issued_at(rotated_refresh)
    resp2 = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "DPoP"         => proof,
      }, body: refresh_body2))
    assert_http_status(resp2, 401)
    JSON.parse(resp2.body)["error"].as_s.should eq("invalid_grant")
  end
end
