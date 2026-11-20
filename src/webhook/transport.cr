# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http/client"
require "http/headers"
require "../config"

module Facet
  module Webhook
    # The shared delivery transport: one `HTTP::Client` per POST with the
    # connect + read timeouts from the webhook config. Both the background
    # dispatcher and the test-delivery route run their POSTs through here —
    # the runtime behaviour (timeout sourcing, per-call client) lives once.
    #
    # Both callers keep their own `post` seam (`Dispatcher#post` as an
    # instance method, `Test.post` on the module) so the specs can stub the
    # transport — a subclass override for the dispatcher, a module reopen
    # for the test route — and delegate to this module when unstubbed.
    module Transport
      # One `HTTP::Client` per call, with connect + read timeouts from the
      # config. No real network is expected in tests — the callers stub
      # this seam.
      def self.post(uri : URI, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
        timeout = Facet::Config.instance.webhook.timeout_s.seconds
        client = ::HTTP::Client.new(uri)
        client.connect_timeout = timeout
        client.read_timeout = timeout
        begin
          client.post(uri.request_target, headers: headers, body: body)
        ensure
          client.close
        end
      end

      # Wall time of one POST, in whole milliseconds.
      def self.elapsed_ms(started : Time::Instant) : Int64
        (Time.instant - started).total_milliseconds.to_i64
      end
    end
  end
end
