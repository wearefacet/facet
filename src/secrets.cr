# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the secret store concern.
#
# Durable secrets keyed by document + slot, stored out-of-band from the
# event-sourced doctype system. Three semantic modes — `hash`, `sealed`,
# `token` — select the consumer operation.
module Facet
  module Secrets
    Log = ::Log.for("facet.secrets")
  end
end

require "./secrets/config"
require "./secrets/codec"
require "./secrets/store"
require "./secrets/staging"
require "./secrets/adoption"
