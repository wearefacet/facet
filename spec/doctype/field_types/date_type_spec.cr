# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DateType do
      subject = DateType.new

      it "has type_name 'date'" do
        subject.type_name.should eq("date")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: DateType.new)

        it "passes for a valid YYYY-MM-DD date" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15"), fd, "hired_on", errors)
          errors.should be_empty
        end

        it "passes for the minimum / maximum edge dates" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("0001-01-01"), fd, "hired_on", errors)
          subject.validate(JSON::Any.new("9999-12-31"), fd, "hired_on", errors)
          errors.should be_empty
        end

        it "accepts Feb 29 on a leap year" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2024-02-29"), fd, "hired_on", errors)
          errors.should be_empty
        end

        it "rejects Feb 29 on a non-leap year" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-02-29"), fd, "hired_on", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("not a valid calendar date")
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "hired_on", errors)
          errors.map(&.message).should eq(["must be a string (ISO 8601 date YYYY-MM-DD)"])
        end

        it "rejects datetimes (with time component)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15T10:30:00Z"), fd, "hired_on", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("expected YYYY-MM-DD")
        end

        it "rejects invalid calendar dates (month 13)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-13-01"), fd, "hired_on", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("not a valid calendar date")
        end

        it "rejects malformed strings" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("not-a-date"), fd, "hired_on", errors)
          errors.size.should eq(1)
          errors.first.message.should contain("expected YYYY-MM-DD")
        end

        it "rejects European-style DD-MM-YYYY" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("15-01-2025"), fd, "hired_on", errors)
          errors.size.should eq(1)
        end

        it "rejects slash separator" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025/01/15"), fd, "hired_on", errors)
          errors.size.should eq(1)
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DateType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
