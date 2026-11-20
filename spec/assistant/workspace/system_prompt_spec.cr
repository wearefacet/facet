# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/workspace/system_prompt"
require "../../../src/assistant/workspace/skills"

# Step 4.2 control: `build` embeds the compile-time static body and appends
# the runtime "Session context" suffix. That the `.md` file is really
# embedded is a compile gate — removing the file fails `make check`.
describe Facet::Assistant::Workspace::SystemPrompt do
  it "embeds the static body: identity, etiquette, delete discipline, skills" do
    prompt = Facet::Assistant::Workspace::SystemPrompt.build

    prompt.should contain("workspace assistant")
    # get_schema-first etiquette
    prompt.should contain("get_schema")
    # RBAC honesty — a denial is final
    prompt.should contain("denial is final")
    # delete discipline
    prompt.should contain("delete_document")
    # when to use show_documents / navigate / aggregates
    prompt.should contain("show_documents")
    prompt.should contain("navigate")
    prompt.should contain("aggregate_documents")
    # the skill corpus
    prompt.should contain("filter-grammar")
    prompt.should contain("documents-workflow")
    prompt.should contain("aggregate-reference")
    prompt.should contain("relations")
  end

  it "pins the prompt's skill list against the corpus" do
    prompt = Facet::Assistant::Workspace::SystemPrompt.build
    names = Facet::Assistant::Workspace::Skills.names

    skills_section = prompt.split("## Skills")[1]?.not_nil!
      .split("## Session context")[0]?.not_nil!
    bullet_names = skills_section.lines
      .select(&.starts_with?("- `"))
      .map { |line| line.split("`")[1] }

    # A new skill file without a prompt bullet fails the suite (the prompt
    # orders the corpus pedagogically, so the pin compares as sets).
    bullet_names.sort.should eq(names)
  end

  it "appends the runtime Session context suffix after the static body" do
    prompt = Facet::Assistant::Workspace::SystemPrompt.build
    prompt.should contain("## Session context")
    prompt.should contain("Page context")

    static_last_line = Facet::Assistant::Workspace::SystemPrompt::TEMPLATE.rstrip.lines.last
    prompt.should contain(static_last_line)

    # The suffix comes last: the static body never mentions it (the suffix
    # is appended at runtime, keeping the compiled prefix stable).
    session_idx = prompt.index("## Session context")
    static_idx = prompt.index(static_last_line)
    session_idx.should be_a(Int32)
    static_idx.should be_a(Int32)
    session_idx.not_nil!.should be > static_idx.not_nil!
  end

  it "builds a byte-identical prompt for repeated calls (stable KV prefix)" do
    Facet::Assistant::Workspace::SystemPrompt.build
      .should eq(Facet::Assistant::Workspace::SystemPrompt.build)
  end

  it "appends the custom block after the Session context suffix" do
    custom = "## Custom instructions\n\nBe terse."
    prompt = Facet::Assistant::Workspace::SystemPrompt.build(custom)

    prompt.should contain("## Custom instructions")
    prompt.should contain("Be terse.")

    session_idx = prompt.index("## Session context")
    custom_idx = prompt.index("## Custom instructions")
    session_idx.should be_a(Int32)
    custom_idx.should be_a(Int32)
    custom_idx.not_nil!.should be > session_idx.not_nil!

    # The block rides at the very end.
    prompt.rstrip.should end_with(custom)
  end

  it "returns the no-block prompt when the custom block is nil or empty" do
    base = Facet::Assistant::Workspace::SystemPrompt.build
    Facet::Assistant::Workspace::SystemPrompt.build(nil).should eq(base)
    Facet::Assistant::Workspace::SystemPrompt.build("").should eq(base)
  end

  it "appends the language directive after the Session context" do
    prompt = Facet::Assistant::Workspace::SystemPrompt.build(nil, "fr")

    prompt.should contain("## Language")
    prompt.should contain("`fr`")

    session_idx = prompt.index("## Session context")
    language_idx = prompt.index("## Language")
    session_idx.should be_a(Int32)
    language_idx.should be_a(Int32)
    language_idx.not_nil!.should be > session_idx.not_nil!
  end

  it "keeps the custom block after the language directive, at the very end" do
    custom = "## Custom instructions\n\nBe terse."
    prompt = Facet::Assistant::Workspace::SystemPrompt.build(custom, "fr")

    language_idx = prompt.index("## Language")
    custom_idx = prompt.index("## Custom instructions")
    language_idx.should be_a(Int32)
    custom_idx.should be_a(Int32)
    custom_idx.not_nil!.should be > language_idx.not_nil!

    prompt.rstrip.should end_with(custom)
  end

  it "returns the base prompt when no language is given" do
    base = Facet::Assistant::Workspace::SystemPrompt.build
    Facet::Assistant::Workspace::SystemPrompt.build(nil, nil).should eq(base)
    Facet::Assistant::Workspace::SystemPrompt.build(nil, "").should eq(base)
    Facet::Assistant::Workspace::SystemPrompt.build(nil, "hello world").should eq(base)
  end

  it "builds a byte-identical prompt for repeated calls with the same block" do
    custom = "## Custom instructions\n\nBe terse."
    Facet::Assistant::Workspace::SystemPrompt.build(custom)
      .should eq(Facet::Assistant::Workspace::SystemPrompt.build(custom))
  end
end
