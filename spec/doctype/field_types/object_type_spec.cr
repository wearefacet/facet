# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe ObjectType do
      subject = ObjectType.new

      it "has type_name 'object'" do
        subject.type_name.should eq("object")
      end

      describe "#validate" do
        it "passes for object values" do
          fd = FieldDefinition.new(type: ObjectType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"key": "val"})), fd, "metadata", errors)
          errors.should be_empty
        end

        it "rejects non-object values" do
          fd = FieldDefinition.new(type: ObjectType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("string"), fd, "metadata", errors)
          errors.map(&.message).should eq(["must be an object (JSON object)"])
        end

        it "validates sub-fields when properties is present" do
          props = {
            "name" => FieldDefinition.new(type: StringType.new, required: true),
            "age"  => FieldDefinition.new(type: IntegerType.new),
          }
          fd = FieldDefinition.new(type: ObjectType.new, properties: props)

          # Missing required sub-field
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"age": 30})), fd, "person", errors)
          errors.map(&.message).should eq(["is required"])
          errors.first.try(&.field).should eq("person.name")

          # Type mismatch on sub-field
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"name": "Alice", "age": "not-a-number"})), fd, "person", errors)
          errors.map(&.message).should eq(["must be an integer"])
          errors.first.try(&.field).should eq("person.age")
        end

        it "rejects unknown sub-fields when properties is present" do
          props = {
            "name" => FieldDefinition.new(type: StringType.new),
          }
          fd = FieldDefinition.new(type: ObjectType.new, properties: props)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"name": "Alice", "unknown": "value"})), fd, "person", errors)
          errors.map(&.message).should eq(["is not a defined field"])
          errors.first.try(&.field).should eq("person.unknown")
        end

        it "passes for free-form objects when no properties" do
          fd = FieldDefinition.new(type: ObjectType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"anything": "goes", "nested": {"x": 1}})), fd, "data", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors for plain object" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ObjectType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "recurses into nested sub-fields" do
          props = {
            "name" => FieldDefinition.new(type: StringType.new),
          }
          fd = FieldDefinition.new(type: ObjectType.new, properties: props)
          errors = [] of Facet::ValidationError
          subject.validate_definition(fd, "person", errors)
          errors.should be_empty
        end
      end
    end
  end
end
