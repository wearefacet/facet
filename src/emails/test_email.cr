# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./base_email"

module Facet
  # The outbound mail-connector probe.
  #
  # Sent by the platform settings page (`POST /Api/SystemSettings/mail/test`)
  # so an operator can prove the saved mail connector works before users
  # depend on it — password resets, invites, and MFA links all ride it.
  #
  # The message goes through the standard `BaseEmail` path, so it uses the
  # effective adapter and From header (`SystemSettings::MailView`) exactly
  # like a real email. `adapter_name` names the saved adapter in the body,
  # so a delivery that reaches the wrong transport is visible in the inbox.
  class TestEmail < BaseEmail
    def initialize(@email_address : String, @adapter_name : String, @sent_at : String)
    end

    to @email_address
    subject "Facet test email"
    templates text, html
  end
end
