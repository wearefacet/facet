# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/doctype/composition"

module Facet::Doctype
  private def self.parse_definition(json : String) : DoctypeDefinition
    DoctypeDefinition.from_json(json)
  end

  describe Composition do
    describe ".validate" do
      it "accepts a mutual parent/child pair" do
        parent = parse_definition(%({
          "doctype": "Project",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}},
          "children": {"tasks": {"doctype": "Task", "collection": true}}
        }))
        child = parse_definition(%({
          "doctype": "Task",
          "domain": "comp",
          "aggregate_root": false,
          "member_of": "Project",
          "fields": {"title": {"type": "string"}}
        }))

        Composition.validate([parent, child]).should be_empty
      end

      it "accepts a bundle of unrelated roots" do
        a = parse_definition(%({
          "doctype": "Alpha",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}}
        }))
        b = parse_definition(%({
          "doctype": "Beta",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}}
        }))

        Composition.validate([a, b]).should be_empty
      end

      it "rejects a children entry whose target declares no member_of (the hybrid)" do
        parent = parse_definition(%({
          "doctype": "Deal",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}},
          "children": {"activities": {"doctype": "Activity", "collection": true}}
        }))
        # The historical crm.Activity shape: aggregate_root: false, no member_of.
        child = parse_definition(%({
          "doctype": "Activity",
          "domain": "comp",
          "aggregate_root": false,
          "fields": {"subject": {"type": "string"}}
        }))

        problems = Composition.validate([parent, child])
        problems.size.should eq(1)
        problems[0].doctype.should eq("Deal")
        problems[0].message.should contain("Activity")
        problems[0].message.should contain("member_of")
      end

      it "rejects a children entry whose target is missing from the bundle" do
        parent = parse_definition(%({
          "doctype": "Project",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}},
          "children": {"tasks": {"doctype": "Task", "collection": true}}
        }))

        problems = Composition.validate([parent])
        problems.size.should eq(1)
        problems[0].message.should contain("not defined in this domain")
      end

      it "rejects a member_of whose parent has no matching children entry" do
        parent = parse_definition(%({
          "doctype": "Container",
          "domain": "comp",
          "aggregate_root": true,
          "fields": {"name": {"type": "string"}}
        }))
        child = parse_definition(%({
          "doctype": "Thing",
          "domain": "comp",
          "aggregate_root": false,
          "member_of": "Container",
          "fields": {"label": {"type": "string"}}
        }))

        problems = Composition.validate([parent, child])
        problems.size.should eq(1)
        problems[0].doctype.should eq("Thing")
        problems[0].message.should contain("children entry")
      end

      it "rejects a member_of whose parent is missing from the bundle" do
        child = parse_definition(%({
          "doctype": "Thing",
          "domain": "comp",
          "aggregate_root": false,
          "member_of": "Container",
          "fields": {"label": {"type": "string"}}
        }))

        problems = Composition.validate([child])
        problems.size.should eq(1)
        problems[0].message.should contain("not defined in this domain")
      end
    end
  end
end
