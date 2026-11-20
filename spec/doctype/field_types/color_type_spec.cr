# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe ColorType do
      subject = ColorType.new

      it "has type_name 'color'" do
        subject.type_name.should eq("color")
      end

      # ── Validation (happy) ─────────────────────────────────────────────

      describe "#validate" do
        fd = FieldDefinition.new(type: ColorType.new)
        base_path = "color_field"

        it "passes for valid hex colors" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("#FF00CC"), fd, base_path, errors)
          errors.should be_empty
        end

        it "passes for valid rgb/rgba colors" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("rgb(255, 0, 0)"), fd, base_path, errors)
          errors.should be_empty

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("rgba(255, 0, 0, 0.5)"), fd, base_path, errors)
          errors.should be_empty
        end

        it "passes for valid hsl/hsla colors" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hsl(210, 100%, 50%)"), fd, base_path, errors)
          errors.should be_empty

          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hsla(210, 100%, 50%, 0.5)"), fd, base_path, errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, base_path, errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects invalid hex format" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("#GGG"), fd, base_path, errors)
          errors.first.message.should contain("Invalid color format")
        end

        it "rejects invalid rgb values (out of range)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("rgb(300, 0, 0)"), fd, base_path, errors)
          errors.first.message.should contain("range")
        end

        it "rejects malformed rgb syntax" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("rgb(255, 0)"), fd, base_path, errors)
          errors.first.message.should contain("Invalid color format")
        end

        it "rejects out-of-range HSL hue" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("hsl(400, 50%, 50%)"), fd, base_path, errors)
          errors.first.message.should contain("out of range")
        end

        it "rejects alpha out of range" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("rgba(255, 0, 0, 1.5)"), fd, base_path, errors)
          errors.first.message.should contain("Alpha must be in range")
        end

        it "rejects completely invalid strings" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("not-a-color"), fd, base_path, errors)
          errors.first.message.should contain("Invalid color format")
        end
      end

      # ── Normalization (B-103) ─────────────────────────────────────────

      describe "#normalize" do
        fd = FieldDefinition.new(type: ColorType.new)

        it "normalizes 3-digit hex to #RRGGBBAA" do
          subject.normalize(JSON::Any.new("#f00"), fd).raw.should eq("#ff0000ff")
          subject.normalize(JSON::Any.new("#ABC"), fd).raw.should eq("#aabbccff")
        end

        it "normalizes 8-digit hex to its own canonical form" do
          subject.normalize(JSON::Any.new("#11223344"), fd).raw.should eq("#11223344")
        end

        it "normalizes rgb/rgba with alpha defaulting to FF" do
          subject.normalize(JSON::Any.new("rgb(255, 0, 0)"), fd).raw.should eq("#ff0000ff")
          subject.normalize(JSON::Any.new("rgba(255, 0, 0, 0.5)"), fd).raw.should eq("#ff000080")
        end

        it "normalizes hsl/hsla" do
          subject.normalize(JSON::Any.new("hsl(300, 100%, 50%)"), fd).raw.should eq("#ff00ffff")
          subject.normalize(JSON::Any.new("hsla(210, 100%, 50%, 0.5)"), fd).raw.should eq("#007fff80")
        end

        it "passes a non-string value through unchanged" do
          subject.normalize(JSON::Any.new(42), fd).raw.should eq(42)
        end

        it "passes an unparseable string through unchanged (validate reports it)" do
          subject.normalize(JSON::Any.new("not-a-color"), fd).raw.should eq("not-a-color")
        end
      end

      # ── validate_definition (no-op) ─────────────────────────────────────

      describe "#validate_definition" do
        it "adds no errors (no schema-level constraints)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ColorType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
