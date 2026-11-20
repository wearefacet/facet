# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for long‑form UTF‑8 text values.
    # Semantically longer than `String`; validated identically.
    class LongTextType < FieldType
      register_type "longtext"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        s = require_string(value, path, errors)
        return if s.nil?

        # Length bounds, same semantics as `StringType` (B-57).
        if min = field_definition.min
          if s.size < min
            errors << ValidationError.new(
              field: path,
              message: "must be at least #{min} characters",
              code: "out_of_range",
              params: {"value" => s, "min" => min.to_s},
            )
          end
        end

        if max = field_definition.max
          if s.size > max
            errors << ValidationError.new(
              field: path,
              message: "must be at most #{max} characters",
              code: "out_of_range",
              params: {"value" => s, "max" => max.to_s},
            )
          end
        end

        # Pattern validation
        pattern_str = field_definition.pattern
        return if pattern_str.nil?

        validate_pattern(field_definition, path, s, errors, pattern_str)
      end

      # Normalizes carriage returns out of longtext values: `\r\n` and
      # bare `\r` are rewritten to `\n`. Done before validation so any
      # stray `\r` (which we don't support in markdown rendering) is
      # canonicalized rather than rejected. Null values pass through —
      # the array/dictionary recursions null-skip too, and an explicit
      # null is a legal value (e.g. the SystemSettings seed).
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        s = value.as_s?
        return value unless s
        return value unless s.includes?('\r')
        JSON::Any.new(s.gsub(/\r\n/, "\n").gsub(/\r/, "\n"))
      end
    end
  end
end
