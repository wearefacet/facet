# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/app/system_prompt"

PINNED_DAY = Time.utc(2026, 3, 15, 10, 30, 0)

describe Facet::Assistant::App::SystemPrompt do
  it "embeds the static body: identity, etiquette, delete discipline" do
    prompt = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)

    prompt.should contain("Facet app")
    # get_schema-first etiquette
    prompt.should contain("get_schema")
    # RBAC honesty — a denial is final
    prompt.should contain("denial is final")
    # delete discipline
    prompt.should contain("delete_document")
  end

  it "builds a byte-identical prompt for repeated calls (stable KV prefix)" do
    a = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    b = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    a.should eq(b)
  end

  it "keeps the static prefix byte-identical across conversations" do
    # The static body is the same for every app conversation — only the
    # Session context block varies. Pin the compile-time TEMPLATE equality.
    a = Facet::Assistant::App::SystemPrompt.build("One", "editor", today: PINNED_DAY)
    b = Facet::Assistant::App::SystemPrompt.build("Two", "viewer", today: PINNED_DAY)
    a.split(Facet::Assistant::App::SystemPrompt::SESSION_HEADER).first
      .should eq(b.split(Facet::Assistant::App::SystemPrompt::SESSION_HEADER).first)
  end

  it "appends the Session context with the app name, role, and date" do
    prompt = Facet::Assistant::App::SystemPrompt.build("Appas Portal", "editor", today: PINNED_DAY)

    prompt.should contain("## Session context")
    prompt.should contain("- App: Appas Portal.")
    prompt.should contain("- Active role: editor.")
    prompt.should contain("- Today's date: 2026-03-15 (UTC).")

    static_last_line = Facet::Assistant::App::SystemPrompt::TEMPLATE.rstrip.lines.last
    session_idx = prompt.index("## Session context")
    static_idx = prompt.index(static_last_line)
    session_idx.should be_a(Int32)
    static_idx.should be_a(Int32)
    session_idx.not_nil!.should be > static_idx.not_nil!
  end

  it "carries the boundary line in the Session context" do
    prompt = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    prompt.should contain("strictly within this app's permissions")
  end

  it "appends the language directive after the Session context" do
    prompt = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", language: "fr", today: PINNED_DAY)

    prompt.should contain("## Language")
    prompt.should contain("`fr`")

    session_idx = prompt.index("## Session context")
    language_idx = prompt.index("## Language")
    language_idx.not_nil!.should be > session_idx.not_nil!
  end

  it "appends the app instructions block after the language directive" do
    prompt = Facet::Assistant::App::SystemPrompt.build(
      "Appas", "editor", app_instructions: "Always quote the ticket number.", language: "fr", today: PINNED_DAY)

    prompt.should contain("## App instructions")
    prompt.should contain("Always quote the ticket number.")

    language_idx = prompt.index("## Language")
    app_idx = prompt.index("## App instructions")
    app_idx.not_nil!.should be > language_idx.not_nil!
  end

  it "keeps the custom instructions block at the very end" do
    custom = "## Custom instructions\n\nBe terse."
    prompt = Facet::Assistant::App::SystemPrompt.build(
      "Appas", "editor", app_instructions: "App rules.", custom_instructions: custom, today: PINNED_DAY)

    app_idx = prompt.index("## App instructions")
    custom_idx = prompt.index("## Custom instructions")
    custom_idx.not_nil!.should be > app_idx.not_nil!

    prompt.rstrip.should end_with(custom)
  end

  it "appends nothing when the app instructions are absent, empty, or blank" do
    base = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", app_instructions: nil, today: PINNED_DAY).should eq(base)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", app_instructions: "", today: PINNED_DAY).should eq(base)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", app_instructions: "   \n\t ", today: PINNED_DAY).should eq(base)
  end

  it "appends nothing when the custom instructions are absent or empty" do
    base = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", custom_instructions: nil, today: PINNED_DAY).should eq(base)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", custom_instructions: "", today: PINNED_DAY).should eq(base)
  end

  it "returns the base prompt when no language is given" do
    base = Facet::Assistant::App::SystemPrompt.build("Appas", "editor", today: PINNED_DAY)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", language: nil, today: PINNED_DAY).should eq(base)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", language: "", today: PINNED_DAY).should eq(base)
    Facet::Assistant::App::SystemPrompt.build("Appas", "editor", language: "not a tag", today: PINNED_DAY).should eq(base)
  end

  it "builds a byte-identical prompt for repeated calls with the same blocks" do
    a = Facet::Assistant::App::SystemPrompt.build(
      "Appas", "editor", app_instructions: "Rules.", custom_instructions: "## Custom instructions\n\nBe terse.", language: "fr", today: PINNED_DAY)
    b = Facet::Assistant::App::SystemPrompt.build(
      "Appas", "editor", app_instructions: "Rules.", custom_instructions: "## Custom instructions\n\nBe terse.", language: "fr", today: PINNED_DAY)
    a.should eq(b)
  end
end
