# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http/client"
require "http/headers"
require "openssl"
require "socket"
require "../config"
require "./target_check"

module Facet
  module Webhook
    # The shared delivery transport: one POST per call with the connect +
    # read timeouts from the webhook config. Both the background dispatcher
    # and the test-delivery route run their POSTs through here — the runtime
    # behaviour (timeout sourcing, per-call connection) lives once.
    #
    # Both callers keep their own `post` seam (`Dispatcher#post` as an
    # instance method, `Test.post` on the module) so the specs can stub the
    # transport — a subclass override for the dispatcher, a module reopen
    # for the test route — and delegate to this module when unstubbed.
    #
    # ## Pinned dial (S9)
    #
    # The target gate resolves the webhook host once. A second, independent
    # resolution at dial time lets a rebinding resolver answer public at
    # check time and private at dial time. To close that window the transport
    # resolves the host again through the gate (`TargetCheck.checked_address`)
    # and dials the address it returns, while keeping the original hostname
    # for the TLS SNI and the `Host` header. A hostname-only allowlist entry
    # (no DNS at check time) has no address to pin to; the transport then
    # falls back to a plain `HTTP::Client`, which is the operator-approved
    # internal case.
    module Transport
      # One POST with connect + read timeouts from the config. No real
      # network is expected in tests — the callers stub this seam.
      def self.post(uri : URI, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
        timeout = Facet::Config.instance.webhook.timeout_s.seconds
        if address = TargetCheck.checked_address(uri.to_s)
          post_pinned(uri, address, body, headers, timeout)
        else
          post_unpinned(uri, body, headers, timeout)
        end
      end

      # Wall time of one POST, in whole milliseconds.
      def self.elapsed_ms(started : Time::Instant) : Int64
        (Time.instant - started).total_milliseconds.to_i64
      end

      # Dials the checked address while presenting the original hostname: the
      # TCP socket connects to `address`, the TLS client sets SNI and verifies
      # the certificate against the URL host, and the `Host` header carries
      # the URL host. The `Host` header is set here only when the caller has
      # not supplied one — the signing path never sets `Host`, so the check is
      # belt-and-braces.
      private def self.post_pinned(
        uri : URI,
        address : Socket::IPAddress,
        body : String,
        headers : ::HTTP::Headers,
        timeout : Time::Span,
      ) : ::HTTP::Client::Response
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        host = uri.host || ""
        socket = TCPSocket.new(address.address, port, connect_timeout: timeout)
        begin
          if uri.scheme == "https"
            context = OpenSSL::SSL::Context::Client.new
            io = OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: host)
          else
            io = socket
          end
          post_on(io, uri, host, body, headers, timeout)
        ensure
          socket.close
        end
      end

      # Sends the request on an already-open socket and reads the response.
      # A fresh `HTTP::Client` per call over the pinned socket keeps the
      # timeout handling in one place (the stdlib client cannot dial a fixed
      # address).
      private def self.post_on(
        io : IO,
        uri : URI,
        host : String,
        body : String,
        headers : ::HTTP::Headers,
        timeout : Time::Span,
      ) : ::HTTP::Client::Response
        effective = ::HTTP::Headers.new
        headers.each { |name, values| values.each { |v| effective.add(name, v) } }
        effective["Host"] ||= host
        client = ::HTTP::Client.new(io)
        client.connect_timeout = timeout
        client.read_timeout = timeout
        client.post(uri.request_target, headers: effective, body: body)
      end

      # The unpinned fallback: the host resolves at dial time. Reached only
      # when the gate has no address to pin (a hostname-only allowlist entry
      # that does not resolve, or a rejected host — which the callers'
      # `TargetCheck.check` already refused before reaching this module).
      private def self.post_unpinned(
        uri : URI,
        body : String,
        headers : ::HTTP::Headers,
        timeout : Time::Span,
      ) : ::HTTP::Client::Response
        client = ::HTTP::Client.new(uri)
        client.connect_timeout = timeout
        client.read_timeout = timeout
        begin
          client.post(uri.request_target, headers: headers, body: body)
        ensure
          client.close
        end
      end
    end
  end
end
