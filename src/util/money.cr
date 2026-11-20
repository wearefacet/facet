# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "big"

module Facet
  module Util
    # Represents a currency definition.
    #
    # Rows come from `core.Currency` documents, loaded into this in-process
    # registry by `Facet::Currency::Registry`. Looked up by ticker via `.[]`
    # (raising) or `.find` (non-raising).
    #
    # `active` / `favorite` / `grouping` drive the write-path lifecycle rule
    # (`Document::MoneyCurrencyCheck`) and the currency picker;
    # `MoneyType#validate` only consults `.registered?`, so inactive rows
    # keep validating where a field already holds them.
    #
    # ```
    # currency = Facet::Util::Currency.new(ticker: "EUR", symbol: "€", name: "Euro", digits: 2)
    # currency.ticker   # => "EUR"
    # currency.symbol   # => "€"
    # currency.digits   # => 2
    # currency.active   # => true
    # currency.grouping # => "standard"
    # ```
    struct Currency
      include JSON::Serializable

      getter ticker : String
      getter symbol : String = ""
      getter name : String
      getter digits : Int32
      # `.active`/.favorite are data attributes (serialized, compared, and
      # spec-asserted by name), not predicates — hence plain getters.
      # ameba:disable Naming/QueryBoolMethods
      getter active : Bool = true
      # ameba:disable Naming/QueryBoolMethods
      getter favorite : Bool = false
      getter grouping : String = "standard"

      def initialize(
        @ticker : String,
        @name : String,
        @digits : Int32,
        @symbol : String = "",
        @active : Bool = true,
        @favorite : Bool = false,
        @grouping : String = "standard",
      )
      end

      def ==(other : self) : Bool
        ticker == other.ticker &&
          symbol == other.symbol &&
          name == other.name &&
          digits == other.digits &&
          active == other.active &&
          favorite == other.favorite &&
          grouping == other.grouping
      end

      def hash
        ticker.hash ^ symbol.hash ^ name.hash ^ digits.hash ^
          active.hash ^ favorite.hash ^ grouping.hash
      end

      def to_s : String
        "#{ticker} (#{symbol}) #{name}"
      end

      def inspect : String
        to_s
      end

      # ── Registry ────────────────────────────────────────────────────────

      @@currencies = {} of String => self

      # Registers a batch of currencies into the global registry.
      # Called by `Facet::Currency::Registry.refresh` (replace-all — pair it
      # with `reset!`) and by pure (DB-less) specs.
      def self.register(currencies : Hash(String, self)) : Nil
        @@currencies.merge!(currencies)
      end

      # Looks up a currency by ticker.
      # Raises `UnknownCurrencyError` if the ticker is not registered.
      def self.[](ticker : String) : self
        @@currencies[ticker]? || raise UnknownCurrencyError.new("Unknown currency: #{ticker}")
      end

      # Non-raising lookup. Returns `nil` for an unregistered ticker.
      def self.find(ticker : String) : self?
        @@currencies[ticker]?
      end

      # Returns true if the ticker is registered.
      def self.registered?(ticker : String) : Bool
        @@currencies.has_key?(ticker)
      end

      # Returns all registered currencies.
      def self.all : Hash(String, self)
        @@currencies
      end

      # Clears the registry (useful in tests).
      def self.reset! : Nil
        @@currencies.clear
      end
    end

    # Represents a monetary amount stored as a `{"value":"...","currency":"..."}`
    # JSON object.
    #
    # `value` is a canonical decimal string parsed as `BigDecimal` for
    # arithmetic and comparison. `currency` is an ISO-4217-style ticker
    # validated against the `Currency` registry. The JSON shape preserves the
    # original `value` string verbatim — numeric comparison only happens at
    # query time via the IMMUTABLE `facet_money_value_as_numeric` helper.
    #
    # A `money` field is always multi-currency at the storage layer; the
    # field-level `currency` declaration on `FieldDefinition` is a display
    # hint / default backfill (see `MoneyType#normalize`).
    #
    # ```
    # money = Facet::Util::Money.new("123.42", "USD")
    # money.amount  # => BigDecimal.new(123.42)
    # money.to_json # => {"value":"123.42","currency":"USD"}
    # money.to_s    # => "123.42 USD"
    # ```
    struct Money
      getter value : String
      getter currency : String

      # Constructs a `Money` from a decimal string and a currency ticker.
      # Parses the value as `BigDecimal` eagerly (raises on malformed input)
      # and verifies the currency is registered (raises `UnknownCurrencyError`).
      def initialize(@value : String, @currency : String)
        amount
        Currency[@currency]
      end

      # Convenience accessor for the numeric form, used by arithmetic and
      # comparisons. Re-parses the `value` string on every call so the
      # struct stays immutable; the cost is negligible for the call
      # frequencies in this codebase.
      def amount : BigDecimal
        BigDecimal.new(@value)
      rescue ex : ArgumentError | ::InvalidBigDecimalException
        raise ArgumentError.new("money value '#{@value}' is not a valid decimal: #{ex.message}")
      end

      # ── JSON ────────────────────────────────────────────────────────────

      # Deserializes from `{"value":"...","currency":"..."}` and validates the
      # currency is registered. Raises `UnknownCurrencyError` on unknown
      # ticker and `ArgumentError` on malformed value. Missing keys raise
      # `KeyError`.
      def self.from_json(string_or_io) : self
        pull = JSON::PullParser.new(string_or_io)
        value = nil
        currency = nil
        pull.read_object do |key|
          case key
          when "value"    then value = pull.read_string
          when "currency" then currency = pull.read_string
          else
            pull.skip
          end
        end
        value = value || raise KeyError.new("Missing JSON attribute: value")
        currency = currency || raise KeyError.new("Missing JSON attribute: currency")
        new(value, currency)
      end

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("value", @value)
          builder.field("currency", @currency)
        end
      end

      def to_json : String
        String.build { |io| to_json(io) }
      end

      # ── Arithmetic ─────────────────────────────────────────────────────

      # Adds money with the same currency.
      # Raises `CurrencyMismatchError` if currencies differ.
      def +(other : Money) : Money
        assert_same_currency!(other)
        Money.new((amount + other.amount).to_s, @currency)
      end

      # Subtracts money with the same currency.
      # Raises `CurrencyMismatchError` if currencies differ.
      def -(other : Money) : Money
        assert_same_currency!(other)
        Money.new((amount - other.amount).to_s, @currency)
      end

      # Multiplies by a scalar number.
      def *(other : Number) : Money
        Money.new((amount * BigDecimal.new(other)).to_s, @currency)
      end

      # Divides by a scalar number.
      # Raises `DivisionByZeroError` on division by zero.
      def /(other : Number) : Money
        raise DivisionByZeroError.new("Division by zero") if other == 0
        Money.new((amount / BigDecimal.new(other)).to_s, @currency)
      end

      # ── Conversion ──────────────────────────────────────────────────────

      # Formats as the decimal string and the currency ticker.
      #
      # ```
      # Money.new(\"123.42\", \"USD\").to_s # => \"123.42 USD\"
      # Money.new(\"-50.00\", \"EUR\").to_s # => \"-50.00 EUR\"
      # Money.new(\"0\",      \"JPY\").to_s # => \"0 JPY\"
      # ```
      def to_s : String
        "#{@value} #{@currency}"
      end

      def inspect : String
        to_s
      end

      # ── Comparison ──────────────────────────────────────────────────────

      def ==(other : Money) : Bool
        amount == other.amount && @currency == other.currency
      end

      def hash
        @value.hash ^ @currency.hash
      end

      # ── Private helpers ───────────────────────────────────────────────

      private def assert_same_currency!(other : Money) : Nil
        return if @currency == other.currency
        raise CurrencyMismatchError.new("Currency mismatch: #{@currency} != #{other.currency}")
      end
    end

    # Error raised when operating on money with mismatched currencies.
    class CurrencyMismatchError < Exception
    end

    # Error raised when referencing an unregistered currency.
    class UnknownCurrencyError < Exception
    end

    # Error raised when dividing money by zero.
    class DivisionByZeroError < Exception
    end
  end
end
