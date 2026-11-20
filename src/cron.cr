# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the cron concern.
#
# Wraps the `cron_parser` shard and provides a fiber-based scheduler that
# fires registered tasks at their next cron-computed instant. See
# `doc/backend/cron.md`.
module Facet
  module Cron
    Log = ::Log.for("facet.cron")
  end
end

require "./cron/parser"
require "./cron/scheduler"
require "./cron/lease"
