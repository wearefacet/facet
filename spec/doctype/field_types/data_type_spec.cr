# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DataType do
      subject = DataType.new

      it "has type_name 'data'" do
        subject.type_name.should eq("data")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: DataType.new)

        it "always rejects any value (computed fields cannot be set by user)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("anything"), fd, "full_name", errors)
          errors.map(&.message).should eq(["is computed (data) and should not be set"])

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "count", errors)
          errors.map(&.message).should eq(["is computed (data) and should not be set"])

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(true), fd, "flag", errors)
          errors.map(&.message).should eq(["is computed (data) and should not be set"])
        end
      end

      describe "#validate_definition" do
        it "adds no errors" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DataType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
