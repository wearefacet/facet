# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Jobs
    # One claimed job row, as returned by `Queries.claim` and `Queries.find`.
    #
    # `attempts` counts claims (incremented on claim, not on outcome), so a
    # first execution carries `attempts = 1`. The worker reads
    # `max_attempts` from the row to decide retry vs. terminal;
    # `backoff` is the per-attempt delay list set at enqueue time (nil =
    # retry immediately).
    record Job,
      id : String,
      kind : String,
      payload : JSON::Any,
      attempts : Int32,
      max_attempts : Int32,
      backoff : Array(Int32)?
  end
end
