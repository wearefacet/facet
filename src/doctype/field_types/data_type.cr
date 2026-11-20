# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for computed values (driven by a Lua script).
    #
    # Data fields must **not** be user‑provided in input — they are always
    # computed server‑side.
    class DataType < FieldType
      register_type "data"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        # Data (computed) fields should not be provided in input
        errors << ValidationError.new(
          field: path,
          message: "is computed (data) and should not be set",
          code: "read_only",
        )
      end
    end
  end
end
