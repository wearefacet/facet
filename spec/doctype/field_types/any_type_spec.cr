# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe AnyType do
      subject = AnyType.new

      it "has type_name 'any'" do
        subject.type_name.should eq("any")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: AnyType.new)

        it "passes for string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hello"), fd, "data", errors)
          errors.should be_empty
        end

        it "passes for integer values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42_i64), fd, "data", errors)
          errors.should be_empty
        end

        it "passes for boolean values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "data", errors)
          errors.should be_empty
        end

        it "passes for null values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(nil), fd, "data", errors)
          errors.should be_empty
        end

        it "passes for array values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%([1, 2, 3])), fd, "data", errors)
          errors.should be_empty
        end

        it "passes for object values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"key": "val"})), fd, "data", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: AnyType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
