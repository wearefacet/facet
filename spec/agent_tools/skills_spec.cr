# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/agent_tools/skills"

# The shared skill corpus (src/agent_tools/skills/) and its surface filter.
#
# The corpus contract is fail-loud: every file carries a non-empty
# `surfaces` front-matter allow-list drawn from the known agent surfaces.
# `mcp` serves the shared tool-grammar skills; `workspace` additionally
# serves the chat-only etiquette skill. The domain-builder corpus lives in
# its own directory and resolves on neither surface.
module Facet::AgentTools
  describe Skills do
    describe "corpus contract" do
      it "tags every file with known, non-empty surfaces" do
        all = SkillFiles.list(Skills::DIR)
        all.should_not be_empty
        all.each do |skill|
          skill.surfaces.empty?.should be_false
          skill.surfaces.each do |surface|
            Skills::SURFACES.should contain(surface)
          end
        end
      end

      it "parses front-matter (title, description, tags, surfaces)" do
        skill = Skills.read_for("mcp", "filter-grammar").not_nil!
        skill.title.should eq("Filter Grammar")
        skill.description.should contain("field__op")
        skill.tags.should contain("filters")
        skill.surfaces.should eq(["workspace", "mcp"])
        skill.body.should contain("# Filter Grammar")
      end

      it "keeps the chat-only UI tools out of the mcp-served skills" do
        # UI tool names are backticked in the corpus. The chat-only
        # etiquette skill owns them; a shared (mcp-served) skill must not
        # instruct an MCP agent to call a tool it does not have.
        SkillFiles.list(Skills::DIR).each do |skill|
          next unless skill.surfaces.includes?("mcp")
          skill.body.should_not contain("`show_documents`")
          skill.body.should_not contain("`navigate`")
        end
      end
    end

    describe ".list_for / .names_for" do
      it "serves the shared tool-grammar skills to mcp" do
        names = Skills.names_for("mcp")
        names.should contain("filter-grammar")
        names.should contain("aggregate-reference")
        names.should contain("relations")
        names.should contain("documents-workflow")
        names.should eq(names.sort)
      end

      it "serves the workspace subset plus the chat-only skill" do
        names = Skills.names_for("workspace")
        names.should contain("chat-etiquette")
        names.should contain("documents-workflow")
        names.should eq(names.sort)
      end

      it "keeps the chat-only skill out of the mcp listing" do
        Skills.names_for("mcp").should_not contain("chat-etiquette")
      end
    end

    describe ".read_for" do
      it "reads the chat-only skill on the workspace surface" do
        skill = Skills.read_for("workspace", "chat-etiquette").not_nil!
        skill.body.should contain("show_documents")
        skill.body.should contain("navigate")
      end

      it "keeps the domain-builder corpus unreachable from both surfaces" do
        Skills.read_for("mcp", "doctype-anatomy").should be_nil
        Skills.read_for("workspace", "doctype-anatomy").should be_nil
      end

      it "returns nil for an unknown skill" do
        Skills.read_for("mcp", "nonexistent-skill").should be_nil
      end
    end
  end
end
