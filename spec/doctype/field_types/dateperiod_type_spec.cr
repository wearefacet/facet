# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DatePeriodType do
      subject = DatePeriodType.new

      it "has type_name 'dateperiod'" do
        subject.type_name.should eq("dateperiod")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: DatePeriodType.new)

        it "passes for a valid {start, end} interval of YYYY-MM-DD dates" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01","end":"2026-01-31"}))
          subject.validate(value, fd, "calendar", errors)
          errors.should be_empty
        end

        it "allows start == end (inclusive both ends → single-day range)" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-15","end":"2026-01-15"}))
          subject.validate(value, fd, "calendar", errors)
          errors.should be_empty
        end

        it "rejects non-object values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2026-01-01"), fd, "calendar", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("must be an object")
        end

        it "rejects an object missing 'end'" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01"}))
          subject.validate(value, fd, "calendar", errors)
          errors.first.message.should contain("both 'start' and 'end'")
        end

        it "rejects start > end" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-02-01","end":"2026-01-01"}))
          subject.validate(value, fd, "calendar", errors)
          errors.any?(&.message.includes?("on or before")).should be_true
        end

        it "rejects datetime values for the bounds (dateperiod requires YYYY-MM-DD)" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z"}))
          subject.validate(value, fd, "calendar", errors)
          errors.size.should eq(2)
          errors.all?(&.message.includes?("expected YYYY-MM-DD")).should be_true
        end

        it "rejects an invalid calendar date" do
          errors = [] of Facet::ValidationError
          value = JSON.parse(%({"start":"2025-13-01","end":"2026-01-01"}))
          subject.validate(value, fd, "calendar", errors)
          errors.any? { |e| e.message.includes?("not a valid calendar date") }.should be_true
        end
      end

      describe "#validate_definition" do
        it "passes for allowed capabilities" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: DatePeriodType.new,
            filters: [FilterCapability::Equality, FilterCapability::Interval],
          )
          subject.validate_definition(fd, "calendar", errors)
          errors.should be_empty
        end

        it "rejects the 'comparison' capability" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: DatePeriodType.new,
            filters: [FilterCapability::Comparison],
          )
          subject.validate_definition(fd, "calendar", errors)
          errors.any?(&.message.includes?("comparison")).should be_true
        end

        it "passes when no filters are declared" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DatePeriodType.new)
          subject.validate_definition(fd, "calendar", errors)
          errors.should be_empty
        end
      end

      describe ".allowed_capabilities" do
        it "lists equality and interval" do
          caps = DatePeriodType.allowed_capabilities
          caps.should contain(FilterCapability::Equality)
          caps.should contain(FilterCapability::Interval)
          caps.size.should eq(2)
        end
      end
    end
  end
end
