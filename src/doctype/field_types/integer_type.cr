# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for 64‑bit signed integer values.
    class IntegerType < FieldType
      register_type "integer"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        int = value.as_i64?
        unless int
          errors << ValidationError.new(
            field: path,
            message: "must be an integer",
            code: "invalid_type",
            params: {"expected" => "an integer"},
          )
          return
        end

        # The declared `min` / `max` bounds are part of the definition
        # contract (the role budget field pins `min: 0`); the mutation path
        # enforces them like every other declared constraint.
        if min = field_definition.min
          if int < min
            errors << ValidationError.new(
              field: path,
              message: "must be at least #{min}",
              code: "out_of_range",
              params: {"value" => int.to_s, "min" => min.to_s},
            )
          end
        end

        if max = field_definition.max
          if int > max
            errors << ValidationError.new(
              field: path,
              message: "must be at most #{max}",
              code: "out_of_range",
              params: {"value" => int.to_s, "max" => max.to_s},
            )
          end
        end
      end
    end
  end
end
