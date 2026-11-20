# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/domain_builder/context"
require "../../../src/assistant/domain_builder/skills"
require "../../../src/assistant/domain_builder/system_prompt"

private def builder_context(target_name : String? = nil, description : String? = nil) : Facet::Assistant::DomainBuilder::Context
  Facet::Assistant::DomainBuilder::Context.new(
    draft_domain: "_draft_hr",
    target_name: target_name,
    description: description,
  )
end

describe Facet::Assistant::DomainBuilder::SystemPrompt do
  it "substitutes the session-context placeholders" do
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(
      builder_context(target_name: "hr", description: "HR domain for people records")
    )

    prompt.should contain("- Draft domain: `_draft_hr`")
    prompt.should contain("- Target live name: `hr` (advisory).")
    prompt.should contain("- Intent: HR domain for people records")
    prompt.should_not contain("$DRAFT_DOMAIN")
    prompt.should_not contain("$TARGET_NAME_LINE")
    prompt.should_not contain("$DESCRIPTION_LINE")
  end

  it "drops the optional lines when the context carries no target or description" do
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context)

    prompt.should contain("- Draft domain: `_draft_hr`")
    prompt.should_not contain("Target live name")
    prompt.should_not contain("- Intent:")
  end

  it "keeps Session context the last section of the template" do
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context)

    headings = prompt.lines.select(&.starts_with?("## "))
    headings.last.should eq("## Session context")
  end

  it "appends the custom block after the Session context" do
    custom = "## Custom instructions\n\nAnswer in French."
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, custom)

    prompt.should contain("## Custom instructions")
    prompt.should contain("Answer in French.")

    session_idx = prompt.index("## Session context")
    custom_idx = prompt.index("## Custom instructions")
    session_idx.should be_a(Int32)
    custom_idx.should be_a(Int32)
    custom_idx.not_nil!.should be > session_idx.not_nil!

    # The block rides at the very end.
    prompt.rstrip.should end_with(custom)
  end

  it "returns the no-block prompt when the custom block is nil or empty" do
    base = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context)
    Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, nil).should eq(base)
    Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, "").should eq(base)
  end

  it "appends the language directive after the Session context" do
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, nil, "fr")

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
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, custom, "fr")

    language_idx = prompt.index("## Language")
    custom_idx = prompt.index("## Custom instructions")
    language_idx.should be_a(Int32)
    custom_idx.should be_a(Int32)
    custom_idx.not_nil!.should be > language_idx.not_nil!

    prompt.rstrip.should end_with(custom)
  end

  it "returns the base prompt when no language is given" do
    base = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context)
    Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, nil, nil).should eq(base)
    Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, nil, "").should eq(base)
    Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context, nil, "hello world").should eq(base)
  end

  it "builds a byte-identical prompt for repeated calls with the same inputs" do
    custom = "## Custom instructions\n\nAnswer in French."
    first = Facet::Assistant::DomainBuilder::SystemPrompt.build(
      builder_context(target_name: "hr"), custom
    )
    second = Facet::Assistant::DomainBuilder::SystemPrompt.build(
      builder_context(target_name: "hr"), custom
    )
    first.should eq(second)
  end

  it "lists every skill of the corpus, in loader order (drift guard)" do
    prompt = Facet::Assistant::DomainBuilder::SystemPrompt.build(builder_context)
    names = Facet::Assistant::DomainBuilder::Skills.names

    skills_section = prompt.split("## Skills")[1]?.not_nil!
      .split("## Session context")[0]?.not_nil!
    bullet_names = skills_section.lines
      .select(&.starts_with?("- `"))
      .map { |line| line.split("`")[1] }

    # The bullet list names all skills, counts them, and follows the same
    # alphabetical order the loader serves — a new skill file without a
    # prompt entry fails here.
    bullet_names.should eq(names)
    names.each { |name| prompt.should contain(name) }
  end
end
