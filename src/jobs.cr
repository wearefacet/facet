# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the background-jobs concern.
#
# A PostgreSQL-only job queue: callers enqueue rows in `background_jobs`,
# a worker claims due rows and runs the matching handler.
# See `doc/backend/jobs.md`.
module Facet
  module Jobs
    Log = ::Log.for("facet.jobs")
  end
end

require "./jobs/config"
require "./jobs/job"
require "./jobs/handler"
require "./jobs/liveness"
require "./jobs/queries"
require "./jobs/worker"
require "./jobs/manager"
