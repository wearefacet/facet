# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe BooleanType do
      subject = BooleanType.new

      it "has type_name 'boolean'" do
        subject.type_name.should eq("boolean")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: BooleanType.new)

        it "passes for true" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "active", errors)
          errors.should be_empty
        end

        it "passes for false" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(false), fd, "active", errors)
          errors.should be_empty
        end

        it "rejects integer values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(1), fd, "active", errors)
          errors.map(&.message).should eq(["must be a boolean"])
        end

        it "rejects string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("true"), fd, "active", errors)
          errors.map(&.message).should eq(["must be a boolean"])
        end

        it "rejects null values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(nil), fd, "active", errors)
          errors.map(&.message).should eq(["must be a boolean"])
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: BooleanType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
