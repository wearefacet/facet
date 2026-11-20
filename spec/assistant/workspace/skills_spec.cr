# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../support/workspace_test_helpers"

# Surface control: the workspace surface lists and reads exactly its
# corpus subset, the loader parses front-matter, and the `read_skill` tool
# maps an unknown name to the error envelope.
module Facet::Assistant::Workspace
  describe Skills do
    describe ".list" do
      it "lists exactly the workspace surface skills, sorted" do
        names = Skills.list.map(&.name)
        names.should eq(["aggregate-reference", "chat-etiquette", "documents-workflow", "filter-grammar", "longtext", "relations"])
      end

      it "parses front-matter (title, description, tags)" do
        skill = Skills.read("filter-grammar").not_nil!
        skill.title.should eq("Filter Grammar")
        skill.description.should contain("field__op")
        skill.tags.should contain("filters")
        skill.body.should_not be_empty
        skill.body.should contain("# Filter Grammar")
      end
    end

    describe ".read" do
      it "reads documents-workflow with the loop content, without the chat etiquette" do
        skill = Skills.read("documents-workflow").not_nil!
        skill.body.should contain("get_schema")
        skill.body.should contain("list_documents")
        # The chat-only etiquette lives in its own skill.
        skill.body.should_not contain("show_documents")
      end

      it "reads chat-etiquette with the show and navigate tools" do
        skill = Skills.read("chat-etiquette").not_nil!
        skill.body.should contain("show_documents")
        skill.body.should contain("navigate")
      end

      it "reads aggregate-reference with the money bag rule" do
        skill = Skills.read("aggregate-reference").not_nil!
        skill.body.should contain("per-currency")
      end

      it "reads relations with the membership recipe" do
        skill = Skills.read("relations").not_nil!
        skill.body.should contain("parent_id")
        skill.body.should contain("member_of")
      end

      it "returns nil for an unknown skill" do
        Skills.read("nonexistent-skill").should be_nil
      end
    end

    describe ".names" do
      it "returns the six workspace skill names" do
        Skills.names.should eq(["aggregate-reference", "chat-etiquette", "documents-workflow", "filter-grammar", "longtext", "relations"])
      end
    end

    # The read_skill tool maps an unknown name to the error envelope.
    describe "read_skill tool envelope" do
      it "errors on an unknown name through a registered agent" do
        with_db do |db|
          agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)

          cb = agent.registered_workspace_tool_callback("read_skill")
          result = JSON.parse(cb.not_nil!.call({"name" => JSON::Any.new("nope")}))

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("nope")
        end
      end
    end
  end
end
