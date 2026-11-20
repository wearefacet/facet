# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe ArrayType do
      subject = ArrayType.new

      it "has type_name 'array'" do
        subject.type_name.should eq("array")
      end

      describe "#validate" do
        it "passes for array values" do
          items_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: ArrayType.new, items: items_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%(["a", "b", "c"])), fd, "tags", errors)
          errors.should be_empty
        end

        it "rejects non-array values" do
          fd = FieldDefinition.new(type: ArrayType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("string"), fd, "tags", errors)
          errors.map(&.message).should eq(["must be an array"])
          errors.first.try(&.field).should eq("tags")
        end

        it "validates element types when items is present" do
          items_fd = FieldDefinition.new(type: IntegerType.new)
          fd = FieldDefinition.new(type: ArrayType.new, items: items_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%([1, "not-a-number", 3])), fd, "scores", errors)
          errors.map(&.message).should eq(["must be an integer"])
          errors.first.try(&.field).should eq("scores.1")
        end

        it "allows null elements" do
          items_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: ArrayType.new, items: items_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%(["a", null, "c"])), fd, "tags", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds error when items is missing" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ArrayType.new)
          subject.validate_definition(fd, "tags", errors)
          errors.map(&.message).should eq(["of type 'array' must define 'items'"])
          errors.first.try(&.field).should eq("tags")
        end

        it "passes when items is defined" do
          items_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: ArrayType.new, items: items_fd)
          errors = [] of Facet::ValidationError
          subject.validate_definition(fd, "tags", errors)
          errors.should be_empty
        end
      end
    end
  end
end
