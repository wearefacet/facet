# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a datetime range — a bounded interval between two
    # ISO‑8601 timestamps. Stored as a JSONB object `{"start": "...",
    # "end": "..."}` with both bounds required.
    #
    # Indexing uses a PostgreSQL GiST expression index over
    # `tstzrange((content#>>'{f,start}')::timestamptz,
    # (content#>>'{f,end}')::timestamptz, '[)')`. The `[)` bounds
    # convention (inclusive start, exclusive end) reflects that real
    # timestamps live in a dense continuum — a period that ends at
    # `2026-01-01T00:00:00Z` does not include the instant `00:00:00`.
    #
    # Supported filter capabilities:
    # - `equality`  — range equality (`eq`)
    # - `interval`  — `eq`, `contains`, `overlaps`, `within`
    #
    # `comparison` is rejected at schema validation time — the scalar
    # comparison operators (`gt`/`gte`/`lt`/`lte`/`between`) compare a
    # single scalar against a stored `{start, end}` object and would
    # silently produce wrong comparisons.
    class PeriodType < RangeType
      register_type "period"

      def initialize
        super(
          "must be an object with 'start' and 'end' (ISO 8601 datetimes)",
          "ISO 8601 datetime",
          "start must be strictly before end (period bounds are '[)' — exclusive upper)",
        )
      end

      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        obj = value.as_h?
        return value unless obj

        start_raw = obj["start"]?
        end_raw = obj["end"]?
        return value if start_raw.nil? || end_raw.nil?

        start_norm = normalize_iso8601_to_utc(start_raw)
        end_norm = normalize_iso8601_to_utc(end_raw)
        return value if start_norm.nil? || end_norm.nil?

        new_h = obj.dup
        new_h["start"] = start_norm
        new_h["end"] = end_norm
        JSON::Any.new(new_h)
      end

      protected def parse_bound(
        str : String,
        path : String,
        bound : String,
        errors : Array(ValidationError),
      ) : Time?
        # Reject pure date values — a `period` is a timestamp range.
        if str.matches?(/^\d{4}-\d{2}-\d{2}$/)
          errors << ValidationError.new(
            field: "#{path}.#{bound}",
            message: "must include a time component (use datetime, not date, for period bounds): '#{str}'",
            code: "invalid_format",
            params: {"value" => str, "format" => "a datetime with a time component"},
          )
          return nil
        end

        begin
          Time.parse_iso8601(str)
        rescue Time::Format::Error
          errors << ValidationError.new(
            field: "#{path}.#{bound}",
            message: "is not a valid ISO 8601 datetime: '#{str}'",
            code: "invalid_format",
            params: {"value" => str, "format" => "an ISO 8601 datetime"},
          )
          nil
        end
      end

      # Exclusive upper bound: start must be strictly before end.
      protected def in_order?(start : Time, end_bound : Time) : Bool
        start < end_bound
      end
    end
  end
end
