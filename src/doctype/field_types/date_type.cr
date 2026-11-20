# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for ISO‑8601 calendar date values (no time component).
    #
    # Stored as a `YYYY-MM-DD` string. Differs from `DatetimeType` in that
    # the time portion is forbidden — this is for human-scale calendar dates
    # (hire date, date of birth, contract effective date, …). Indexes btree
    # on `content->>'field'` exactly like `datetime`/`string`.
    class DateType < FieldType
      register_type "date"

      # Regex match for the YYYY-MM-DD text shape. After this passes,
      # calendar validity is enforced by attempting a Crystal `Time.parse`
      # with the explicit `%Y-%m-%d` format — Crystal's `Time.parse_iso8601`
      # rejects date-only strings (it requires a time component), so we
      # use the explicit format instead.
      DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str_val = require_string(value, path, errors, suffix: "ISO 8601 date YYYY-MM-DD")
        return if str_val.nil?

        unless str_val.matches?(DATE_PATTERN)
          errors << ValidationError.new(
            field: path,
            message: "is not a valid ISO 8601 date (expected YYYY-MM-DD): '#{str_val}'",
            code: "invalid_format",
            params: {"value" => str_val, "format" => "an ISO 8601 date (YYYY-MM-DD)"},
          )
          return
        end

        # Calendar validity — reject e.g. 2025-13-40 or 2025-02-29 (Feb 29
        # on a non-leap year). `Time.parse_iso8601` does not accept date-only
        # strings, so we parse with the explicit `%Y-%m-%d` format and a UTC
        # location. Crystal raises `Time::Format::Error` for pattern mismatches
        # and `ArgumentError` for semantically impossible calendar dates
        # (Feb 30, month 13) — both indicate the input is not a real date.
        begin
          Time.parse(str_val, "%Y-%m-%d", Time::Location::UTC)
        rescue Time::Format::Error | ArgumentError
          errors << ValidationError.new(
            field: path,
            message: "is not a valid calendar date: '#{str_val}'",
            code: "invalid_format",
            params: {"value" => str_val, "format" => "a valid calendar date"},
          )
        end
      end
    end
  end
end
