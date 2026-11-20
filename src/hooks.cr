# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the hooks concern.
#
# Hooks are domain-owned Lua scripts that run automatically when a trigger
# fires. There are two kinds:
#
# - `event` hooks run when a mutation event is observed on a source doctype
#   in another (or the same) domain.
# - `schedule` hooks run on a cron schedule, exactly once per cluster turn,
#   secured by a Redis lease.
#
# Both kinds share execution mechanics (the Sandbox, the `document.*` API,
# OpenTelemetry spans, error capture) and diverge only on the dispatch
# trigger. See `doc/backend/hooks.md`.
module Facet
  module Hooks
    Log = ::Log.for("facet.hooks")
  end
end

require "./hooks/definition"
require "./hooks/validator"
require "./hooks/registry"
require "./hooks/executor"
require "./hooks/handler"
require "./hooks/manager"
