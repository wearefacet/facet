# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for UTF‑8 text values.
    class StringType < FieldType
      register_type "string"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        s = require_string(value, path, errors)
        return if s.nil?

        # The declared `min` / `max` bounds are length bounds for text
        # types (the same semantics `SecretType` applies to plaintext).
        # Declared-but-inert constraints are a silent-success class: an
        # author who pins `min: 2` on a string arg or field must see the
        # short value rejected, not accepted (B-57).
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
    end
  end
end
