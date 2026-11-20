# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a duration value stored as an integer count of seconds.
    #
    # The displayed unit granularity on the frontend (days, hours, minutes,
    # seconds) is a presentation concern — the stored JSONB value is always a
    # non-negative integer seconds count, so filter and sort use the same
    # `jsonb_as_numeric` numeric path as `integer` and `money`.
    #
    # Supported filter capabilities:
    # - `equality`   — equality (`eq`)
    # - `comparison` — `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between`
    #
    # `interval` / `membership` are rejected at schema validation time —
    # a scalar seconds count has no range or container semantics.
    class DurationType < FieldType
      register_type "duration"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        unless value.as_i64?
          errors << ValidationError.new(
            field: path,
            message: "must be a non-negative integer (duration seconds)",
            code: "invalid_type",
            params: {"expected" => "a non-negative integer (duration seconds)"},
          )
          return
        end

        if value.as_i64 < 0
          errors << ValidationError.new(
            field: path,
            message: "must be a non-negative integer (duration seconds)",
            code: "out_of_range",
            params: {"reason" => "must be a non-negative number of seconds"},
          )
        end
      end

      # Filter capabilities permitted on a `duration` field. Same
      # numeric-comparison set as `integer` / `money` (minus `currency`).
      def self.allowed_capabilities : Array(FilterCapability)
        [FilterCapability::Equality, FilterCapability::Comparison]
      end
    end
  end
end
