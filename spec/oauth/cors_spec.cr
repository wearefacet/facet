# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/oauth/cors"
require "../../src/oauth/origin_cache"
require "../support/http_helper"
require "../support/oauth_helper"

HTTPTest.init

# CORS handler for app-registered origins.
#
# Contract:
# - The token endpoint and the document API must accept the app's registered
#   origins.
# - Origins are matched exactly via `OriginCache` (no wildcards, no
#   normalization — same rule as `redirect_uri` on the authorize endpoint).
# - Echo, not `*`: browsers ignore `Access-Control-Allow-Origin: *` when
#   `Authorization` is in `Access-Control-Allow-Headers`.
#
# The handler runs early in the Kemal chain (before `AuthHandler`) — see
# `src/oauth/cors.cr`. These specs assert both preflight (`OPTIONS`) and
# actual-response header mirroring for the two CORS-relevant surfaces:
# `/OAuth/token` and `/Api/*`.

describe "OAuth::Cors" do
  around_each do |example|
    redis_cleanup
    # AuthHandler is OFF: only the CORS handler is under test. CORS applies
    # pre-auth, so theAuthHandler state does not affect outcomes.
    Facet::HTTP::AuthHandler.enabled = false
    Facet::OAuth::OriginCache.reset
    begin
      example.run
    ensure
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

  describe "OPTIONS /OAuth/token preflight" do
    it "returns 204 with CORS headers for a registered origin" do
      with_db do |db|
        create_test_app(db, "test-app",
          redirect_uris: ["https://app.example.com/cb"],
          allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{
          "Origin"       => "https://app.example.com",
          "Content-Type" => "application/x-www-form-urlencoded",
        }
        resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/token", headers: headers))

        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
        resp.headers["Access-Control-Allow-Credentials"]?.should eq("true")
        resp.headers["Access-Control-Allow-Methods"]?.to_s.should contain("POST")
        resp.headers["Access-Control-Allow-Headers"]?.to_s.should contain("Authorization")
        # DPoP: the token request a browser app makes carries the
        # `DPoP` proof header — the preflight must declare it or the browser
        # blocks the actual exchange.
        resp.headers["Access-Control-Allow-Headers"]?.to_s.should contain("DPoP")
        resp.headers["Vary"]?.to_s.should contain("Origin")
      end
    end

    it "returns 204 without CORS Allow-Origin for an unregistered origin" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{
          "Origin"       => "https://attacker.example.com",
          "Content-Type" => "application/x-www-form-urlencoded",
        }
        resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/token", headers: headers))

        assert_http_status(resp, 204)
        # No Allow-Origin → browser blocks the subsequent actual request.
        resp.headers["Access-Control-Allow-Origin"]?.should be_nil
        resp.headers["Vary"]?.to_s.should contain("Origin")
      end
    end

    it "returns 204 without CORS Allow-Origin when there is no Origin header" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/token"))
        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should be_nil
      end
    end
  end

  describe "OPTIONS /Api/* preflight" do
    it "echoes CORS Allow-Origin for a registered origin" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{
          "Origin"       => "https://app.example.com",
          "Content-Type" => "application/json",
        }
        resp = call_api(HTTP::Request.new("OPTIONS", "/Api/crm/Contact", headers: headers))

        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
        resp.headers["Access-Control-Allow-Credentials"]?.should eq("true")
        # DPoP-bound API reads arrive with the `DPoP` proof header set.
        resp.headers["Access-Control-Allow-Headers"]?.to_s.should contain("DPoP")
      end
    end

    # F07-05 — the API serves PATCH, PUT, and DELETE under /Api/*. A
    # browser preflights every non-safelisted method, so the preflight
    # must declare the write verbs or the browser blocks the real call.
    it "declares the write verbs and QUERY in Access-Control-Allow-Methods (F07-05)" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{"Origin" => "https://app.example.com"}
        resp = call_api(HTTP::Request.new("OPTIONS", "/Api/crm/Contact", headers: headers))

        assert_http_status(resp, 204)
        methods = resp.headers["Access-Control-Allow-Methods"].split(',').map(&.strip)
        %w[GET POST PATCH PUT DELETE QUERY OPTIONS].each do |verb|
          methods.should contain(verb)
        end
      end
    end
  end

  describe "OPTIONS /.well-known/oauth-authorization-server preflight" do
    it "echoes CORS Allow-Origin for a registered origin" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{"Origin" => "https://app.example.com"}
        resp = call_api(HTTP::Request.new("OPTIONS", "/.well-known/oauth-authorization-server", headers: headers))

        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
      end
    end
  end

  describe "OPTIONS /OAuth/client-info preflight (B-22)" do
    it "echoes CORS Allow-Origin for a registered origin" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{"Origin" => "https://app.example.com"}
        resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/client-info?slug=whatever", headers: headers))

        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
      end
    end

    it "sends no ACAO for an unregistered origin" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{"Origin" => "https://stranger.example.com"}
        resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/client-info?slug=whatever", headers: headers))

        assert_http_status(resp, 204)
        resp.headers["Access-Control-Allow-Origin"]?.should be_nil
      end
    end
  end

  describe "actual GET /OAuth/client-info response (B-22)" do
    around_each do |example|
      Facet::HTTP::AuthHandler.enabled = true
      begin
        example.run
      ensure
        Facet::HTTP::AuthHandler.enabled = false
      end
    end

    it "mirrors Access-Control-Allow-Origin when Origin is registered" do
      with_db do |db|
        _, _client_id = create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])
        # `create_test_app` suffixes the slug for isolation — resolve the
        # live slug from the projections.
        slug = with_db do |db2|
          db2.query_one("SELECT content->>'slug' FROM projections WHERE domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL LIMIT 1", as: String)
        end

        headers = HTTP::Headers{"Origin" => "https://app.example.com"}
        resp = call_api(HTTP::Request.new("GET", "/OAuth/client-info?slug=#{slug}", headers: headers))

        assert_http_status(resp, 200)
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
      end
    end
  end

  describe "actual responses (non-OPTIONS)" do
    it "mirrors Access-Control-Allow-Origin on a /Api/* response when Origin is registered" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        # GET /Api/iam/me without auth yields 200 from `extract_account_id` →
        # 401 JSON shape. The CORS handler still adds headerscircling back to
        # the AuthHandler-protected path; we only assert CORS-headers presence,
        # not the body or status.
        headers = HTTP::Headers{"Origin" => "https://app.example.com"}
        resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))
        resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
        resp.headers["Access-Control-Allow-Credentials"]?.should eq("true")
        resp.headers["Vary"]?.to_s.should contain("Origin")
      end
    end

    it "does not mirror CORS headers when the Origin is not registered" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        headers = HTTP::Headers{"Origin" => "https://attacker.example.com"}
        resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))
        resp.headers["Access-Control-Allow-Origin"]?.should be_nil
      end
    end

    it "does not add CORS headers when there is no Origin header" do
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        resp = call_api(HTTP::Request.new("GET", "/Api/iam/me"))
        resp.headers["Access-Control-Allow-Origin"]?.should be_nil
      end
    end
  end

  describe "OriginCache invalidation" do
    it "marks the cache stale when `app.App` mutations fire (`mark_stale`)" do
      # Direct unit-level exercise of the invalidation path. A separate
      # integration spec covers the Redis pub/sub subscriber wiring; this
      # test pins the cache's `mark_stale` contract so CORS picks up new
      # origins immediately after invalidation.
      with_db do |db|
        create_test_app(db, "test-app", allowed_origins: ["https://app.example.com"])

        # Warm the cache.
        Facet::OAuth::OriginCache.origin_allowed?("https://app.example.com").should be_true
        Facet::OAuth::OriginCache.origin_allowed?("https://new.example.com").should be_false

        # A new app added between requests is invisible until `mark_stale` runs.
        create_test_app(db, "test-app-2", allowed_origins: ["https://new.example.com"])
        Facet::OAuth::OriginCache.origin_allowed?("https://new.example.com").should be_false

        # The Pub/Sub subscriber (`Event::Subscriber::AppCache`) calls
        # `mark_stale` on every `app.App` mutation — simulate that here.
        Facet::OAuth::OriginCache.mark_stale
        Facet::OAuth::OriginCache.origin_allowed?("https://new.example.com").should be_true
        Facet::OAuth::OriginCache.origin_allowed?("https://app.example.com").should be_true
      end
    end

    it "rebuilds on read when the staleness bound expires (fanout lost)" do
      # A 3 s bound: the in-window document writes must complete inside the
      # bound so the currency hydration they trigger cannot fire a rebuild
      # (with_cache_ttl re-stamps the registry at entry).
      with_cache_ttl(3) do
        with_db do |db|
          # Warm the cache under the bound: the snapshot stamp starts here.
          create_test_app(db, "ttl-app", allowed_origins: ["https://ttl.example.com"])
          Facet::OAuth::OriginCache.origin_allowed?("https://ttl.example.com").should be_true

          # A new app lands in the DB while Redis is down: no fanout fires,
          # so `mark_stale` never runs.
          create_test_app(db, "ttl-app-2", allowed_origins: ["https://after.example.com"])
        end

        # Inside the bound the warm snapshot still serves — the new origin
        # stays invisible.
        Facet::OAuth::OriginCache.origin_allowed?("https://after.example.com").should be_false

        # Past the bound the next read rebuilds from the DB and the origin
        # resolves without any invalidation — the bound caps the outage
        # window instead of letting the stale data persist until restart.
        assert_eventually(timeout: 8.0, interval: 0.05) do
          Facet::OAuth::OriginCache.origin_allowed?("https://after.example.com")
        end
        Facet::OAuth::OriginCache.origin_allowed?("https://ttl.example.com").should be_true
      end
    end
  end
end
