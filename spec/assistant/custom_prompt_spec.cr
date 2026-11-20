# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/assistant/custom_prompt"
require "../../src/document"
require "../../src/doctype/seed"

# Valid 32-byte master key for building a Config in the file-fallback specs.
# The secret store fails closed on a missing or short key.
PROMPT_SPEC_MASTER_KEY = "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="

# Pins `assistant.system_prompt` on the settings singleton. No Redis fanout
# runs in the unit suite — invalidate like the subscriber would.
def pin_system_prompt(db, payload : String) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    payload,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

# Swaps the config singleton for one whose file side carries `prompt`, and
# restores the original after. The swap pins `staleness_ttl_s: 0` so the
# process caches keep the suite's disabled staleness bound.
def with_file_prompt(prompt : String?, &)
  original = Facet::Config.instance
  Facet::Config.instance = Facet::Config.new(
    artifact_grant_secret: "test-secret",
    secrets: Facet::Secrets::Config.new(master_key: PROMPT_SPEC_MASTER_KEY),
    cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
    assistant: Facet::Assistant::Config.new(system_prompt: prompt),
  )
  yield
ensure
  Facet::Config.instance = original || Facet::Config.instance
  Facet::SystemSettings.reset_cache!
end

describe Facet::Assistant::CustomPrompt do
  before_each do
    # The per-example truncation wipes the projection row but no process
    # cache; drop it so every example resolves from its own DB state.
    Facet::SystemSettings.reset_cache!
  end

  it "returns nil when nothing is set" do
    with_file_prompt(nil) do
      with_db do |db|
        Facet::Assistant::CustomPrompt.block(db).should be_nil
      end
    end
  end

  it "returns the header and the text when the settings document pins a value" do
    with_db do |db|
      pin_system_prompt(db, %({"assistant": {"system_prompt": "Always answer in French."}}))

      block = Facet::Assistant::CustomPrompt.block(db)
      block.should eq("## Custom instructions\n\nAlways answer in French.")
    end
  end

  it "treats a whitespace-only value as no block" do
    with_db do |db|
      pin_system_prompt(db, %({"assistant": {"system_prompt": " \\n\\t "}}))

      Facet::Assistant::CustomPrompt.block(db).should be_nil
    end
  end

  it "prefers the settings document over the file value" do
    with_db do |db|
      pin_system_prompt(db, %({"assistant": {"system_prompt": "document prompt"}}))
    end

    with_file_prompt("file prompt") do
      with_db do |db|
        block = Facet::Assistant::CustomPrompt.block(db).not_nil!
        block.should contain("document prompt")
        block.should_not contain("file prompt")
      end
    end
  end

  it "falls back to the file value when the document does not pin" do
    with_file_prompt("  file prompt  ") do
      with_db do |db|
        block = Facet::Assistant::CustomPrompt.block(db)
        block.should eq("## Custom instructions\n\nfile prompt")
      end
    end
  end
end
