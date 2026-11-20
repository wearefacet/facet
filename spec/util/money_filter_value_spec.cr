# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "big"
require "../../src/util/money"
require "../../src/util/money_filter_value"
require "../../src/config"

alias MoneyFilterValue = Facet::Util::MoneyFilterValue

describe Facet::Util::MoneyFilterValue do
  # The parser validates currency tickers against the registry, so the
  # registry must hold at least USD/EUR/JPY for these specs. `before_each`
  # is used (not `before_all`) per the spec-helper rule that `before_all` is
  # broken in this project.
  before_each do
    Facet::Util::Currency.reset!
    register_seed_currencies
  end

  describe ".parse (string input)" do
    it "parses a currency-prefixed value" do
      v = MoneyFilterValue.parse("USD 1000")
      v.currency.should eq("USD")
      v.amount.should eq(BigDecimal.new("1000"))
    end

    it "parses a currency-agnostic value (no prefix)" do
      v = MoneyFilterValue.parse("1000")
      v.currency.should be_nil
      v.amount.should eq(BigDecimal.new("1000"))
    end

    it "parses a negative amount with currency prefix" do
      v = MoneyFilterValue.parse("USD -50.50")
      v.currency.should eq("USD")
      v.amount.should eq(BigDecimal.new("-50.50"))
    end

    it "parses a negative amount with no currency prefix" do
      v = MoneyFilterValue.parse("-50.50")
      v.currency.should be_nil
      v.amount.should eq(BigDecimal.new("-50.50"))
    end

    it "parses a decimal amount" do
      v = MoneyFilterValue.parse("EUR 99.95")
      v.currency.should eq("EUR")
      v.amount.should eq(BigDecimal.new("99.95"))
    end

    it "parses a zero amount" do
      v = MoneyFilterValue.parse("GBP 0")
      v.currency.should eq("GBP")
      v.amount.should eq(BigDecimal.new("0"))
    end

    it "accepts multiple whitespace characters between currency and amount" do
      v = MoneyFilterValue.parse("USD   1000")
      v.currency.should eq("USD")
      v.amount.should eq(BigDecimal.new("1000"))
    end

    it "parses an inactive registered ticker (stored values stay filterable)" do
      Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

      v = MoneyFilterValue.parse("OLD 25.50")
      v.currency.should eq("OLD")
      v.amount.should eq(BigDecimal.new("25.50"))
    end
  end

  describe ".parse (numeric input)" do
    it "parses an Int64 as a currency-agnostic amount" do
      v = MoneyFilterValue.parse(1000_i64)
      v.currency.should be_nil
      v.amount.should eq(BigDecimal.new("1000"))
    end

    it "parses a Float64 as a currency-agnostic amount" do
      v = MoneyFilterValue.parse(99.5_f64)
      v.currency.should be_nil
      v.amount.should eq(BigDecimal.new("99.5"))
    end
  end

  describe ".parse (malformed input)" do
    it "raises ArgumentError on an empty string" do
      expect_raises(ArgumentError, /empty/) do
        MoneyFilterValue.parse("")
      end
    end

    it "raises ArgumentError on a currency prefix with no amount" do
      expect_raises(ArgumentError) do
        MoneyFilterValue.parse("USD")
      end
    end

    it "raises ArgumentError on a non-numeric amount" do
      expect_raises(ArgumentError) do
        MoneyFilterValue.parse("USD abc")
      end
    end

    it "raises ArgumentError on an unregistered currency ticker" do
      expect_raises(ArgumentError, /unknown currency/i) do
        MoneyFilterValue.parse("XYZ 100")
      end
    end

    it "raises ArgumentError on a lowercase currency prefix (case-sensitive)" do
      # The grammar requires 3 uppercase letters — "usd" is not interpreted
      # as a currency prefix, so it falls through to "parse as amount" and
      # raises on the non-decimal amount.
      expect_raises(ArgumentError) do
        MoneyFilterValue.parse("usd 100")
      end
    end
  end
end
