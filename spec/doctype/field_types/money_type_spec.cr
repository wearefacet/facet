# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/util/money"
require "../../../src/config"

module Facet
  module Doctype
    describe MoneyType do
      subject = MoneyType.new

      before_each do
        Facet::Config.reset!
        Facet::Config.instance
        register_seed_currencies
      end

      it "has type_name 'money'" do
        subject.type_name.should eq("money")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: MoneyType.new)

        it "passes for a {value, currency} object" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"100","currency":"USD"})), fd, "price", errors)
          errors.should be_empty
        end

        it "passes for a negative value string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"-50.00","currency":"EUR"})), fd, "balance", errors)
          errors.should be_empty
        end

        it "passes for a zero value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"0","currency":"JPY"})), fd, "fee", errors)
          errors.should be_empty
        end

        it "passes for a decimal value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"9.99","currency":"USD"})), fd, "price", errors)
          errors.should be_empty
        end

        it "rejects a bare number" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(100_i64), fd, "price", errors)
          errors.map(&.message).should eq(["must be a money object {value, currency}"])
        end

        it "rejects a bare decimal string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("9.99"), fd, "price", errors)
          errors.map(&.message).should eq(["must be a money object {value, currency}"])
        end

        it "rejects a boolean" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "price", errors)
          errors.map(&.message).should eq(["must be a money object {value, currency}"])
        end

        it "rejects an array" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%([1, 2])), fd, "price", errors)
          errors.map(&.message).should eq(["must be a money object {value, currency}"])
        end

        it "rejects an object missing value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"currency":"USD"})), fd, "price", errors)
          errors.map(&.field).should contain("price.value")
          errors.map(&.code).should contain("required")
        end

        it "rejects an object missing currency" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"100"})), fd, "price", errors)
          errors.map(&.field).should contain("price.currency")
          errors.map(&.code).should contain("required")
        end

        it "rejects a non-string value member (number)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":100,"currency":"USD"})), fd, "price", errors)
          errors.map(&.field).should contain("price.value")
          errors.map(&.code).should contain("invalid_type")
        end

        it "rejects a non-decimal value string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"abc","currency":"USD"})), fd, "price", errors)
          errors.map(&.field).should contain("price.value")
          errors.map(&.code).should contain("invalid_format")
        end

        it "rejects an unregistered currency ticker" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"100","currency":"XYZ"})), fd, "price", errors)
          errors.map(&.field).should contain("price.currency")
          errors.map(&.code).should contain("schema")
        end

        it "rejects a non-string currency member" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"value":"100","currency":100})), fd, "price", errors)
          errors.map(&.field).should contain("price.currency")
          errors.map(&.code).should contain("invalid_type")
        end
      end

      describe "#normalize" do
        it "backfills the currency from field_definition.currency when missing" do
          fd = FieldDefinition.new(type: MoneyType.new, currency: "USD")
          normalized = subject.normalize(JSON.parse(%({"value":"100"})), fd)
          normalized["currency"].as_s.should eq("USD")
          normalized["value"].as_s.should eq("100")
        end

        it "leaves an already-present currency untouched" do
          fd = FieldDefinition.new(type: MoneyType.new, currency: "USD")
          normalized = subject.normalize(JSON.parse(%({"value":"100","currency":"EUR"})), fd)
          normalized["currency"].as_s.should eq("EUR")
        end

        it "leaves the value unchanged when there is no field-level currency" do
          fd = FieldDefinition.new(type: MoneyType.new)
          original = JSON.parse(%({"value":"100"}))
          subject.normalize(original, fd).should eq(original)
        end

        it "returns a non-object value unchanged so validate surfaces the error" do
          fd = FieldDefinition.new(type: MoneyType.new, currency: "USD")
          original = JSON::Any.new(100_i64)
          subject.normalize(original, fd).should eq(original)
        end
      end

      describe "#validate_definition" do
        it "adds no errors when no currency is specified" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: MoneyType.new)
          subject.validate_definition(fd, "price", errors)
          errors.should be_empty
        end

        # The field-level `currency:` is a backfill default written onto money
        # values that omit it (see `MoneyType#normalize`). It is NOT a
        # foreign-key-style constraint against the runtime currency registry —
        # whether a written currency ticker is known is enforced on the
        # per-value write path (`MoneyType#validate`), so doctype defs stay
        # portable across deployments whose registered currencies differ.
        it "does not validate the field-level currency against the registry" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: MoneyType.new, currency: "XYZ")
          subject.validate_definition(fd, "price", errors)
          errors.should be_empty
        end

        it "accepts the money-allowed capabilities" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: MoneyType.new,
            filters: [FilterCapability::Equality, FilterCapability::Comparison, FilterCapability::Currency],
          )
          subject.validate_definition(fd, "price", errors)
          errors.should be_empty
        end

        it "rejects the interval capability" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: MoneyType.new, filters: [FilterCapability::Interval])
          subject.validate_definition(fd, "price", errors)
          errors.any? { |e| e.message.includes?("interval") && e.message.includes?("money") }.should be_true
        end

        it "rejects the membership capability" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: MoneyType.new, filters: [FilterCapability::Membership])
          subject.validate_definition(fd, "price", errors)
          errors.any?(&.message.includes?("membership")).should be_true
        end

        it "rejects the text_search capability" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: MoneyType.new, filters: [FilterCapability::TextSearch])
          subject.validate_definition(fd, "price", errors)
          errors.any?(&.message.includes?("text_search")).should be_true
        end
      end

      describe ".allowed_capabilities" do
        it "lists equality, comparison, currency" do
          caps = MoneyType.allowed_capabilities
          caps.should contain(FilterCapability::Equality)
          caps.should contain(FilterCapability::Comparison)
          caps.should contain(FilterCapability::Currency)
          caps.size.should eq(3)
        end
      end
    end
  end
end
