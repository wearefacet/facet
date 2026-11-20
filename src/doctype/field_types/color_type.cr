# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../util/color"

module Facet
  module Doctype
    # Field type for color values.
    #
    # Delegates parsing and normalization to `Util::Color`.
    # Stores the normalized 32-bit hex string `#RRGGBBAA`.
    class ColorType < FieldType
      register_type "color"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str = require_string(value, path, errors)
        return if str.nil?

        unless Util::Color.valid?(str)
          begin
            Util::Color.normalize(str)
          rescue e : ArgumentError
            errors << ValidationError.new(
              field: path,
              message: e.message.to_s,
              code: "invalid_format",
            )
          end
        end
      end

      # Normalizes a color value to its canonical `#RRGGBBAA` form before
      # validation and persistence — the same hook `DatetimeType` and
      # `PeriodType` use. Accepts every grammar `Util::Color` serves (hex
      # `#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA`, `rgb`/`rgba`, `hsl`/`hsla`;
      # alpha defaults to `FF`). Returns `value` unchanged when it is not a
      # string or does not parse, so `#validate` surfaces the original
      # field-level error and nothing partial is written.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        str = value.as_s?
        return value unless str

        normalized = begin
          Util::Color.normalize(str)
        rescue ArgumentError
          return value
        end
        JSON::Any.new(normalized)
      end
    end
  end
end
