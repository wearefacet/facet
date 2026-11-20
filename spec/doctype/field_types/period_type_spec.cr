# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe PeriodType do
      subject = PeriodType.new

      it "has type_name 'period'" do
        subject.type_name.should eq("period")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: PeriodType.new)

        it "passes for a valid {start, end} object with ISO 8601 datetimes" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.should be_empty
        end

        it "passes with timezone offsets in the datetimes" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01T00:00:00+02:00","end":"2026-02-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.should be_empty
        end

        it "rejects non-object values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2026-01-01"), fd, "tenure", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("must be an object")
        end

        it "rejects an object missing 'end'" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.size.should be >= 1
          errors.first.message.should contain("both 'start' and 'end'")
        end

        it "rejects an object where start >= end (exclusive upper bound)" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-02-01T00:00:00Z","end":"2026-01-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.any?(&.message.includes?("strictly before")).should be_true
        end

        it "rejects equal start and end (exclusive upper bound)" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z","end":"2026-01-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.any?(&.message.includes?("strictly before")).should be_true
        end

        it "rejects plain date strings for the bounds (period requires a time)" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01","end":"2026-02-01"}))
          subject.validate(value, fd, "tenure", errors)
          errors.any? { |e| e.message.includes?("must include a time component") }.should be_true
        end

        it "rejects an invalid ISO 8601 datetime in start" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"not-a-date","end":"2026-02-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.any? { |e| e.field == "tenure.start" && e.message.includes?("not a valid ISO 8601 datetime") }.should be_true
        end

        it "rejects integer values for start" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":42,"end":"2026-02-01T00:00:00Z"}))
          subject.validate(value, fd, "tenure", errors)
          errors.any? { |e| e.field == "tenure.start" }.should be_true
        end
      end

      describe "#normalize" do
        fd = FieldDefinition.new(type: PeriodType.new)

        it "returns the value unchanged for a non-object" do
          result = subject.normalize(JSON::Any.new("2026-01-01"), fd)
          result.raw.should eq("2026-01-01")
        end

        it "returns the value unchanged when 'start' or 'end' is missing" do
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z"}))
          result = subject.normalize(value, fd)
          result.should eq(value)
        end

        it "returns the value unchanged when a bound is unparseable" do
          value = JSON.parse(%({"start":"not-a-date","end":"2026-02-01T00:00:00Z"}))
          result = subject.normalize(value, fd)
          result.should eq(value)
        end

        it "normalizes both bounds to UTC RFC‑3339" do
          value = JSON.parse(%({"start":"2026-01-01T00:00:00+02:00","end":"2026-02-01T00:00:00-05:00"}))
          result = subject.normalize(value, fd)
          result["start"].raw.should eq("2025-12-31T22:00:00Z")
          result["end"].raw.should eq("2026-02-01T05:00:00Z")
        end

        it "leaves already‑UTC bounds untouched" do
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z"}))
          result = subject.normalize(value, fd)
          result["start"].raw.should eq("2026-01-01T00:00:00Z")
          result["end"].raw.should eq("2026-02-01T00:00:00Z")
        end

        it "preserves other keys in the object" do
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z","label":"Q1"}))
          result = subject.normalize(value, fd)
          result["label"].raw.should eq("Q1")
        end
      end

      describe "#validate_definition" do
        it "passes for allowed capabilities" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: PeriodType.new,
            filters: [FilterCapability::Equality, FilterCapability::Interval],
          )
          subject.validate_definition(fd, "tenure", errors)
          errors.should be_empty
        end

        it "rejects the 'comparison' capability" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: PeriodType.new,
            filters: [FilterCapability::Comparison],
          )
          subject.validate_definition(fd, "tenure", errors)
          errors.any?(&.message.includes?("comparison")).should be_true
        end

        it "rejects 'text_search', 'membership', 'currency'" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: PeriodType.new,
            filters: [FilterCapability::TextSearch, FilterCapability::Membership, FilterCapability::Currency],
          )
          subject.validate_definition(fd, "tenure", errors)
          errors.size.should eq(3)
        end

        it "passes when no filters are declared" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: PeriodType.new)
          subject.validate_definition(fd, "tenure", errors)
          errors.should be_empty
        end
      end

      describe ".allowed_capabilities" do
        it "lists equality and interval" do
          caps = PeriodType.allowed_capabilities
          caps.should contain(FilterCapability::Equality)
          caps.should contain(FilterCapability::Interval)
          caps.size.should eq(2)
        end
      end
    end
  end
end
