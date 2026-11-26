# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/websocket/route"
require "../support/oauth_helper"

# Terminal spy for HandshakeHandler unit specs — records that the chain
# reached the end without running any real upgrade logic.
private class WsHandshakeSpy
  include ::HTTP::Handler

  getter? ran : Bool = false

  def call(context : ::HTTP::Server::Context) : Nil
    @ran = true
  end
end

# Builds an upgrade-shaped context: GET + Upgrade + optional protocol list.
private def ws_upgrade_context(path : String, protocols : String?) : ::HTTP::Server::Context
  headers = ::HTTP::Headers{"Upgrade" => "websocket"}
  headers["Sec-WebSocket-Protocol"] = protocols if protocols
  request = ::HTTP::Request.new("GET", path, headers: headers)
  ::HTTP::Server::Context.new(request, ::HTTP::Server::Response.new(IO::Memory.new))
end

# Drives the handler with a recording handler at the end of the chain.
private def run_handshake(context : ::HTTP::Server::Context) : Nil
  spy = WsHandshakeSpy.new
  handler = Facet::Websocket::Route::HandshakeHandler.new
  handler.next = spy
  handler.call(context)
  spy.ran?.should be_true
end

describe Facet::Websocket::Route do
  # `Facet::Websocket::Route.build_origin_regex` builds the allowlist pattern the
  # `/Ws` upgrade handler matches the browser `Origin` header against.
  # `Config.instance.host` may carry a scheme (e.g. `https://localhost:3443`,
  # the dev Caddy proxy shape) — the regex must normalise it, or no real
  # origin matches and every upgrade is rejected with close 4403.
  #
  # These cases exercise the regex through its public `host` argument so they do
  # not depend on which `config.{env}.yml` happens to be loaded (the test env has
  # no `host:` key and falls back to the scheme-less `localhost:3000` default,
  # which would not surface the scheme-bearing case).
  #
  # The `.origin_allowed?` cases cover the app-origin half of the allowlist an
  # active `app.App` contributes through `OAuth::OriginCache`. The handshake-
  # handler cases cover the `Sec-WebSocket-Protocol` token transport: the token
  # entry is stripped from the offered list, answered with the contract protocol
  # name, and carried in the context store for the upgrade block.
  describe ".build_origin_regex" do
    # ── scheme-bearing host ──────────────────────────────────────────

    it "accepts an origin equal to a scheme-bearing host" do
      regex = Facet::Websocket::Route.build_origin_regex("https://localhost:3443")
      "https://localhost:3443".should match(regex)
    end

    it "accepts the http variant of a scheme-bearing host" do
      regex = Facet::Websocket::Route.build_origin_regex("https://localhost:3443")
      "http://localhost:3443".should match(regex)
    end

    it "rejects an origin whose host differs from a scheme-bearing host" do
      regex = Facet::Websocket::Route.build_origin_regex("https://localhost:3443")
      "https://evil.example".should_not match(regex)
    end

    it "rejects an origin that re-prefixes the scheme (the old bug)" do
      # The pre-fix regex produced `^https?://https://localhost:3443…$`, which
      # would have matched a hypothetical `https://https://localhost:3443`
      # origin but never the real one. Guard against the pattern regressing:
      # the double-scheme form must NOT be accepted.
      regex = Facet::Websocket::Route.build_origin_regex("https://localhost:3443")
      "https://https://localhost:3443".should_not match(regex)
    end

    # ── scheme-less host (legacy form, still valid) ───────────────────────

    it "accepts an origin equal to a scheme-less host" do
      regex = Facet::Websocket::Route.build_origin_regex("localhost:3000")
      "https://localhost:3000".should match(regex)
    end

    it "accepts an http origin for a scheme-less host" do
      regex = Facet::Websocket::Route.build_origin_regex("localhost:3000")
      "http://localhost:3000".should match(regex)
    end

    it "accepts an origin carrying an explicit port when the host omits one" do
      # Host configured without a port (`example.com`) still matches origins
      # that supply the default port — the optional `(:\d+)?` clause covers it.
      regex = Facet::Websocket::Route.build_origin_regex("example.com")
      "https://example.com:443".should match(regex)
    end

    it "escapes regex metacharacters in the host" do
      # A `.` in the host must stay literal. `exampleXcom` (same letters, no
      # dot) would match if the `.` were unescaped; it must be rejected.
      regex = Facet::Websocket::Route.build_origin_regex("example.com")
      "https://exampleXcom".should_not match(regex)
    end
  end

  describe ".origin_allowed?" do
    # Config-host cases are pure regex composition — no DB. The app-origin
    # cases seed a live `app.App` and go through `OAuth::OriginCache`.
    before_each do
      with_db { |db| seed_app_doctypes(db) }
    end

    around_each do |example|
      Facet::OAuth::OriginCache.reset
      begin
        example.run
      ensure
        Facet::OAuth::OriginCache.reset
      end
    end

    it "allows the configured host origin without touching the cache" do
      regex = Facet::Websocket::Route.build_origin_regex("localhost:3000")
      Facet::Websocket::Route.origin_allowed?("http://localhost:3000", regex).should be_true
    end

    it "allows an origin registered on an active app" do
      with_db do |db|
        create_test_app(db, "ws-origin-app", allowed_origins: ["https://hr.apps.example"], host: "hr.apps.example")

        regex = Facet::Websocket::Route.build_origin_regex("localhost:3000")
        Facet::Websocket::Route.origin_allowed?("https://hr.apps.example", regex).should be_true
      end
    end

    it "rejects an origin not registered anywhere" do
      with_db do |db|
        create_test_app(db, "ws-origin-app", allowed_origins: ["https://hr.apps.example"], host: "hr.apps.example")

        regex = Facet::Websocket::Route.build_origin_regex("localhost:3000")
        Facet::Websocket::Route.origin_allowed?("https://evil.example", regex).should be_false
      end
    end

    it "rejects an origin of a disabled app (the cache only mirrors active apps)" do
      with_db do |db|
        app_id, _client = create_test_app(db, "ws-origin-app",
          allowed_origins: ["https://hr.apps.example"], host: "hr.apps.example")

        Facet::Websocket::Route.origin_allowed?("https://hr.apps.example",
          Facet::Websocket::Route.build_origin_regex("localhost:3000")).should be_true

        Facet::Document::Update.call(
          db, "app", "App", app_id,
          %({"status": "disabled"}),
          Facet::RBAC::AuthContext.system,
        )
        Facet::OAuth::OriginCache.reset

        Facet::Websocket::Route.origin_allowed?("https://hr.apps.example",
          Facet::Websocket::Route.build_origin_regex("localhost:3000")).should be_false
      end
    end
  end

  describe "HandshakeHandler" do
    it "strips the token entry, echoes the protocol name, and stashes the token" do
      token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhY2MifQ.a-b_c3signature"
      ctx = ws_upgrade_context("/Ws", "#{Facet::Websocket::Route::TOKEN_PROTOCOL},#{token}")

      run_handshake(ctx)

      ctx.request.headers["Sec-WebSocket-Protocol"].should eq(Facet::Websocket::Route::TOKEN_PROTOCOL)
      ctx.response.headers["Sec-WebSocket-Protocol"]?.should eq(Facet::Websocket::Route::TOKEN_PROTOCOL)
      ctx.get?(Facet::Websocket::Route::CONTEXT_TOKEN_KEY).should eq(token)
    end

    it "leaves a protocol-only offer untouched (no token, no echo)" do
      ctx = ws_upgrade_context("/Ws", "#{Facet::Websocket::Route::TOKEN_PROTOCOL}")

      run_handshake(ctx)

      ctx.request.headers["Sec-WebSocket-Protocol"].should eq(Facet::Websocket::Route::TOKEN_PROTOCOL)
      ctx.response.headers["Sec-WebSocket-Protocol"]?.should be_nil
      ctx.get?(Facet::Websocket::Route::CONTEXT_TOKEN_KEY).should be_nil
    end

    it "leaves unrelated protocol offers untouched (cookie/header auth path)" do
      ctx = ws_upgrade_context("/Ws", "v1.chat, json")

      run_handshake(ctx)

      ctx.request.headers["Sec-WebSocket-Protocol"].should eq("v1.chat, json")
      ctx.response.headers["Sec-WebSocket-Protocol"]?.should be_nil
      ctx.get?(Facet::Websocket::Route::CONTEXT_TOKEN_KEY).should be_nil
    end

    it "ignores non-upgrade paths entirely" do
      ctx = ws_upgrade_context("/Api/crm/Company", "#{Facet::Websocket::Route::TOKEN_PROTOCOL},eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhY2MifQ.sig")

      run_handshake(ctx)

      ctx.get?(Facet::Websocket::Route::CONTEXT_TOKEN_KEY).should be_nil
      ctx.response.headers["Sec-WebSocket-Protocol"]?.should be_nil
    end
  end
end
