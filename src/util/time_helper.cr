# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Time / timezone helpers.
    #
    # The application stores every timestamp as UTC in tz‑naive PostgreSQL
    # `timestamp` columns (see `doc/backend/workflow.md` → Time / Timezone).
    # These helpers convert ISO‑8601 strings supplied by clients — which may
    # carry a timezone offset — into a canonical UTC RFC‑3339 form before
    # they reach the database or the JSONB content layer.
    module TimeHelper
      # Normalizes an ISO‑8601 datetime string to its UTC RFC‑3339 form.
      #
      # Returns `nil` if `value` is not a parseable ISO‑8601 datetime.
      # Callers should fall through to their existing error handling in
      # that case (typically a no‑match clause rather than a 500).
      #
      # Crystal's `Time.parse_iso8601` rejects tz‑naive datetime strings
      # ("2025-01-15T10:30:00" raises `Time::Format::Error`), so every
      # accepted input carries an explicit offset and `.to_utc` is a
      # lossless conversion. Example:
      #
      # ```
      # TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00+02:00")
      # # => "2025-01-15T08:30:00Z"
      # ```
      def self.to_utc_rfc3339(value : String) : String?
        parsed = Time.parse_iso8601(value)
        parsed.to_utc.to_rfc3339
      rescue Time::Format::Error
        nil
      end
    end
  end
end
