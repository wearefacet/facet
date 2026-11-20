# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./base_email"

module Facet
  # Outbound password-reset email.
  #
  # Sent when a user requests a password reset via `POST /Api/iam/password-reset/request`.
  # Contains a single-use, time-limited reset link. The validity phrase is
  # derived from `iam.change_password_expiration` by `IAM::Helpers.link_validity_text`
  # and matches the frontend's `PasswordResetScreen.svelte` copy, which derives
  # the same TTL from the request response's `link_ttl_seconds`.
  class PasswordResetEmail < BaseEmail
    def initialize(@email_address : String, @display_name : String, @reset_link : String, @validity : String)
    end

    to @email_address
    subject "Reset your Facet password"
    templates text, html
  end
end
