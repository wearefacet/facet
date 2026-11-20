# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe DictionaryType do
      subject = DictionaryType.new

      it "has type_name 'dictionary'" do
        subject.type_name.should eq("dictionary")
      end

      describe "#validate" do
        it "passes for object values" do
          val_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: DictionaryType.new, dictionary_value: val_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"key1": "val1", "key2": "val2"})), fd, "metadata", errors)
          errors.should be_empty
        end

        it "rejects non-object values" do
          fd = FieldDefinition.new(type: DictionaryType.new)
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("string"), fd, "metadata", errors)
          errors.map(&.message).should eq(["must be an object (dictionary)"])
        end

        it "validates value types" do
          val_fd = FieldDefinition.new(type: IntegerType.new)
          fd = FieldDefinition.new(type: DictionaryType.new, dictionary_value: val_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"a": 1, "b": "not-int"})), fd, "scores", errors)
          errors.map(&.message).should eq(["must be an integer"])
          errors.first.try(&.field).should eq("scores.b")
        end

        it "allows null values" do
          val_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: DictionaryType.new, dictionary_value: val_fd)
          errors = [] of Facet::ValidationError
          subject.validate(JSON.parse(%({"a": "text", "b": null})), fd, "metadata", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds error when values is missing" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: DictionaryType.new)
          subject.validate_definition(fd, "metadata", errors)
          errors.map(&.message).should eq(["of type 'dictionary' must define 'values'"])
        end

        it "passes when values is defined" do
          val_fd = FieldDefinition.new(type: StringType.new)
          fd = FieldDefinition.new(type: DictionaryType.new, dictionary_value: val_fd)
          errors = [] of Facet::ValidationError
          subject.validate_definition(fd, "metadata", errors)
          errors.should be_empty
        end
      end
    end
  end
end
