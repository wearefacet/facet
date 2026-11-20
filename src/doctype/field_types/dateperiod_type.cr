# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a calendar-date range — a bounded interval between two
    # ISO‑8601 calendar dates. Stored as a JSONB object `{"start": "...",
    # "end": "..."}` with both bounds required and inclusive on both ends.
    #
    # Indexing uses a PostgreSQL GiST expression index over
    # `daterange((content#>>'{f,start}')::date,
    # (content#>>'{f,end}')::date, '[]')`. The `[]` bounds
    # convention (inclusive start AND inclusive end) reflects that
    # calendar dates are discrete: a dateperiod that ends on
    # `2026-01-15` includes that whole day.
    #
    # Supported filter capabilities:
    # - `equality`  — range equality (`eq`)
    # - `interval`  — `eq`, `contains`, `overlaps`, `within`
    #
    # `comparison` is rejected at schema validation time — the scalar
    # comparison operators have no meaning against a stored `{start, end}`
    # date range object.
    class DatePeriodType < RangeType
      register_type "dateperiod"

      def initialize
        super(
          "must be an object with 'start' and 'end' (ISO 8601 dates YYYY-MM-DD)",
          "ISO 8601 date YYYY-MM-DD",
          "start must be on or before end (dateperiod bounds are '[]' — inclusive both ends)",
        )
      end

      DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

      protected def parse_bound(
        str : String,
        path : String,
        bound : String,
        errors : Array(ValidationError),
      ) : Time?
        unless str.matches?(DATE_PATTERN)
          errors << ValidationError.new(
            field: "#{path}.#{bound}",
            message: "is not a valid ISO 8601 date (expected YYYY-MM-DD): '#{str}'",
            code: "invalid_format",
            params: {"value" => str, "format" => "an ISO 8601 date (YYYY-MM-DD)"},
          )
          return nil
        end

        begin
          Time.parse(str, "%Y-%m-%d", Time::Location::UTC)
        rescue Time::Format::Error | ArgumentError
          errors << ValidationError.new(
            field: "#{path}.#{bound}",
            message: "is not a valid calendar date: '#{str}'",
            code: "invalid_format",
            params: {"value" => str, "format" => "a valid calendar date"},
          )
          nil
        end
      end

      # Inclusive both ends: start may equal end (single-day range).
      protected def in_order?(start : Time, end_bound : Time) : Bool
        start <= end_bound
      end
    end
  end
end
