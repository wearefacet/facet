# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "big"
require "../../src/util/money"
require "../../src/config"

alias Money = Facet::Util::Money
alias Currency = Facet::Util::Currency

describe Facet::Util::Currency do
  it "stores ticker, symbol, name, and digits" do
    c = Currency.new(ticker: "EUR", symbol: "€", name: "Euro", digits: 2)
    c.ticker.should eq("EUR")
    c.symbol.should eq("€")
    c.name.should eq("Euro")
    c.digits.should eq(2)
  end
end

describe Facet::Util::Money do
  # Ensure currencies are loaded for these specs. `register_seed_currencies`
  # fills the in-memory registry from the `core.Currency` seeds.
  #
  # This MUST be `before_each`, never `before_all`: inside a spec file that is
  # compiled together with Kemal, a bare `before_all` resolves to Kemal's
  # HTTP-filter macro, registering the block to run on EVERY request through
  # the FilterHandler — which would reset the config singleton mid-request.
  # See doc/backend/workflow.md → Testing.
  before_each do
    Currency.reset!
    register_seed_currencies
  end

  # ── Construction ─────────────────────────────────────────────────────

  describe ".new" do
    it "stores value and currency verbatim" do
      m = Money.new("123.42", "USD")
      m.value.should eq("123.42")
      m.currency.should eq("USD")
    end

    it "accepts an integer-shaped value string" do
      m = Money.new("0", "JPY")
      m.value.should eq("0")
    end

    it "accepts a negative value string" do
      m = Money.new("-50.00", "EUR")
      m.value.should eq("-50.00")
    end

    it "raises ArgumentError on a non-decimal value" do
      expect_raises(ArgumentError) do
        Money.new("not-a-number", "USD")
      end
    end

    it "rejects a non-decimal value from BigDecimal (InvalidBigDecimalException)" do
      expect_raises(Exception) do
        Money.new("abc", "USD")
      end
    end

    it "raises UnknownCurrencyError on an unregistered ticker" do
      expect_raises(Facet::Util::UnknownCurrencyError) do
        Money.new("100", "XYZ")
      end
    end
  end

  describe ".amount" do
    it "returns the value as a BigDecimal" do
      m = Money.new("123.42", "USD")
      m.amount.should eq(BigDecimal.new("123.42"))
    end

    it "round-trips the original string (no normalisation)" do
      m = Money.new("9.99", "EUR")
      m.amount.to_s.should eq("9.99")
    end
  end

  # ── Arithmetic ──────────────────────────────────────────────────────

  describe ".amount (arithmetic value form)" do
    it "adds two Money with the same currency" do
      result = Money.new("100.00", "USD") + Money.new("0.50", "USD")
      result.amount.should eq(BigDecimal.new("100.50"))
      result.currency.should eq("USD")
    end

    it "raises CurrencyMismatchError on cross-currency" do
      expect_raises(Facet::Util::CurrencyMismatchError) do
        Money.new("100", "USD") + Money.new("100", "EUR")
      end
    end
  end

  describe "#-" do
    it "subtracts two Money with the same currency" do
      result = Money.new("100.00", "USD") - Money.new("0.50", "USD")
      result.amount.should eq(BigDecimal.new("99.50"))
      result.currency.should eq("USD")
    end

    it "raises CurrencyMismatchError on cross-currency" do
      expect_raises(Facet::Util::CurrencyMismatchError) do
        Money.new("100", "USD") - Money.new("100", "EUR")
      end
    end
  end

  describe "#*" do
    it "multiplies by an integer scalar" do
      result = Money.new("10.00", "USD") * 3
      result.amount.should eq(BigDecimal.new("30.00"))
      result.currency.should eq("USD")
    end
  end

  describe "#/" do
    it "divides by an integer scalar" do
      result = Money.new("100.00", "USD") / 4
      result.amount.should eq(BigDecimal.new("25.00"))
      result.currency.should eq("USD")
    end

    it "raises DivisionByZeroError on division by zero" do
      expect_raises(Facet::Util::DivisionByZeroError) do
        Money.new("100", "USD") / 0
      end
    end
  end

  # ── Comparison ───────────────────────────────────────────────────────

  describe "#==" do
    it "is true when value and currency match exactly" do
      Money.new("123.42", "USD").should eq(Money.new("123.42", "USD"))
    end

    it "is false when currencies differ" do
      Money.new("123", "USD").should_not eq(Money.new("123", "EUR"))
    end

    it "is false when values differ" do
      Money.new("100", "USD").should_not eq(Money.new("200", "USD"))
    end

    it "treats numerically-equal strings (e.g. '100' vs '100.00') as equal" do
      Money.new("100", "USD").should eq(Money.new("100.00", "USD"))
    end
  end

  describe "#hash" do
    it "is equal for money with the same value and currency" do
      Money.new("123.42", "USD").hash.should eq(Money.new("123.42", "USD").hash)
    end
  end

  # ── String representation ────────────────────────────────────────────

  describe "#to_s" do
    it "formats value and currency separated by a space" do
      Money.new("123.42", "USD").to_s.should eq("123.42 USD")
    end

    it "formats negative values" do
      Money.new("-50.00", "EUR").to_s.should eq("-50.00 EUR")
    end

    it "formats zero values" do
      Money.new("0", "JPY").to_s.should eq("0 JPY")
    end
  end

  describe "#inspect" do
    it "delegates to #to_s" do
      Money.new("9.99", "EUR").inspect.should eq("9.99 EUR")
    end
  end

  # ── JSON serialisation ───────────────────────────────────────────────

  describe "#to_json" do
    it "serialises as the {value, currency} object" do
      json = Money.new("123.42", "USD").to_json
      json.should eq(%({"value":"123.42","currency":"USD"}))
    end

    it "preserves the original value string (does not re-emit amount)" do
      Money.new("9.990", "USD").to_json.should eq(%({"value":"9.990","currency":"USD"}))
    end
  end

  describe ".from_json" do
    it "deserialises from the {value, currency} object" do
      m = Money.from_json(%({"value":"200.00","currency":"USD"}))
      m.value.should eq("200.00")
      m.currency.should eq("USD")
    end

    it "round-trips through to_json" do
      original = Money.new("99.95", "JPY")
      Money.from_json(original.to_json).should eq(original)
    end

    it "raises UnknownCurrencyError on an unregistered ticker" do
      expect_raises(Facet::Util::UnknownCurrencyError) do
        Money.from_json(%({"value":"100","currency":"XYZ"}))
      end
    end

    it "raises on a non-decimal value" do
      expect_raises(Exception) do
        Money.from_json(%({"value":"abc","currency":"USD"}))
      end
    end

    it "raises when value is missing" do
      expect_raises(KeyError) do
        Money.from_json(%({"currency":"USD"}))
      end
    end

    it "raises when currency is missing" do
      expect_raises(KeyError) do
        Money.from_json(%({"value":"100"}))
      end
    end
  end

  # ── Currency registry ────────────────────────────────────────────────

  describe "Currency.[]" do
    it "raises UnknownCurrencyError for an unregistered ticker" do
      expect_raises(Facet::Util::UnknownCurrencyError) do
        Currency["XYZ"]
      end
    end
  end

  describe "Currency #to_json" do
    it "serialises Currency as ticker/symbol/name/digits plus picker fields JSON" do
      c = Currency.new(ticker: "EUR", symbol: "€", name: "Euro", digits: 2)
      c.to_json.should eq(%({"ticker":"EUR","symbol":"€","name":"Euro","digits":2,"active":true,"favorite":false,"grouping":"standard"}))
    end
  end

  describe "Currency .from_json" do
    it "deserialises Currency from JSON" do
      c = Currency.from_json(%({"ticker":"GBP","symbol":"£","name":"Pound","digits":2}))
      c.ticker.should eq("GBP")
      c.symbol.should eq("£")
      c.name.should eq("Pound")
      c.digits.should eq(2)
    end
  end
end
