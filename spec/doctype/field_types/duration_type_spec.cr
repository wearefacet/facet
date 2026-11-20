# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DurationType do
      subject = DurationType.new

      it "has type_name 'duration'" do
        subject.type_name.should eq("duration")
      end

      it "is registered under 'duration'" do
        FieldType.parse("duration").should eq(DurationType.new)
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: DurationType.new)

        it "passes for non-negative integers" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(3600_i64), fd, "sla", errors)
          errors.should be_empty
        end

        it "passes for zero" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(0_i64), fd, "sla", errors)
          errors.should be_empty
        end

        it "passes for day-spanning values" do
          errors = [] of Facet::ValidationError
          # 2 days = 2 * 86400
          subject.validate(JSON::Any.new(172_800_i64), fd, "sla", errors)
          errors.should be_empty
        end

        it "rejects negative integers" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(-1_i64), fd, "sla", errors)
          errors.size.should eq(1)
          errors.first.code.should eq("out_of_range")
        end

        it "rejects float values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(1.5_f64), fd, "sla", errors)
          errors.map(&.code).should eq(["invalid_type"])
        end

        it "rejects string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("3600"), fd, "sla", errors)
          errors.map(&.code).should eq(["invalid_type"])
        end

        it "rejects boolean values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "sla", errors)
          errors.map(&.code).should eq(["invalid_type"])
        end

        it "rejects null values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(nil), fd, "sla", errors)
          errors.map(&.code).should eq(["invalid_type"])
        end
      end

      describe "#validate_definition" do
        it "accepts equality and comparison" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: DurationType.new,
            filters: [FilterCapability::Equality, FilterCapability::Comparison],
          )
          subject.validate_definition(fd, "sla", errors)
          errors.should be_empty
        end

        it "rejects interval" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: DurationType.new,
            filters: [FilterCapability::Interval],
          )
          subject.validate_definition(fd, "sla", errors)
          errors.any? { |e| e.message.includes?("interval") && e.message.includes?("duration") }.should be_true
        end

        it "rejects membership and currency" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(
            type: DurationType.new,
            filters: [FilterCapability::Membership, FilterCapability::Currency],
          )
          subject.validate_definition(fd, "sla", errors)
          errors.any?(&.message.includes?("membership")).should be_true
          errors.any?(&.message.includes?("currency")).should be_true
        end

        it "adds no errors when filters is nil" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DurationType.new)
          subject.validate_definition(fd, "sla", errors)
          errors.should be_empty
        end
      end
    end
  end
end
