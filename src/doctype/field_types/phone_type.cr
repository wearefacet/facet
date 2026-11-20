# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for a phone number value.
    #
    # Stored as a string. Validation is intentionally loose — phone numbers
    # vary widely across locales and carriers (spacing, `+` prefixes, dashes,
    # extensions), so the type only requires a non-empty string. Formatting
    # and copy-to-clipboard are frontend presentation concerns.
    class PhoneType < FieldType
      register_type "phone"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str = require_string(value, path, errors)
        return if str.nil?

        if str.empty?
          errors << ValidationError.new(
            field: path,
            message: "must not be empty",
            code: "invalid_format",
          )
        end
      end
    end
  end
end
