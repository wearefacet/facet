# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe PhoneType do
      subject = PhoneType.new

      it "has type_name 'phone'" do
        subject.type_name.should eq("phone")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: PhoneType.new)

        it "passes for a plain phone number" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("+1-555-0100"), fd, "phone", errors)
          errors.should be_empty
        end

        it "passes for a number with spaces and extension" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("+44 7700 900123 ext 42"), fd, "phone", errors)
          errors.should be_empty
        end

        it "passes for a bare number" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("5550100"), fd, "phone", errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "phone", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects an empty string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(""), fd, "phone", errors)
          errors.first.message.should eq("must not be empty")
        end
      end

      describe "#validate_definition" do
        it "adds no errors (no schema-level constraints)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: PhoneType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
