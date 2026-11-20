# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http"
require "socket"

module Facet
  module Util
    # Resolves the client IP of one HTTP request. The single input for the
    # login throttle (`IAM::Routes`), the OAuth register/token rate limiters
    # (`OAuth::Routes`), and the telemetry `http.client_ip` attribute.
    #
    # The rule:
    #
    # - The result is always a bare host — never a port. The socket address
    #   carries the ephemeral port (`Socket::IPAddress#to_s` renders
    #   `ip:port`), so keying a counter on it gives every connection a key
    #   of its own and no counter can grow.
    # - The immediate peer is the socket remote address. When the peer is
    #   not a trusted proxy — or no trusted proxy is configured — the peer
    #   host is the result, and `X-Forwarded-For` is ignored. Any client
    #   can set that header to any value; the server reads it only when
    #   the socket peer is on the configured `trusted_proxies` list.
    # - When the peer is a trusted proxy, the header is walked right to
    #   left: trusted hops are skipped, and the first untrusted hop wins —
    #   the client address the nearest trusted proxy saw. No header, or a
    #   chain with no untrusted hop, falls back to the peer host.
    #
    # Comparison is case-insensitive and bracket-free: the peer host and
    # every hop are lowercased, and a hop wrapped in brackets (a bracketed
    # IPv6 literal) loses them. Config entries are bare hosts — no port,
    # no brackets. A hop that carries a port never matches an entry and
    # passes through as the result.
    module ClientIp
      # Returns the client IP for one request, or nil when the request has
      # no IP peer (no socket behind the request, or a non-IP socket such
      # as a Unix socket).
      def self.resolve(
        headers : ::HTTP::Headers,
        remote_address : Socket::Address?,
        trusted_proxies : Array(String),
      ) : String?
        peer = socket_host(remote_address)
        return nil if peer.nil?

        trusted = trusted_proxies.map(&.downcase)
        return peer unless trusted.includes?(peer.downcase)

        hops = forwarded_hops(headers)
        return peer if hops.empty?

        hops.reverse_each do |hop|
          return hop unless trusted.includes?(hop)
        end
        peer
      end

      # The host form of the socket remote address without the port. nil
      # for a missing socket and for non-IP sockets (Unix sockets carry a
      # path, not an address).
      private def self.socket_host(address : Socket::Address?) : String?
        return nil if address.nil?
        return address.address if address.is_a?(Socket::IPAddress)
        nil
      end

      # The `X-Forwarded-For` hops, left to right. `HTTP::Headers#[]?` is
      # case-insensitive and comma-joins repeated headers, so one split
      # covers both shapes.
      private def self.forwarded_hops(headers : ::HTTP::Headers) : Array(String)
        raw = headers["X-Forwarded-For"]?
        return [] of String if raw.nil? || raw.strip.empty?

        raw.split(",").compact_map do |entry|
          host = entry.strip
          host = host[1...host.size - 1] if host.starts_with?('[') && host.ends_with?(']')
          host.empty? ? nil : host.downcase
        end
      end
    end
  end
end
