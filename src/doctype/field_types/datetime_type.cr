# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for ISO‑8601 datetime values.
    #
    # Storage contract: every value is normalized to a UTC ISO‑8601 string
    # (RFC 3339 form, `...Z`) before persistence. Callers may submit values
    # with a timezone offset (e.g. `2025-01-15T10:30:00+02:00`); the offset
    # is respected and the result is converted to UTC. This guarantees that
    # the same instant has exactly one canonical stored representation,
    # which is required for JSONB equality, btree determinism on
    # `content->>'field'`, and the IMMUTABLE range-construction wrappers in
    # migration `0002_indexing.sql`.
    class DatetimeType < FieldType
      register_type "datetime"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str_val = require_string(value, path, errors, suffix: "ISO 8601 datetime")
        return if str_val.nil?

        begin
          Time.parse_iso8601(str_val)
        rescue Time::Format::Error
          errors << ValidationError.new(
            field: path,
            message: "is not a valid ISO 8601 datetime: '#{str_val}'",
            code: "invalid_format",
            params: {"value" => str_val, "format" => "an ISO 8601 datetime"},
          )
        end
      end

      # Normalizes an ISO‑8601 datetime string to its UTC RFC‑3339 form.
      # Returns `value` unchanged if it is not a parseable string so that
      # `validate` still surfaces the original error.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        normalize_iso8601_to_utc(value) || value
      end
    end
  end
end
