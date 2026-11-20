# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for JSONB sub‑documents.
    #
    # When `properties` is present on the FieldDefinition, validates sub‑fields
    # against the nested schema; otherwise the object is free‑form.
    class ObjectType < FieldType
      register_type "object"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        obj = value.as_h?
        if obj.nil?
          errors << ValidationError.new(
            field: path,
            message: "must be an object (JSON object)",
            code: "invalid_type",
            params: {"expected" => "an object"},
          )
          return
        end

        props = field_definition.properties
        return if props.nil?

        obj_keys = obj.keys.to_set

        # Check required sub-fields
        props.each do |sub_name, sub_field|
          if sub_field.required && !obj_keys.includes?(sub_name)
            errors << ValidationError.new(
              field: "#{path}.#{sub_name}",
              message: "is required",
              code: "required",
            )
          end
        end

        # Validate each provided sub-field
        obj.each do |sub_name, sub_value|
          sub_field = props[sub_name]?
          if sub_field.nil?
            errors << ValidationError.new(
              field: "#{path}.#{sub_name}",
              message: "is not a defined field",
              code: "unknown_field",
            )
            next
          end
          next if sub_value.raw.nil?

          # Delegate to the sub-field's type
          if sub_type = sub_field.type
            sub_type.validate(sub_value, sub_field, "#{path}.#{sub_name}", errors)
          end
        end
      end

      # Recurses normalization into nested properties.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        obj = value.as_h?
        return value if obj.nil?

        props = field_definition.properties
        return value if props.nil?

        mutated = false
        new_h = {} of String => JSON::Any
        obj.each do |key, val|
          # Null sub-values pass through untouched — the array/dictionary
          # recursions null-skip too, and an explicit null is a legal value
          # (e.g. the SystemSettings seed pins nothing).
          if val.raw.nil?
            new_h[key] = val
            next
          end
          if (sub_field = props[key]?) && (sub_type = sub_field.type)
            normalized = sub_type.normalize(val, sub_field)
            mutated = true if normalized != val
            new_h[key] = normalized
          else
            new_h[key] = val
          end
        end
        mutated ? JSON::Any.new(new_h) : value
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        # Recurse into nested properties
        props = field_definition.properties
        return if props.nil?

        props.each do |sub_name, sub_field|
          if sub_type = sub_field.type
            sub_type.validate_definition(sub_field, "#{path}.#{sub_name}", errors)
          end
        end
      end
    end
  end
end
