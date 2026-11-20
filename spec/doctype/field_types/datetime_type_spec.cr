# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DatetimeType do
      subject = DatetimeType.new

      it "has type_name 'datetime'" do
        subject.type_name.should eq("datetime")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: DatetimeType.new)

        it "passes for valid ISO 8601 datetime" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15T10:30:00Z"), fd, "created", errors)
          errors.should be_empty
        end

        it "passes for ISO 8601 with timezone offset" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15T10:30:00+02:00"), fd, "created", errors)
          errors.should be_empty
        end

        it "passes for ISO 8601 with fractional seconds" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15T10:30:00.123Z"), fd, "created", errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "created", errors)
          errors.map(&.message).should eq(["must be a string (ISO 8601 datetime)"])
        end

        it "rejects invalid datetime strings" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("not-a-date"), fd, "created", errors)
          errors.first.message.should contain("not a valid ISO 8601 datetime")
        end

        it "rejects strings with no time component" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("2025-01-15"), fd, "created", errors)
          errors.first.message.should contain("not a valid ISO 8601 datetime")
        end
      end

      describe "#normalize" do
        fd = FieldDefinition.new(type: DatetimeType.new)

        it "returns the value unchanged for a non-string" do
          # `validate` still surfaces the original error message.
          result = subject.normalize(JSON::Any.new(42), fd)
          result.raw.should eq(42)
        end

        it "returns the value unchanged for an unparseable string" do
          result = subject.normalize(JSON::Any.new("not-a-date"), fd)
          result.raw.should eq("not-a-date")
        end

        it "leaves a UTC ISO‑8601 value as UTC RFC‑3339" do
          result = subject.normalize(JSON::Any.new("2025-01-15T10:30:00Z"), fd)
          result.raw.should eq("2025-01-15T10:30:00Z")
        end

        it "normalizes a timezone offset to UTC RFC‑3339" do
          result = subject.normalize(JSON::Any.new("2025-01-15T10:30:00+02:00"), fd)
          result.raw.should eq("2025-01-15T08:30:00Z")
        end

        it "normalizes a negative timezone offset to UTC RFC‑3339" do
          result = subject.normalize(JSON::Any.new("2025-01-15T10:30:00-05:00"), fd)
          result.raw.should eq("2025-01-15T15:30:00Z")
        end

        it "drops fractional seconds in the canonical form" do
          result = subject.normalize(JSON::Any.new("2025-01-15T10:30:00.123Z"), fd)
          result.raw.should eq("2025-01-15T10:30:00Z")
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DatetimeType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
