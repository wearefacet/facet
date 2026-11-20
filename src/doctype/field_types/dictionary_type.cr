# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a key‑value map with typed values.
    #
    # Keys are always strings; the value type is described by the
    # `dictionary_value` FieldDefinition.
    class DictionaryType < FieldType
      register_type "dictionary"

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
            message: "must be an object (dictionary)",
            code: "invalid_type",
            params: {"expected" => "an object (dictionary)"},
          )
          return
        end

        dict_val = field_definition.dictionary_value
        return if dict_val.nil?

        obj.each do |key, val|
          next if val.raw.nil?

          if val_type = dict_val.type
            val_type.validate(val, dict_val, "#{path}.#{key}", errors)
          end
        end
      end

      # Recurses normalization into dictionary values.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        obj = value.as_h?
        return value if obj.nil?

        dict_val = field_definition.dictionary_value
        return value if dict_val.nil?

        val_type = dict_val.type
        return value if val_type.nil?

        mutated = false
        new_h = {} of String => JSON::Any
        obj.each do |key, val|
          if val.raw.nil?
            new_h[key] = val
            next
          end
          normalized = val_type.normalize(val, dict_val)
          mutated = true if normalized != val
          new_h[key] = normalized
        end
        mutated ? JSON::Any.new(new_h) : value
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if field_definition.dictionary_value.nil?
          errors << ValidationError.new(
            field: path,
            message: "of type 'dictionary' must define 'values'",
            code: "schema",
          )
        else
          dict_val = field_definition.dictionary_value.as(FieldDefinition)
          if val_type = dict_val.type
            val_type.validate_definition(dict_val, "#{path}.values", errors)
          end
        end
      end
    end
  end
end
