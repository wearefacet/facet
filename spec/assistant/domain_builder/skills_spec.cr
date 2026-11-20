# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/domain_builder/skills"

module Facet::Assistant::DomainBuilder
  describe Skills do
    describe ".list" do
      it "returns all skill files from the skills directory" do
        skills = Skills.list
        names = skills.map(&.name)
        # The 14 canonical skills should all be present.
        names.should contain("doctype-anatomy")
        names.should contain("field-types")
        names.should contain("lifecycle-scripts")
        names.should contain("named-scopes")
        names.should contain("replication")
        names.should contain("document-views")
        names.should contain("children-and-composition")
        names.should contain("rbac-context-sets")
        names.should contain("validation-and-check")
        names.should contain("iteration-workflow")
        names.should contain("lua-document-helpers")
        names.should contain("lua-actor")
        names.should contain("display-and-identity")
        names.should contain("reference-patterns")
        names.should contain("collection-views")
      end

      it "returns skills sorted by name" do
        names = Skills.list.map(&.name)
        names.should eq(names.sort)
      end

      it "parses front-matter (title, description, tags)" do
        skill = Skills.read("field-types").not_nil!
        skill.title.should eq("Field Types")
        skill.description.should contain("FieldType")
        skill.tags.should contain("schema")
        skill.tags.should contain("fields")
        skill.body.should_not be_empty
        skill.body.should contain("# Field Types")
      end

      it "new skills carry front-matter and fixture-derived content" do
        lua = Skills.read("lua-document-helpers").not_nil!
        lua.body.should contain("document.list")
        lua.body.should contain("pcall")

        actor = Skills.read("lua-actor").not_nil!
        actor.body.should contain("ctx.actor.scope")

        identity = Skills.read("display-and-identity").not_nil!
        identity.body.should contain("display_name")

        refs = Skills.read("reference-patterns").not_nil!
        refs.body.should contain("owner_id")
      end
    end

    describe ".read" do
      it "returns nil for a missing skill" do
        Skills.read("nonexistent-skill").should be_nil
      end

      it "returns the full body of a skill" do
        skill = Skills.read("iteration-workflow").not_nil!
        skill.body.should contain("create → check → update → re-check")
      end
    end

    describe ".names" do
      it "returns the list of skill names" do
        names = Skills.names
        names.should contain("doctype-anatomy")
        names.size.should be >= 14
      end
    end
  end
end
