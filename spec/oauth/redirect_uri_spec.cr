# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/redirect_uri"

# `OAuth::RedirectUri` — the `app.App` `redirect_uris` request-time match,
# and the OAuth-facing delegates to the shared shape rule
# (`Util::RedirectUri`).
#
# Shared shape rule (B-154): absolute `https` on any host, or absolute
# `http` on a loopback host only (`localhost`, any `*.localhost`
# subdomain, `127.0.0.1`, `::1`); no fragment, no userinfo, no query; the
# only permitted wildcard is a `*` port on an http loopback host
# (RFC 8252 §7.3 — the OS assigns the local listener's port).
#
# Request-time match: exact string equality on any entry, plus the
# wildcard rule — same scheme + loopback host, any port (including the
# default / absent one); a registered path pins the presented path.
describe Facet::OAuth::RedirectUri do
  describe "valid_shape?" do
    it "accepts absolute https URIs" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/cb").should be_true
    end

    it "accepts http on a loopback host (development)" do
      Facet::OAuth::RedirectUri.valid_shape?("http://localhost:5173/auth/cb").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://facet.localhost:5173/auth/cb").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://127.0.0.1:5173/cb").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://[::1]:5173/cb").should be_true
    end

    it "accepts the loopback wildcard port" do
      Facet::OAuth::RedirectUri.valid_shape?("http://localhost:*").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://facet.localhost:*").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://127.0.0.1:*").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://[::1]:*").should be_true
      Facet::OAuth::RedirectUri.valid_shape?("http://localhost:*/auth/cb").should be_true
    end

    it "accepts a URI without a port or path" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com").should be_true
    end

    it "rejects http on a non-loopback host (B-154)" do
      Facet::OAuth::RedirectUri.valid_shape?("http://public.example.com/cb").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("http://app.example.com").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("http://localhost.evil.com/cb").should be_false
    end

    it "rejects a wildcard on a non-loopback host" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com:*").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("http://app.example.com:*").should be_false
    end

    it "rejects a wildcard anywhere but the port" do
      Facet::OAuth::RedirectUri.valid_shape?("https://*.example.com/cb").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/cb/*").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("http*://app.example.com/cb").should be_false
    end

    it "rejects a https wildcard even on loopback" do
      Facet::OAuth::RedirectUri.valid_shape?("https://localhost:*").should be_false
    end

    it "rejects a fragment and a query" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/cb#x").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/cb?a=1").should be_false
    end

    it "rejects userinfo" do
      Facet::OAuth::RedirectUri.valid_shape?("https://user@app.example.com/cb").should be_false
    end

    it "rejects a missing authority" do
      Facet::OAuth::RedirectUri.valid_shape?("https:///cb").should be_false
    end

    it "rejects an invalid or oversized port" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com:99999/cb").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com:/cb").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com:80a/cb").should be_false
    end

    it "rejects whitespace and control characters" do
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/cb x").should be_false
      Facet::OAuth::RedirectUri.valid_shape?("https://app.example.com/\n").should be_false
    end
  end

  describe "match?" do
    it "matches an exact registered entry" do
      registered = ["https://app.example.com/cb"]
      Facet::OAuth::RedirectUri.match?(registered, "https://app.example.com/cb").should be_true
    end

    it "rejects an unregistered URI" do
      registered = ["https://app.example.com/cb"]
      Facet::OAuth::RedirectUri.match?(registered, "https://attacker.com/cb").should be_false
    end

    it "matches any port against a wildcard loopback entry" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/callback").should be_true
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:49152/callback").should be_true
    end

    it "matches the IP-literal loopback wildcard entries" do
      Facet::OAuth::RedirectUri.match?(["http://127.0.0.1:*"], "http://127.0.0.1:4000/callback").should be_true
      Facet::OAuth::RedirectUri.match?(["http://[::1]:*"], "http://[::1]:4000/callback").should be_true
    end

    it "matches any port against a *.localhost wildcard entry" do
      registered = ["http://facet.localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://facet.localhost:5173/callback").should be_true
      Facet::OAuth::RedirectUri.match?(registered, "http://api.localhost:5173/callback").should be_false
    end

    it "matches a port-less presented URI against a wildcard entry" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost/callback").should be_true
    end

    it "honours a pinned path on a wildcard entry" do
      registered = ["http://localhost:*/auth/cb"]
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/auth/cb").should be_true
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/callback").should be_false
    end

    it "matches any path when the wildcard entry carries none" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/anything/goes").should be_true
    end

    it "rejects a host mismatch against a wildcard entry" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://127.0.0.1:5173/callback").should be_false
      Facet::OAuth::RedirectUri.match?(registered, "http://evil.com:5173/callback").should be_false
    end

    it "rejects a scheme mismatch against a wildcard entry" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "https://localhost:5173/callback").should be_false
    end

    it "rejects a query or fragment in the presented URI" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/cb?a=1").should be_false
      Facet::OAuth::RedirectUri.match?(registered, "http://localhost:5173/cb#x").should be_false
    end

    it "matches case-insensitively on the host" do
      registered = ["http://localhost:*"]
      Facet::OAuth::RedirectUri.match?(registered, "http://LOCALHOST:5173/callback").should be_true
    end
  end

  describe "https_or_loopback?" do
    it "accepts https on any host" do
      Facet::OAuth::RedirectUri.https_or_loopback?("https://app.example.com/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("https://localhost/cb").should be_true
    end

    it "accepts http on a loopback host" do
      Facet::OAuth::RedirectUri.https_or_loopback?("http://localhost:8765/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("http://facet.localhost:8765/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("http://127.0.0.1:8765/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("http://[::1]:8765/cb").should be_true
    end

    it "accepts the wildcard-port loopback form" do
      Facet::OAuth::RedirectUri.https_or_loopback?("http://localhost:*/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("http://facet.localhost:*/cb").should be_true
      Facet::OAuth::RedirectUri.https_or_loopback?("http://127.0.0.1:*/cb").should be_true
    end

    it "rejects http on a non-loopback host" do
      Facet::OAuth::RedirectUri.https_or_loopback?("http://app.example.com/cb").should be_false
      Facet::OAuth::RedirectUri.https_or_loopback?("http://intranet.local/cb").should be_false
    end

    it "rejects a non-http(s) scheme and an unparseable entry" do
      Facet::OAuth::RedirectUri.https_or_loopback?("ftp://app.example.com/cb").should be_false
      Facet::OAuth::RedirectUri.https_or_loopback?("not a uri").should be_false
    end
  end
end
