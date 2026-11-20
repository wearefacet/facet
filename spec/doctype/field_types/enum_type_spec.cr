# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe EnumType do
      subject = EnumType.new

      it "has type_name 'enum'" do
        subject.type_name.should eq("enum")
      end

      describe "#validate" do
        ev1 = EnumValue.new(key: "active")
        ev2 = EnumValue.new(key: "inactive")
        ev3 = EnumValue.new(key: "pending")
        fd = FieldDefinition.new(type: EnumType.new, values: [ev1, ev2, ev3])

        it "passes for a valid enum value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("active"), fd, "status", errors)
          errors.should be_empty
        end

        it "passes for another valid enum value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("pending"), fd, "status", errors)
          errors.should be_empty
        end

        it "rejects an invalid enum value" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("archived"), fd, "status", errors)
          errors.first.message.should contain("invalid enum value")
          errors.first.message.should contain("archived")
          errors.first.message.should contain("active")
          errors.first.message.should contain("inactive")
        end

        it "stamps params with the value, the allowed list, and the format rule" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("archived"), fd, "status", errors)
          params = errors.first.params.should_not be_nil
          params["value"].should eq("archived")
          params["allowed"].should eq("active, inactive, pending")
          params["format"].should eq("one of: active, inactive, pending")
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "status", errors)
          errors.map(&.message).should eq(["must be a string (enum)"])
        end

        it "passes when values is nil (no constraint)" do
          fd_no_vals = FieldDefinition.new(type: EnumType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("anything"), fd_no_vals, "status", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors for valid enum values" do
          errors = [] of Facet::ValidationError
          ev = EnumValue.new(key: "ok")
          fd = FieldDefinition.new(type: EnumType.new, values: [ev])
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "rejects duplicate keys" do
          errors = [] of Facet::ValidationError
          ev1 = EnumValue.new(key: "dup")
          ev2 = EnumValue.new(key: "dup")
          fd = FieldDefinition.new(type: EnumType.new, values: [ev1, ev2])
          subject.validate_definition(fd, "test", errors)
          errors.any?(&.message.includes?("duplicate enum key")).should be_true
        end

        it "rejects empty key" do
          errors = [] of Facet::ValidationError
          ev = EnumValue.new(key: "")
          fd = FieldDefinition.new(type: EnumType.new, values: [ev])
          subject.validate_definition(fd, "test", errors)
          errors.any?(&.message.includes?("empty")).should be_true
        end

        it "rejects key longer than 64 characters" do
          errors = [] of Facet::ValidationError
          ev = EnumValue.new(key: "a" * 65)
          fd = FieldDefinition.new(type: EnumType.new, values: [ev])
          subject.validate_definition(fd, "test", errors)
          errors.any?(&.message.includes?("exceeds max length")).should be_true
        end
      end
    end
  end
end
