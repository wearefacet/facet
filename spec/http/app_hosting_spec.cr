# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "http"
require "../../src/http/server"
require "../support/http_helper"
require "../support/app_helper"

# Part C — host-based dispatch of app deployments.
#
# Files covered:
#   - src/app/hosting.cr — `App::Hosting::HostCache` (host → app_id,
#     event-invalidated) and the pre-router `Handler` (Facet-host
#     fall-through, exact-match lookup, static serving).
#   - src/app/host_ask.cr — the Caddy On-Demand TLS `ask` endpoint
#     (`GET /Edge/HostAsk?domain=<name>`): `200` for a claimed,
#     non-reserved host, `404` otherwise.
#
# The dispatcher's fixed order: Facet's own hosts win, then an exact
# (never suffix) match against the app's `host` field, then resolution of
# app → active_deployment → files map. Everything else is a bare 404.
# The spa shell fallback answers page loads only (Fetch Metadata
# `navigate` / `nested-navigate`, or no header at all); an asset fetch
# that misses the files map gets a bare 404.

HTTPTest.init

INDEX_HTML = "<!doctype html><html><body>home</body></html>"
APP_JS     = "console.log('hosted');"

def upload_spec_artifact(db, bytes : Bytes, filename : String) : String
  tempfile = File.tempfile("hosting-spec")
  begin
    tempfile.write(bytes)
    tempfile.flush
    tempfile.rewind
    result = Facet::Artifact::Uploader.upload(
      db, tempfile, filename,
      Facet::RBAC::AuthContext.system, "app", "Deployment", "hosting-spec", "files[0].file", nil,
    )
    result.as(Facet::Artifact::Uploader::Result).artifact_id
  ensure
    File.delete?(tempfile.path)
  end
end

# Creates an active app with a host and an active deployment built from
# the given {path → bytes} map. Returns {app, deployment} ids.
def create_hosted_app(db, host : String, files : Hash(String, Bytes | String), spa : Bool = true) : {String, String}
  app_result = Facet::Document::Create.call(
    db, "app", "App",
    %({"slug": "hosted-#{unique_suffix}", "name": "Hosted App", "status": "active", "host": "#{host}"}),
    Facet::RBAC::AuthContext.system,
  )
  app_id = expect_create_success(app_result).projection.id

  file_entries = files.map do |path, bytes|
    artifact_id = bytes.is_a?(Bytes) ? upload_spec_artifact(db, bytes, path) : bytes.as(String)
    %({"path": "#{path}", "file": "#{artifact_id}"})
  end

  deployment_result = Facet::Document::Create.call(
    db, "app", "Deployment",
    %({"app_id": "app.App.#{app_id}", "revision": 1, "spa": #{spa}, "files": [#{file_entries.join(",")}]}),
    Facet::RBAC::AuthContext.system,
    allow_system_writes: true, # revision is read_only
    skip_authorization: true,
  )
  deployment_id = expect_create_success(deployment_result).projection.id

  patch = Facet::Document::Update.call(
    db, "app", "App", app_id,
    %({"active_deployment": "app.Deployment.#{deployment_id}"}),
    Facet::RBAC::AuthContext.system,
  )
  patch.should be_a(Facet::Document::Update::Result)

  # No Redis fanout in specs — rebuild the host cache explicitly, exactly
  # what the AppCache subscriber does on a live `app.App` mutation.
  Facet::App::Hosting::HostCache.reset
  {app_id, deployment_id}
end

def get_with_host(path : String, host : String, fetch_mode : String? = nil) : HTTP::Client::Response
  headers = HTTP::Headers{"Host" => host}
  headers["Sec-Fetch-Mode"] = fetch_mode unless fetch_mode.nil?
  call_api(HTTP::Request.new("GET", path, headers))
end

# The stored, sniffed mime type of the artifact mapped at `path` — the
# response's Content-Type must come from here, never from the client or
# the file extension.
def stored_mime(db, app_id, path) : String
  content = Facet::Mutation::Client.fetch_content(db, "app", "App", app_id)
  deployment_ref = content["active_deployment"].as_s
  deployment_id = deployment_ref.sub("app.Deployment.", "")
  deployment = Facet::Mutation::Client.fetch_content(db, "app", "Deployment", deployment_id)
  artifact_id = deployment["files"].as_a
    .find! { |entry| entry["path"].as_s == path }["file"].as_s
  db.query_one("SELECT mime_type FROM artifacts WHERE id = $1", artifact_id, as: String)
end

describe "app hosting dispatch" do
  before_each do
    with_db { |db| seed_app_doctypes(db) }
    Facet::App::Hosting::HostCache.reset
  end

  it "serves index.html at the root of the app's host" do
    suffix = unique_suffix
    host = "home.app-#{suffix}.example.com"
    app_id, _ = with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice})
    end

    resp = get_with_host("/", host)
    assert_http_status(resp, 200)
    resp.body.should eq(INDEX_HTML)
    with_db { |db| resp.headers["Content-Type"].starts_with?(stored_mime(db, app_id, "index.html")).should be_true }
    resp.headers["X-Content-Type-Options"].should eq("nosniff")
    # The shell revalidates on every navigation — a deploy must be visible
    # on the next load, never up to a max-age later.
    resp.headers["Cache-Control"].should eq("public, no-cache")
  end

  it "serves an exact file path and never a suffix match" do
    host_suffix = unique_suffix
    app_id, _ = with_db do |db|
      create_hosted_app(db, "hr.app-#{host_suffix}.example.com", {
        "index.html"    => INDEX_HTML.to_slice,
        "assets/app.js" => APP_JS.to_slice,
      })
    end
    host = "hr.app-#{host_suffix}.example.com"

    resp = get_with_host("/assets/app.js", host)
    assert_http_status(resp, 200)
    resp.body.should eq(APP_JS)
    with_db { |db| resp.headers["Content-Type"].starts_with?(stored_mime(db, app_id, "assets/app.js")).should be_true }
    # Non-shell assets keep the short shared max-age — "path contains a
    # content hash" is not a contract the deploy surface enforces.
    resp.headers["Cache-Control"].should eq("public, max-age=300")

    # A different registered-looking host never resolves: exact match only.
    resp = get_with_host("/", "evilhr.app-#{host_suffix}.example.com")
    assert_http_status(resp, 404)
  end

  it "falls back to index.html for unknown paths when spa is true, 404s when false" do
    suffix = unique_suffix
    with_db do |db|
      create_hosted_app(db, "spa.app-#{suffix}.example.com", {"index.html" => INDEX_HTML.to_slice}, spa: true)
    end
    resp = get_with_host("/some/client/route", "spa.app-#{suffix}.example.com")
    assert_http_status(resp, 200)
    resp.body.should eq(INDEX_HTML)
    # The SPA fallback serves the shell document — same no-cache policy as
    # the root.
    resp.headers["Cache-Control"].should eq("public, no-cache")

    suffix = unique_suffix
    with_db do |db|
      create_hosted_app(db, "static.app-#{suffix}.example.com", {"index.html" => INDEX_HTML.to_slice}, spa: false)
    end
    resp = get_with_host("/some/path", "static.app-#{suffix}.example.com")
    assert_http_status(resp, 404)
  end

  it "keeps the shell fallback for page loads and 404s asset fetches" do
    suffix = unique_suffix
    host = "nav.app-#{suffix}.example.com"
    app_id, _ = with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice}, spa: true)
    end

    # Page loads keep the fallback: top-level navigation, iframe
    # navigation, and legacy clients that send no Fetch Metadata.
    {"navigate", "nested-navigate", nil}.each do |mode|
      resp = get_with_host("/deep/client/route", host, mode)
      assert_http_status(resp, 200)
      resp.body.should eq(INDEX_HTML)
      with_db do |db|
        resp.headers["Content-Type"].starts_with?(stored_mime(db, app_id, "index.html")).should be_true
      end
    end

    # Asset fetches get an honest miss: 200 HTML under an asset URL is
    # what turned a missing module into a vague MIME failure.
    {"cors", "no-cors", "same-origin", "websocket"}.each do |mode|
      resp = get_with_host("/deep/client/route", host, mode)
      assert_http_status(resp, 404)
      resp.headers["Cache-Control"].should eq("no-store")
    end
  end

  it "serves exact file hits whatever the fetch mode is" do
    suffix = unique_suffix
    host = "asset.app-#{suffix}.example.com"
    with_db do |db|
      create_hosted_app(db, host, {
        "index.html"    => INDEX_HTML.to_slice,
        "assets/app.js" => APP_JS.to_slice,
      }, spa: true)
    end

    resp = get_with_host("/assets/app.js", host, "cors")
    assert_http_status(resp, 200)
    resp.body.should eq(APP_JS)
  end

  it "falls through to the main router on Facet's own hosts" do
    facet_host = Facet::Util::ScriptHelpers.facet_hosts.first
    # /Healthcheck is whitelisted and answers on Facet's own host — if the
    # hosting handler had claimed the request it would be a bare 404.
    resp = get_with_host("/Healthcheck", facet_host)
    assert_http_status(resp, 200)
  end

  it "falls through to the main router on loopback hosts" do
    # Internal SSR fetches (frontend `handleFetch` → BACKEND_URL) reach the
    # backend with an IP Host header — the port is stripped by
    # `HTTP::Request#hostname`. The dispatcher must let the router own
    # these requests; claiming them 404s every SSR page load.
    resp = get_with_host("/Healthcheck", "127.0.0.1:3000")
    assert_http_status(resp, 200)

    # Crystal normalizes the bracketed IPv6 form to `::1`.
    resp = get_with_host("/Healthcheck", "[::1]:3000")
    assert_http_status(resp, 200)
  end

  # B-341 — `Host: localhost` misses the vhost routing when the configured
  # host is another name; the miss must answer a hint, not a bare 404.
  # `localhost` stays outside `LOOPBACK_HOSTS` — the dispatcher never falls
  # through for it, and no app may claim it.
  it "hints at the configured host and the loopback literal on a localhost miss" do
    # Warm the host cache before the config swap — the miss path must not
    # touch the database, and the swapped config carries no database section.
    Facet::App::Hosting::HostCache.app_for_host("warm-#{unique_suffix}.example.com")
    original = Facet::Config.instance
    Facet::Config.instance = Facet::Config.new(
      host: "facet.localhost:3443",
      base_url: "facet.localhost:3443",
      artifact_base_url: "artifacts.localhost:3444",
      artifact_grant_secret: "test-secret",
      cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
    )
    begin
      resp = get_with_host("/Healthcheck", "localhost:3000")
      assert_http_status(resp, 404)
      body = JSON.parse(resp.body)
      body["error"].as_s.should eq("Not found")
      body["hint"].as_s.should contain("facet.localhost")
      # The loopback literal carries the port the caller used.
      body["hint"].as_s.should contain("http://127.0.0.1:3000")
    ensure
      Facet::Config.instance = original
    end
  end

  it "keeps the error field bare for other unknown hosts" do
    resp = get_with_host("/", "random-#{unique_suffix}.example.com")
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should eq("Not found")
  end

  it "hints at the rejected host on an unknown-host miss" do
    host = "random-#{unique_suffix}.example.com"
    resp = get_with_host("/Api/bench/Invoice", host)
    assert_http_status(resp, 404)
    body = JSON.parse(resp.body)
    body["error"].as_s.should eq("Not found")
    # A bare 404 reads as "the API is missing"; the hint names the rejected
    # Host header and the config keys the set comes from.
    body["hint"].as_s.should contain(host)
    body["hint"].as_s.should contain("configured host set")
  end

  it "404s unknown hosts, unregistered paths, and inactive apps" do
    # An arbitrary Host header never reaches a document query result.
    resp = get_with_host("/", "random-#{unique_suffix}.example.com")
    assert_http_status(resp, 404)

    suffix = unique_suffix
    app_id, _ = with_db do |db|
      create_hosted_app(db, "gone.app-#{suffix}.example.com", {"index.html" => INDEX_HTML.to_slice}, spa: false)
    end

    # Known host, unknown path, spa=false → 404.
    resp = get_with_host("/no/such/file.html", "gone.app-#{suffix}.example.com")
    assert_http_status(resp, 404)

    # A disabled app stops serving (after the cache sees the mutation).
    with_db do |db|
      result = Facet::Document::Update.call(
        db, "app", "App", app_id,
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Document::Update::Result)
    end
    Facet::App::Hosting::HostCache.reset
    resp = get_with_host("/", "gone.app-#{suffix}.example.com")
    assert_http_status(resp, 404)
  end

  it "rebuilds the host cache on invalidation (no restart needed)" do
    suffix = unique_suffix
    host = "late.app-#{suffix}.example.com"

    # The host is unknown before the app exists.
    resp = get_with_host("/", host)
    assert_http_status(resp, 404)

    with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice})
    end

    # After the invalidation the same host serves without a restart.
    resp = get_with_host("/", host)
    assert_http_status(resp, 200)
  end

  it "resolves a new host on read once the staleness bound expires (fanout lost)" do
    suffix = unique_suffix
    warm_host = "warm.app-#{suffix}.example.com"
    late_host = "lost.app-#{suffix}.example.com"

    # A 3 s bound: the in-window document writes must complete inside the
    # bound so the currency hydration they trigger cannot fire a rebuild
    # (with_cache_ttl re-stamps the registry at entry).
    with_cache_ttl(3) do
      with_db do |db|
        # Warm the cache under the one-second bound: `create_hosted_app`
        # ends with a `HostCache.reset`, so the read below rebuilds and
        # stamps the snapshot here.
        create_hosted_app(db, warm_host, {"index.html" => INDEX_HTML.to_slice})
        Facet::App::Hosting::HostCache.app_for_host(warm_host).should_not be_nil

        # A second app claims its host while Redis is down: no fanout
        # fires, so `mark_stale` never runs. Raw document create — the
        # helper's trailing cache reset would stand in for the lost
        # fanout and defeat the test.
        app_result = Facet::Document::Create.call(
          db, "app", "App",
          %({"slug": "lost-#{suffix}", "name": "Lost App", "status": "active", "host": "#{late_host}"}),
          Facet::RBAC::AuthContext.system,
        )
        expect_create_success(app_result)
      end

      # Inside the bound the warm snapshot still serves.
      Facet::App::Hosting::HostCache.app_for_host(late_host).should be_nil

      # Past the bound the next read rebuilds from the DB and the host
      # resolves without any invalidation.
      assert_eventually(timeout: 8.0, interval: 0.05) do
        !Facet::App::Hosting::HostCache.app_for_host(late_host).nil?
      end
    end
  end

  it "404s when the app's active deployment is deleted" do
    suffix = unique_suffix
    _, deployment_id = with_db do |db|
      create_hosted_app(db, "tomb.app-#{suffix}.example.com", {"index.html" => INDEX_HTML.to_slice})
    end

    with_db do |db|
      result = Facet::Document::Delete.call(db, "app", "Deployment", deployment_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)
    end
    Facet::App::Hosting::HostCache.reset

    resp = get_with_host("/", "tomb.app-#{suffix}.example.com")
    assert_http_status(resp, 404)
  end
end

describe "HostAsk endpoint (Caddy on-demand TLS)" do
  before_each do
    with_db { |db| seed_app_doctypes(db) }
    Facet::App::Hosting::HostCache.reset
  end

  it "answers 200 for a claimed host" do
    suffix = unique_suffix
    host = "ask.app-#{suffix}.example.com"
    with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice})
    end

    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{host}"))
    assert_http_status(resp, 200)
  end

  it "answers 404 for an unknown host and a missing parameter" do
    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=unknown-#{unique_suffix}.example.com"))
    assert_http_status(resp, 404)

    # No `domain` parameter at all — Caddy always sends one, but the
    # endpoint must not crash on a malformed call.
    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk"))
    assert_http_status(resp, 404)
  end

  it "answers 404 for a reserved Facet host even when unclaimed" do
    # The loopback literals, the compose service name, and the configured
    # host: the main vhost owns these — on-demand issuance must never
    # fire for them.
    ["127.0.0.1", "backend", Facet::Util::ScriptHelpers.facet_hosts.first].each do |reserved|
      resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{reserved}"))
      assert_http_status(resp, 404)
    end
  end

  it "answers 404 for an inactive app's host" do
    suffix = unique_suffix
    host = "disabled.app-#{suffix}.example.com"
    app_id, _ = with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice})
    end
    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{host}"))
    assert_http_status(resp, 200)

    with_db do |db|
      result = Facet::Document::Update.call(
        db, "app", "App", app_id,
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Document::Update::Result)
    end
    Facet::App::Hosting::HostCache.reset
    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{host}"))
    assert_http_status(resp, 404)
  end

  it "normalizes the queried name (case, port) like the host cache does" do
    suffix = unique_suffix
    host = "norm.app-#{suffix}.example.com"
    with_db do |db|
      create_hosted_app(db, host, {"index.html" => INDEX_HTML.to_slice})
    end

    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{host.upcase}"))
    assert_http_status(resp, 200)

    # Caddy sends a bare SNI name (no port, no scheme) — the parameter
    # must survive a defensively-prefixed value unchanged.
    resp = call_api(HTTP::Request.new("GET", "/Edge/HostAsk?domain=#{host}:443"))
    assert_http_status(resp, 200)
  end
end
