# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe FileType do
      subject = FileType.new

      it "has type_name 'file'" do
        subject.type_name.should eq("file")
      end

      # ── validate (ULID shape) ───────────────────────────────────────────

      describe "#validate" do
        fd = FieldDefinition.new(type: FileType.new)
        base_path = "avatar"

        it "passes for a 26-character ULID" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("01HZZZZZZZZZZZZZZZZZZZZZZZ"), fd, base_path, errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, base_path, errors)
          errors.first.code.should eq("invalid_type")
        end

        it "rejects a malformed ULID" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("not-a-ulid"), fd, base_path, errors)
          errors.first.code.should eq("invalid_format")
        end
      end

      # ── validate_definition (accept allow-list) ────────────────────────

      describe "#validate_definition" do
        it "adds no errors when accept is absent" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: FileType.new)
          subject.validate_definition(fd, "avatar", errors)
          errors.should be_empty
        end

        it "adds no errors for valid accept patterns" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: FileType.new, accept: ["image/*", "application/pdf"])
          subject.validate_definition(fd, "avatar", errors)
          errors.should be_empty
        end

        it "adds an error for a malformed accept pattern" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: FileType.new, accept: ["image/*", "not-a-mime"])
          subject.validate_definition(fd, "avatar", errors)
          errors.should_not be_empty
          errors.first.field.should eq("avatar.accept")
          errors.first.code.should eq("invalid_format")
          errors.first.message.should contain("not-a-mime")
        end

        it "rejects a wildcard type" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: FileType.new, accept: ["*/vnd.ms-excel"])
          subject.validate_definition(fd, "avatar", errors)
          errors.should_not be_empty
          errors.first.message.should contain("*/vnd.ms-excel")
        end
      end
    end
  end
end
