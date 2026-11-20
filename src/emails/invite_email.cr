# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./base_email"

module Facet
  # Outbound account-invite email.
  #
  # Sent when an operator invites an account through
  # `POST /Api/iam/accounts/:id/invite`. Contains a single-use, time-limited
  # link to `/ResetPassword` where the recipient sets their first password.
  # The link TTL is `iam.change_password_expiration` (default 24 hours);
  # the validity phrase is derived from it by `IAM::Helpers.link_validity_text`.
  class InviteEmail < BaseEmail
    def initialize(@email_address : String, @display_name : String, @invite_link : String, @validity : String)
    end

    to @email_address
    subject "Set your Facet password"
    templates text, html
  end
end
