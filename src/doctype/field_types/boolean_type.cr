# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for boolean (`true` / `false`) values.
    class BooleanType < FieldType
      register_type "boolean"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        unless value.raw.is_a?(Bool)
          errors << ValidationError.new(
            field: path,
            message: "must be a boolean",
            code: "invalid_type",
            params: {"expected" => "a boolean"},
          )
        end
      end
    end
  end
end
