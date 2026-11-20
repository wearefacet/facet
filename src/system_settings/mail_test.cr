# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"
require "../emails/test_email"
require "./views"

module Facet
  module SystemSettings
    # The "Send test email" action behind the platform settings page.
    #
    # One synchronous delivery through the **saved** connector: the probe
    # email rides the standard `BaseEmail` path, so `before_send` rebuilds
    # the adapter from `MailView` — the effective document-over-file
    # settings — exactly like a password reset or an invite. Pending edits
    # in the form do not participate; the operator saves first.
    #
    # Blocking by decision: the operator waits for the transport, and the
    # transport error comes back as the message. That is the whole point of
    # the action — "connection refused" or "535 authentication failed" is
    # the diagnostic. The caller is a human on an admin page, not a request
    # path, so a slow SMTP connect does not cost throughput.
    #
    # Facet-side rejections answer `422` (the connector turned off, a
    # malformed address); a delivery failure answers `502` with the
    # transport message.
    #
    # `deliver` is the seam a spec replaces to observe or fail the send
    # without a live SMTP server: it receives the built `TestEmail` and
    # runs the standard `deliver` (which rebuilds the adapter from the
    # settings) unless a caller supplies its own.
    module MailTest
      # A plain address shape check — the probe only needs to refuse
      # obvious typos before opening a connection. Full RFC 5322 parsing
      # buys nothing here: the SMTP server is the authority on whether an
      # address exists.
      ADDRESS_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      # Runs one test delivery. Returns the resolved adapter name and From
      # address on success, or the `ServiceError` to render.
      def self.call(
        db : DB::Connection,
        address : String,
        deliver : TestEmail -> Nil = ->(email : TestEmail) { email.deliver; nil },
      ) : Result | Facet::ServiceError
        mail = MailView.build(db)

        # `dev` is the "no email" posture the settings page offers (its label
        # is "none (no email)"): it prints to stdout and never reaches a
        # recipient. A test there proves nothing about delivery, so the probe
        # refuses instead of reporting a success that no inbox received.
        if mail.adapter == "dev"
          return Facet::ServiceError.new(
            422,
            "The email connector is off: the 'dev' adapter prints to stdout and " \
            "delivers nothing. Set mail.adapter to smtp and save before testing",
            [ValidationError.new(field: "mail.adapter", message: "is 'dev' — Facet sends no email",
              code: "invalid_format")],
          )
        end

        unless address.matches?(ADDRESS_RE)
          return Facet::ServiceError.new(
            422,
            "Recipient address is not a valid email address",
            [ValidationError.new(field: "to", message: "is not a valid email address",
              code: "invalid_format")],
          )
        end

        begin
          deliver.call(TestEmail.new(address, mail.adapter, Time.utc.to_s("%F %T UTC")))
        rescue ex : Exception
          # The transport is the remote authority: report what it said. The
          # route turns this into a `502` — the failure is upstream, not a
          # bad request.
          return Facet::ServiceError.new(502, "Mail delivery failed: #{ex.message}")
        end

        Result.new(adapter: mail.adapter, from_address: mail.from_address, to: address)
      end

      # What the settings page shows on success: which transport carried the
      # probe and which From header it carried.
      record Result,
        adapter : String,
        from_address : String,
        to : String
    end
  end
end
