# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe LongTextType do
      subject = LongTextType.new

      it "has type_name 'longtext'" do
        subject.type_name.should eq("longtext")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: LongTextType.new)

        it "passes for string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("long content here"), fd, "bio", errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "bio", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "validates pattern when present" do
          fd_with_pattern = FieldDefinition.new(type: LongTextType.new, pattern: "\\d{3,}")
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("abc123def"), fd_with_pattern, "code", errors)
          errors.should be_empty

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("ab"), fd_with_pattern, "code", errors)
          errors.first.message.should contain("does not match pattern")
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: LongTextType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
