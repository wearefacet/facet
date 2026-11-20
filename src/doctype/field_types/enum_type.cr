# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a closed set of string labels (`values`).
    class EnumType < FieldType
      register_type "enum"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str_val = require_string(value, path, errors, suffix: "enum")
        return if str_val.nil?

        allowed = field_definition.values
        return if allowed.nil? || allowed.any? { |ev| ev.key == str_val }

        keys = allowed.map(&.key).join(", ")
        errors << ValidationError.new(
          field: path,
          message: "has invalid enum value '#{str_val}' (allowed: #{keys})",
          code: "invalid_format",
          params: {"value" => str_val, "allowed" => keys, "format" => "one of: #{keys}"},
        )
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        enum_values = field_definition.values
        return if enum_values.nil?

        # Validate key uniqueness
        keys = enum_values.map(&.key)
        dups = keys.group_by(&.itself).select { |_, v| v.size > 1 }.keys
        dups.each do |dup_key|
          errors << ValidationError.new(
            field: "#{path}.values",
            message: "duplicate enum key '#{dup_key}'",
            code: "duplicate_value",
          )
        end

        # Validate key length
        enum_values.each do |ev|
          if ev.key.size > 64
            errors << ValidationError.new(
              field: "#{path}.values.#{ev.key}",
              message: "enum key '#{ev.key}' exceeds max length of 64 characters",
              code: "too_long",
              params: {"value" => ev.key, "max" => "64"},
            )
          end
          if ev.key.empty?
            errors << ValidationError.new(
              field: "#{path}.values",
              message: "enum key must not be empty",
              code: "empty_value",
            )
          end
        end
      end
    end
  end
end
