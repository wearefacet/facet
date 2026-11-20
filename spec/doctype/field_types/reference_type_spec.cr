# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe ReferenceType do
      subject = ReferenceType.new

      it "has type_name 'reference'" do
        subject.type_name.should eq("reference")
      end

      describe "#validate" do
        it "passes for a fully qualified reference matching the declared doctype" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("hr.Employee.abc123"), fd, "manager", errors)
          errors.should be_empty
        end

        it "passes for null values" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new(nil), fd, "manager", errors)
          errors.should be_empty
        end

        it "rejects integer values" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new(42), fd, "manager", errors)
          errors.map(&.message).should eq(["must be a string (qualified reference id) or null"])
        end

        it "rejects boolean values" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new(true), fd, "manager", errors)
          errors.map(&.message).should eq(["must be a string (qualified reference id) or null"])
        end

        it "rejects object values" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON.parse(%({"id": "abc"})), fd, "manager", errors)
          errors.map(&.message).should eq(["must be a string (qualified reference id) or null"])
        end

        it "rejects a bare id with no domain/doctype prefix" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("abc123"), fd, "manager", errors)
          errors.any? { |e| e.code == "invalid_reference_format" }.should be_true
        end

        it "rejects a two-segment value (domain.Doctype with no id)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("hr.Employee"), fd, "manager", errors)
          errors.any? { |e| e.code == "invalid_reference_format" }.should be_true
        end

        it "rejects a qualified value whose prefix does not match the declared doctype" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("catalog.Product.abc123"), fd, "manager", errors)
          errors.any? { |e| e.code == "reference_doctype_mismatch" }.should be_true
        end

        it "accepts an id segment that itself contains a dot" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "production.Project")
          subject.validate(JSON::Any.new("production.Project.1.task.1"), fd, "parent", errors)
          errors.should be_empty
        end

        # A reference field with no declared `doctype` is polymorphic (e.g. the
        # `target` field of a sidecar doctype). The value is accepted as long
        # as it is a well-formed qualified id; whether the prefix resolves to a
        # registered doctype is a separate concern.
        it "accepts a well-formed qualified value on a polymorphic reference" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new)
          subject.validate(JSON::Any.new("hr.Employee.01ABCDEFG"), fd, "target", errors)
          errors.should be_empty
        end

        it "rejects a malformed value on a polymorphic reference" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new)
          subject.validate(JSON::Any.new("hr.Employee"), fd, "target", errors)
          errors.any? { |e| e.code == "invalid_reference_format" }.should be_true
        end

        # ── URN form (B-104) ───────────────────────────────────────

        # `#normalize` converts a facet URN to its dotted form before
        # validation; these examples pin the behavior when validate sees
        # the value directly (a write path that has not normalized yet) —
        # the URN is checked as its dotted equivalent.
        it "accepts a facet URN matching the declared doctype" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("urn:facet:hr:Employee:01ABC"), fd, "manager", errors)
          errors.should be_empty
        end

        it "rejects a facet URN whose prefix does not match the declared doctype" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("urn:facet:catalog:Product:1"), fd, "manager", errors)
          errors.any? { |e| e.code == "reference_doctype_mismatch" }.should be_true
        end

        it "rejects a malformed facet URN with a clear message" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("urn:facet:hr:Employee"), fd, "manager", errors)
          errors.map(&.code).should eq(["invalid_reference_format"])
          errors.first.message.should contain("well-formed facet document URN")
        end

        it "rejects a state-pinned facet URN" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          subject.validate(JSON::Any.new("urn:facet:hr:Employee:01ABC?state=01XYZ"), fd, "manager", errors)
          errors.map(&.code).should eq(["invalid_reference_format"])
          errors.first.message.should contain("state-pinned")
        end

        it "accepts a well-formed facet URN on a polymorphic reference" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new)
          subject.validate(JSON::Any.new("urn:facet:hr:Employee:01ABC"), fd, "target", errors)
          errors.should be_empty
        end

        # ── collection: true ───────────────────────────────────────────

        it "passes for an array of qualified references matching the declared doctype" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123", "hr.Employee.def456"])), fd, "assignees", errors)
          errors.should be_empty
        end

        it "passes for an empty array" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%([])), fd, "assignees", errors)
          errors.should be_empty
        end

        it "skips null elements" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%([null, "hr.Employee.abc123"])), fd, "assignees", errors)
          errors.should be_empty
        end

        it "rejects a scalar value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON::Any.new("hr.Employee.abc123"), fd, "assignees", errors)
          errors.map(&.message).should eq(["must be an array"])
        end

        it "validates each element and reports errors at the indexed path" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123", "catalog.Product.xyz"])), fd, "assignees", errors)
          errors.map(&.field).should eq(["assignees.1"])
          errors.map(&.code).should eq(["reference_doctype_mismatch"])
        end

        it "passes for a single-element array" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123"])), fd, "assignees", errors)
          errors.should be_empty
        end

        it "passes for distinct targets in one array" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123", "hr.Employee.def456", "hr.Employee.ghi789"])), fd, "assignees", errors)
          errors.should be_empty
        end

        # A repeated target renders one capsule per token against a keyed
        # each-block whose key is the token, so the render throws. The write
        # path rejects the value instead of normalizing it away (F10-A).
        it "rejects an array that repeats the same target (F10-A)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123", "hr.Employee.def456", "hr.Employee.abc123"])), fd, "assignees", errors)
          errors.size.should eq(1)
          errors.first.field.should eq("assignees")
          errors.first.code.should eq("duplicate_reference_target")
          errors.first.message.should contain("repeats the reference target 'hr.Employee.abc123'")
        end

        it "reports each duplicated target once" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          subject.validate(JSON.parse(%(["hr.Employee.abc123", "hr.Employee.abc123", "hr.Employee.abc123"])), fd, "assignees", errors)
          errors.map(&.code).should eq(["duplicate_reference_target"])
        end
      end

      describe "#normalize" do
        it "qualifies a bare id using the field's declared doctype" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("abc123"), fd)
          result.raw.should eq("hr.Employee.abc123")
        end

        it "leaves an already-qualified value unchanged" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("hr.Employee.abc123"), fd)
          result.raw.should eq("hr.Employee.abc123")
        end

        it "qualifies a two-segment id whose prefix does not match the field's doctype" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("catalog.Product.1"), fd)
          result.raw.should eq("hr.Employee.catalog.Product.1")
        end

        it "preserves an id segment that itself contains a dot" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "production.Project")
          result = subject.normalize(JSON::Any.new("1.task.1"), fd)
          result.raw.should eq("production.Project.1.task.1")
        end

        it "passes null through unchanged" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new(nil), fd)
          result.raw.should be_nil
        end

        it "passes a non-string value through unchanged" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new(42), fd)
          result.raw.should eq(42)
        end

        it "returns the value unchanged when the field has no declared doctype" do
          fd = FieldDefinition.new(type: ReferenceType.new)
          result = subject.normalize(JSON::Any.new("abc123"), fd)
          result.raw.should eq("abc123")
        end

        # ── collection: true ───────────────────────────────────────────

        it "qualifies each bare id element in an array" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          result = subject.normalize(JSON.parse(%(["abc123", "hr.Employee.def456"])), fd)
          result.as_a.map(&.raw).should eq(["hr.Employee.abc123", "hr.Employee.def456"])
        end

        it "passes a non-array value through unchanged" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          result = subject.normalize(JSON::Any.new("abc123"), fd)
          result.raw.should eq("abc123")
        end

        it "skips null elements" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          result = subject.normalize(JSON.parse(%([null, "abc123"])), fd)
          result.as_a.map(&.raw).should eq([nil, "hr.Employee.abc123"])
        end

        # ── URN form (B-104) ───────────────────────────────────────

        it "converts a facet URN to the dotted storage form" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("urn:facet:hr:Employee:01ABC"), fd)
          result.raw.should eq("hr.Employee.01ABC")
        end

        it "converts a facet URN on a polymorphic reference" do
          fd = FieldDefinition.new(type: ReferenceType.new)
          result = subject.normalize(JSON::Any.new("urn:facet:hr:Employee:01ABC"), fd)
          result.raw.should eq("hr.Employee.01ABC")
        end

        it "leaves a malformed facet URN unchanged for validation to report" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("urn:facet:hr:Employee"), fd)
          result.raw.should eq("urn:facet:hr:Employee")
        end

        it "leaves a state-pinned facet URN unchanged for validation to report" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee")
          result = subject.normalize(JSON::Any.new("urn:facet:hr:Employee:01ABC?state=01XYZ"), fd)
          result.raw.should eq("urn:facet:hr:Employee:01ABC?state=01XYZ")
        end

        it "converts facet URN elements in a collection" do
          fd = FieldDefinition.new(type: ReferenceType.new, doctype: "hr.Employee", collection: true)
          result = subject.normalize(JSON.parse(%(["urn:facet:hr:Employee:01ABC"])), fd)
          result.as_a.map(&.raw).should eq(["hr.Employee.01ABC"])
        end
      end

      describe "#validate_definition" do
        it "adds no errors when filter is absent" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "adds no errors when filter is empty" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {} of String => JSON::Any)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with eq operator" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"status__eq" => JSON::Any.new("active")})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with implicit eq (no __op suffix)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"status" => JSON::Any.new("active")})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with match operator" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"name__match" => JSON::Any.new("Inc")})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with numeric value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"priority__eq" => JSON::Any.new(1_i64)})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with boolean value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"active__eq" => JSON::Any.new(true)})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "passes for a valid filter with null value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"deleted_at__eq" => JSON::Any.new(nil)})
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end

        it "rejects an unknown operator" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"status__unknown" => JSON::Any.new("active")})
          subject.validate_definition(fd, "test", errors)
          errors.should_not be_empty
          errors.first.message.should contain("unknown operator")
        end

        it "rejects an object value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"nested" => JSON.parse(%({"key": "val"}))})
          subject.validate_definition(fd, "test", errors)
          errors.should_not be_empty
          errors.first.message.should contain("primitive")
        end

        it "rejects an array value" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"tags" => JSON.parse(%([1, 2, 3]))})
          subject.validate_definition(fd, "test", errors)
          errors.should_not be_empty
          errors.first.message.should contain("primitive")
        end

        it "rejects an empty field name in filter key" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: ReferenceType.new, filter: {"__eq" => JSON::Any.new("value")})
          subject.validate_definition(fd, "test", errors)
          errors.should_not be_empty
          errors.first.message.should contain("empty field name")
        end
      end
    end
  end
end
