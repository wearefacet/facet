# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "big"
require "./money"

module Facet
  module Util
    # Parsed form of a `money` field filter value (e.g. the RHS of
    # `price__gte=USD%201000` after HTTP URL-decoding).
    #
    # The filter value is either:
    # - `"<CCY> <amount>"` (currency-prefixed) — extracts the currency ticker
    #   and the decimal amount, AND-constrains the stored currency at query
    #   time.
    # - `"<amount>"` (currency-agnostic) — extracts only the decimal amount;
    #   the query matches any currency.
    #
    # The currency (if present) MUST be registered in the `Currency` registry;
    # an unregistered ticker is a caller typo, not a silent no-match, so
    # `parse` raises `ArgumentError` (the caller — `Document::List` —
    # surfaces this as a 422 service error). A malformed amount also raises
    # `ArgumentError`.
    struct MoneyFilterValue
      getter currency : String?
      getter amount : BigDecimal

      def initialize(@currency : String?, @amount : BigDecimal)
      end

      # Parses a filter value into a `MoneyFilterValue`.
      #
      # Accepts the post-URL-decode form: `"USD 1000"`, `"USD -50.50"`,
      # `"1000"`. String scalars and `Int64` / `Float64` JSON values are
      # supported (no currency is extractable from a bare number).
      #
      # Raises `ArgumentError` on:
      # - empty string.
      # - a currency prefix with no amount (`"USD"`).
      # - a non-decimal amount (`"USD abc"`).
      # - an unregistered currency ticker (`"XYZ 100"`).
      def self.parse(raw : String | Int64 | Float64) : self
        if raw.is_a?(String)
          parse_string(raw)
        else
          # Int64 or Float64: numbers from the JSON body path; no currency
          # prefix is possible.
          new(nil, BigDecimal.new(raw.to_s))
        end
      end

      private def self.parse_string(raw : String) : self
        raise ArgumentError.new("money filter value must not be empty") if raw.empty?

        # Match an optional "<CCY> " prefix: 3 uppercase letters, then one
        # or more whitespace characters, then the remainder is the amount.
        currency : String? = nil
        amount_str = raw
        if match = raw.match(/^([A-Z]{3})\s+(.+)$/)
          currency = match[1]
          unless Util::Currency.registered?(currency)
            raise ArgumentError.new("unknown currency '#{currency}' in money filter value")
          end
          amount_str = match[2]
        end

        amount =
          begin
            BigDecimal.new(amount_str)
          rescue ex : ArgumentError | ::InvalidBigDecimalException
            raise ArgumentError.new("money filter value '#{raw}' has a non-decimal amount: #{ex.message}")
          end

        new(currency, amount)
      end
    end
  end
end
