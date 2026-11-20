# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for an array of typed elements.
    #
    # Element type is described by the `items` FieldDefinition.
    class ArrayType < FieldType
      register_type "array"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        arr = value.as_a?
        if arr.nil?
          errors << ValidationError.new(
            field: path,
            message: "must be an array",
            code: "invalid_type",
            params: {"expected" => "an array"},
          )
          return
        end

        items_defn = field_definition.items
        return if items_defn.nil?

        arr.each_with_index do |item, idx|
          item_path = "#{path}.#{idx}"
          # Skip null items
          next if item.raw.nil?

          if item_type = items_defn.type
            item_type.validate(item, items_defn, item_path, errors)
          end
        end
      end

      # Recurses normalization into array elements.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        arr = value.as_a?
        return value if arr.nil?

        items_defn = field_definition.items
        return value if items_defn.nil?

        item_type = items_defn.type
        return value if item_type.nil?

        mutated = false
        new_arr = [] of JSON::Any
        arr.each do |item|
          if item.raw.nil?
            new_arr << item
            next
          end
          normalized = item_type.normalize(item, items_defn)
          mutated = true if normalized != item
          new_arr << normalized
        end
        mutated ? JSON::Any.new(new_arr) : value
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if field_definition.items.nil?
          errors << ValidationError.new(
            field: path,
            message: "of type 'array' must define 'items'",
            code: "schema",
          )
        else
          items_defn = field_definition.items.as(FieldDefinition)
          if item_type = items_defn.type
            item_type.validate_definition(items_defn, "#{path}.items", errors)
          end
        end
      end
    end
  end
end
