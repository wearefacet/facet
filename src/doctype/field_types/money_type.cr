# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../util/money"

module Facet
  module Doctype
    # Field type for monetary amounts stored as a JSON object
    # `{"value": "...", "currency": "..."}`. The `value` is a decimal string
    # parsed as `BigDecimal` at query time; `currency` is an ISO-4217-style
    # ticker validated against the `Currency` registry at write time.
    #
    # A `money` field is always multi-currency at the storage layer. The
    # optional field-level `currency:` declaration is a display hint / default
    # backfill: `#normalize` fills the `currency` member from
    # `field_definition.currency` when the content payload omits it, so
    # single-currency editors can still send `{"value": "100"}`.
    #
    # Supported filter capabilities (all served by `btree_money` /
    # `btree_money_currency` indexes):
    # - `equality`   — numeric value equality (`eq`)
    # - `comparison` — `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between` on
    #   the numeric value (optionally currency-constrained)
    # - `currency`   — text equality on the stored currency ticker
    #
    # `interval` / `membership` are rejected at schema validation time —
    # money is a scalar decimal, not a range and not a container.
    class MoneyType < FieldType
      register_type "money"

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        obj = value.as_h?
        unless obj
          errors << ValidationError.new(
            field: path,
            message: "must be a money object {value, currency}",
            code: "invalid_type",
            params: {"expected" => "a money object {value, currency}"},
          )
          return
        end

        value_raw = obj["value"]?
        currency_raw = obj["currency"]?

        if value_raw.nil?
          errors << ValidationError.new(
            field: "#{path}.value",
            message: "is required",
            code: "required",
          )
        end
        if currency_raw.nil?
          errors << ValidationError.new(
            field: "#{path}.currency",
            message: "is required",
            code: "required",
          )
        end
        return if value_raw.nil? || currency_raw.nil?

        value_str = value_raw.as_s?
        currency_str = currency_raw.as_s?

        if value_str.nil?
          errors << ValidationError.new(
            field: "#{path}.value",
            message: "must be a decimal string",
            code: "invalid_type",
            params: {"expected" => "a decimal string"},
          )
        end
        if currency_str.nil?
          errors << ValidationError.new(
            field: "#{path}.currency",
            message: "must be a string ticker",
            code: "invalid_type",
            params: {"expected" => "a string ticker"},
          )
        end
        return if value_str.nil? || currency_str.nil?

        unless value_str.matches?(/^-?\d+(\.\d+)?$/)
          errors << ValidationError.new(
            field: "#{path}.value",
            message: "must be a decimal string (got '#{value_str}')",
            code: "invalid_format",
            params: {"value" => value_str, "format" => "a decimal number like 1234.56"},
          )
          return
        end

        unless Util::Currency.registered?(currency_str)
          errors << ValidationError.new(
            field: "#{path}.currency",
            message: "must be a registered currency (got '#{currency_str}')",
            code: "schema",
          )
          return
        end
      end

      # Backfills the `currency` member from `field_definition.currency` when
      # the content payload omits it. Non-money-object values are returned
      # unchanged so `validate` still surfaces the original type error.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        obj = value.as_h?
        return value unless obj

        return value if obj["currency"]?

        default_currency = field_definition.currency
        return value if default_currency.nil?

        new_h = obj.dup
        new_h["currency"] = JSON::Any.new(default_currency)
        JSON::Any.new(new_h)
      end

      # Filter capabilities permitted on a `money` field.
      # `equality` / `comparison` operate on the numeric value (served by
      # `btree_money`); `currency` is text equality on the stored ticker
      # (served by `btree_money_currency`).
      def self.allowed_capabilities : Array(FilterCapability)
        [FilterCapability::Equality, FilterCapability::Comparison, FilterCapability::Currency]
      end
    end
  end
end
