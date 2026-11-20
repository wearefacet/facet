# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe StringType do
      subject = StringType.new

      it "has type_name 'string'" do
        subject.type_name.should eq("string")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: StringType.new)

        it "passes for string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hello"), fd, "name", errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "name", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects boolean values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "active", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects array values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%(["a", "b"])), fd, "tags", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects null values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(nil), fd, "name", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "validates pattern when present" do
          fd_with_pattern = FieldDefinition.new(type: StringType.new, pattern: "^[a-z]+$")
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hello"), fd_with_pattern, "slug", errors)
          errors.should be_empty

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("Hello123"), fd_with_pattern, "slug", errors)
          errors.map(&.message).should eq(["does not match pattern '^[a-z]+$'"])
        end

        # B-57: min/max are length bounds for text types — declared but
        # inert constraints are the silent-success class.
        it "rejects a value shorter than the declared min" do
          fd_with_min = FieldDefinition.new(type: StringType.new, min: 2)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("a"), fd_with_min, "code", errors)
          errors.size.should eq(1)
          errors[0].message.should eq("must be at least 2 characters")
          errors[0].code.should eq("out_of_range")
          errors[0].params.should eq({"value" => "a", "min" => "2"})
        end

        it "rejects a value longer than the declared max" do
          fd_with_max = FieldDefinition.new(type: StringType.new, max: 4)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("abcde"), fd_with_max, "code", errors)
          errors.size.should eq(1)
          errors[0].message.should eq("must be at most 4 characters")
          errors[0].code.should eq("out_of_range")
        end

        it "passes boundary values" do
          fd_bounded = FieldDefinition.new(type: StringType.new, min: 2, max: 4)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("ab"), fd_bounded, "code", errors)
          errors.should be_empty

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("abcd"), fd_bounded, "code", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: StringType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
