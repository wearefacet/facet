# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for unbounded JSON values (schemaless).
    #
    # Accepts any JSON value — string, number, boolean, null, array, or object.
    # Used in system doctypes like `core.Domain` for fields like `grants`
    # and `context_sets` that hold free-form data without a predefined schema.
    class AnyType < FieldType
      register_type "any"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        # Any value is valid
      end
    end
  end
end
