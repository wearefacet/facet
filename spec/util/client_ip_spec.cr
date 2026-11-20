# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/client_ip"

# Builds request headers carrying one optional X-Forwarded-For value.
private def headers_with(xff : String?) : HTTP::Headers
  h = HTTP::Headers.new
  h["X-Forwarded-For"] = xff if xff
  h
end

# Tests for Facet::Util::ClientIp.
#
# Pure-logic coverage of the client-IP resolution rule: the socket host
# without the port, `X-Forwarded-For` only behind a configured trusted
# proxy, right-to-left walk that skips trusted hops.
describe Facet::Util::ClientIp do
  it "returns the socket host without the port when the peer is not trusted" do
    peer = Socket::IPAddress.new("172.25.0.6", 43050)
    Facet::Util::ClientIp.resolve(headers_with(nil), peer, [] of String)
      .should eq("172.25.0.6")
  end

  it "ignores X-Forwarded-For when no trusted proxy is configured" do
    peer = Socket::IPAddress.new("172.25.0.6", 43050)
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9"), peer, [] of String)
      .should eq("172.25.0.6")
  end

  it "ignores X-Forwarded-For when the peer is not a trusted proxy" do
    peer = Socket::IPAddress.new("172.25.0.6", 43050)
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9"), peer, ["127.0.0.1"])
      .should eq("172.25.0.6")
  end

  it "returns the single hop for a trusted peer" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9"), peer, ["127.0.0.1"])
      .should eq("203.0.113.9")
  end

  it "walks a multi-hop chain right to left and returns the first untrusted hop" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    trusted = ["127.0.0.1", "10.0.0.2"]
    # Chain: client → 10.0.0.2 → 127.0.0.1 (peer). The walk skips 127.0.0.1,
    # skips 10.0.0.2, and lands on the client address.
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9, 10.0.0.2"), peer, trusted)
      .should eq("203.0.113.9")
  end

  it "stops at the first untrusted hop — deeper hops stay unread" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    # The rightmost hop is a client, not a proxy; the forged entries to its
    # left must never win.
    Facet::Util::ClientIp.resolve(headers_with("6.6.6.6, 203.0.113.9"), peer, ["127.0.0.1"])
      .should eq("203.0.113.9")
  end

  it "falls back to the peer host when every hop is trusted" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    trusted = ["127.0.0.1", "10.0.0.2"]
    # A chain with no client hop names no client.
    Facet::Util::ClientIp.resolve(headers_with("10.0.0.2"), peer, trusted)
      .should eq("127.0.0.1")
  end

  it "falls back to the peer host when a trusted peer sends no header" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    Facet::Util::ClientIp.resolve(headers_with(nil), peer, ["127.0.0.1"])
      .should eq("127.0.0.1")
  end

  it "falls back to the peer host when the header is blank" do
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    Facet::Util::ClientIp.resolve(headers_with("  "), peer, ["127.0.0.1"])
      .should eq("127.0.0.1")
  end

  it "strips brackets and lowercases an IPv6 hop" do
    peer = Socket::IPAddress.new("::1", 43050)
    Facet::Util::ClientIp.resolve(headers_with("[2001:DB8::10]"), peer, ["::1"])
      .should eq("2001:db8::10")
  end

  it "skips a trusted bracketed IPv6 hop and falls back to the peer" do
    peer = Socket::IPAddress.new("::1", 43050)
    trusted = ["::1", "2001:db8::10"]
    Facet::Util::ClientIp.resolve(headers_with("[2001:DB8::10]"), peer, trusted)
      .should eq("::1")
  end

  it "comma-joins repeated headers into one chain" do
    h = HTTP::Headers.new
    h.add("X-Forwarded-For", "203.0.113.9")
    h.add("X-Forwarded-For", "10.0.0.2")
    peer = Socket::IPAddress.new("127.0.0.1", 43050)
    trusted = ["127.0.0.1", "10.0.0.2"]
    Facet::Util::ClientIp.resolve(h, peer, trusted).should eq("203.0.113.9")
  end

  it "returns nil when the request has no socket peer" do
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9"), nil, ["127.0.0.1"])
      .should be_nil
  end

  it "returns nil for a non-IP socket (Unix socket deployment)" do
    peer = Socket::UNIXAddress.new("/tmp/facet.sock")
    Facet::Util::ClientIp.resolve(headers_with("203.0.113.9"), peer, ["127.0.0.1"])
      .should be_nil
  end
end
