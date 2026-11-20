# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the webhook concern.
#
# Webhooks are outbound HTTP registrations (`core.Webhook` documents) that
# fire on mutations of a source doctype and deliver a signed event
# envelope to a target URL. See `doc/backend/webhook.md`.
module Facet
  module Webhook
    Log = ::Log.for("facet.webhook")
  end
end

require "./webhook/config"
require "./webhook/registry"
require "./webhook/auth_check"
require "./webhook/dispatcher"
require "./webhook/calls"
require "./webhook/manager"
