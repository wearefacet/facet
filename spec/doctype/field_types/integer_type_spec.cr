# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe IntegerType do
      subject = IntegerType.new

      it "has type_name 'integer'" do
        subject.type_name.should eq("integer")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: IntegerType.new)

        it "passes for integer values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42_i64), fd, "age", errors)
          errors.should be_empty
        end

        it "rejects float values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(3.14_f64), fd, "age", errors)
          errors.map(&.message).should eq(["must be an integer"])
        end

        it "rejects string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("42"), fd, "age", errors)
          errors.map(&.message).should eq(["must be an integer"])
        end

        it "rejects boolean values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "active", errors)
          errors.map(&.message).should eq(["must be an integer"])
        end

        it "rejects null values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(nil), fd, "age", errors)
          errors.map(&.message).should eq(["must be an integer"])
        end

        it "passes for zero" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(0_i64), fd, "count", errors)
          errors.should be_empty
        end

        it "passes for negative integers" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(-1_i64), fd, "offset", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: IntegerType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
