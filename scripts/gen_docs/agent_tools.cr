# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
# Generates site-docs/src/content/docs/reference/agent-tools.md from src/agent_tools/.
# Run: make gen-docs-agent-tools
#
# Mechanism: requires the real registry (`src/agent_tools/registry.cr`) and
# reads `Registry.entries` — names, descriptions, input schemas, and the
# `requires` capability tags come from the compiled code. The registry pulls
# in the app's config module, and the `batch` description interpolates
# `Facet::Config.instance.mcp.max_batch_ops` at entry-construction time, so
# building the entries loads `config.dev.yml`; that file expands `!env`
# scalars, so the script first loads the repo's `.env.dev` for values the
# environment does not already carry. Nothing connects to a database at
# require or generation time.
#
# The `read_skill` note after the table is static: `read_skill` is not a
# registry entry (the MCP surface appends it, the workspace assistant mounts
# its own — `src/mcp/skills.cr`, `src/assistant/workspace/registrar.cr`).
#
# Writes the English page and its French twin under
# site-docs/src/content/docs/fr/reference/. The French prose lives in
# scripts/gen_docs/fr_overlay/agent-tools.json (see
# doc/site-docs-fr-style.md). Table cells (tool names, access tags, purposes,
# parameters) stay verbatim English; only the page prose, headings, and
# column headers translate.

require "../../src/agent_tools/registry"
require "./fr_overlay"

REPO_ROOT  = File.expand_path("../..", __DIR__)
PAGE_PATHS = {
  "en" => File.join(REPO_ROOT, "site-docs/src/content/docs/reference/agent-tools.md"),
  "fr" => File.join(REPO_ROOT, "site-docs/src/content/docs/fr/reference/agent-tools.md"),
}

# Abbreviation stems whose final period never ends a sentence.
ABBREVIATIONS = ["e.g", "i.e", "etc", "cf", "vs"]

# Loads KEY=VALUE lines from a dotenv-style file without overriding
# variables the caller already set.
private def load_env_file(path : String) : Nil
  return unless File.exists?(path)
  File.read_lines(path).each do |line|
    line = line.strip
    next if line.empty? || line.starts_with?("#")
    key, value = line.split("=", 2)
    ENV[key] = value unless ENV.has_key?(key)
  end
end

private def esc(text : String) : String
  text.gsub("|", "\\|")
end

# The purpose of a tool is the first sentence of its registry description.
# A sentence ends at a single period followed by whitespace; a period inside
# an ellipsis run or an abbreviation stem never ends one.
private def sentence_end?(text : String, i : Int32) : Bool
  return false unless text[i] == '.'
  return false if i > 0 && text[i - 1] == '.'
  return false if i + 1 < text.size && text[i + 1] == '.'
  return false unless i + 1 < text.size && text[i + 1].whitespace?
  ABBREVIATIONS.each do |stem|
    next unless i >= stem.size && text[i - stem.size...i] == stem
    boundary = i == stem.size || !text[i - stem.size - 1].alphanumeric?
    return false if boundary
  end
  true
end

private def first_sentence(description : String) : String
  text = description.strip
  text.size.times do |i|
    return text[0..i].strip if sentence_end?(text, i)
  end
  text
end

# Renders one parameter as `name (type, required|optional)`.
private def render_parameter(name : String, property : JSON::Any, required : Set(String)) : String
  type = property.as_h?.try(&.["type"]?).try(&.as_s?) || "any"
  state = required.includes?(name) ? "required" : "optional"
  "#{name} (#{type}, #{state})"
end

private def render_parameters(schema : JSON::Any) : String
  properties = schema.as_h?.try(&.["properties"]?).try(&.as_h?)
  return "—" if properties.nil? || properties.empty?
  required = schema.as_h?.try(&.["required"]?).try(&.as_a?) || [] of JSON::Any
  required_names = required.compact_map(&.as_s?).to_set
  properties.keys.sort!.map do |name|
    render_parameter(name, properties[name], required_names)
  end.join("<br>")
end

private def generate : Nil
  load_env_file(File.join(REPO_ROOT, ".env.dev"))

  entries = Facet::AgentTools::Registry.entries
  raise "AgentTools::Registry.entries is empty" if entries.empty?

  names = entries.map(&.name)
  duplicates = names.tally.select { |_, count| count > 1 }.keys
  raise "Duplicate tool names in the registry: #{duplicates.join(", ")}" unless duplicates.empty?

  # An interpolation the compiler did not expand would mean the description
  # carried a literal `#{` — fail loud instead of publishing it.
  entries.each do |entry|
    next unless entry.description.includes?("\#{")
    raise "Uninterpolated description on tool '#{entry.name}'"
  end

  rows = entries.sort_by(&.name).map do |entry|
    purpose = first_sentence(entry.description)
    raise "Tool '#{entry.name}' has an empty purpose" if purpose.empty?
    "| `#{esc(entry.name)}` | #{entry.requires} | #{esc(purpose)} | #{esc(render_parameters(entry.input_schema))} |"
  end

  # Front-matter and body reproduce the committed English page byte for byte:
  # the sidebar block and the pinned verified_at change only on re-verification.
  en_body = <<-MARKDOWN
  ---
  title: Agent tools
  description: Every agent tool with its description and parameters.
  audience: [developer, operator]
  features: [AI-04]
  type: reference
  sidebar:
    order: 13
  verified_at: 008dd880
  ---

  > Generated from `src/agent_tools/` by `make gen-docs-agent-tools`. Do not edit this file by hand.

  Use this page to look up a tool, its access class, and its parameters.

  Facet exposes one catalogue of document tools to every agent surface. The
  MCP resource server lists the whole catalogue under `tools/list`; the
  in-process assistants mount the subset they need. The registry holds
  #{entries.size} tools. Visibility filters the list per role; enforcement
  always runs at call time, exactly as on REST.

  The Access column is the tool's `requires` tag from the registry. A role
  sees a tool when its permission map clears the class:

  - **`read`** — at least one read line.
  - **`write`** — at least one create, update, or delete line.
  - **`action`** — a named action or the `*` wildcard.
  - **`none`** — always visible to a signed-in principal.

  | Tool | Access | Purpose | Parameters |
  |---|---|---|---|
  #{rows.join("\n")}

  One tool is not a registry entry: `read_skill`, the skill loader. The MCP
  surface appends it to `tools/list`, and the workspace assistant mounts its
  own. Both take one required argument, `name` (string). It serves the shared
  skill corpus in `src/agent_tools/skills/`, filtered by the `surfaces`
  front-matter of each skill file.

  ## Related

  - [/apps/agent-tools/](/apps/agent-tools/)
  - [/apps/mcp-agents/](/apps/mcp-agents/)
  MARKDOWN

  ov = "agent-tools"
  catalogue_intro = GenDocs::FrOverlay.fetch(ov, "catalogue_intro", "")
  # The overlay quotes the tool count as prose; fail loud when the registry
  # has moved and the French sentence was not updated with it.
  unless catalogue_intro.includes?("#{entries.size} outils")
    raise "agent-tools.json: catalogue_intro does not quote #{entries.size} tools"
  end

  fr_body = <<-MARKDOWN
  ---
  title: Outils d’agent
  description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}
  audience: [developer, operator]
  features: [AI-04]
  type: reference
  sidebar:
    order: 13
  verified_at: 008dd880
  ---

  #{GenDocs::FrOverlay.fetch(ov, "generated_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "intro", "")}

  #{catalogue_intro}

  #{GenDocs::FrOverlay.fetch(ov, "access_intro", "")}
  #{GenDocs::FrOverlay.fetch(ov, "access_read", "")}
  #{GenDocs::FrOverlay.fetch(ov, "access_write", "")}
  #{GenDocs::FrOverlay.fetch(ov, "access_action", "")}
  #{GenDocs::FrOverlay.fetch(ov, "access_none", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_tool", "Tool")} | #{GenDocs::FrOverlay.fetch(ov, "col_access", "Access")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} | #{GenDocs::FrOverlay.fetch(ov, "col_params", "Parameters")} |
  |---|---|---|---|
  #{rows.join("\n")}

  #{GenDocs::FrOverlay.fetch(ov, "skills_note", "")}

  ## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}

  #{GenDocs::FrOverlay.fetch(ov, "related_agent_tools", "")}
  #{GenDocs::FrOverlay.fetch(ov, "related_mcp_agents", "")}
  MARKDOWN

  {"en" => en_body, "fr" => fr_body}.each do |locale, text|
    path = PAGE_PATHS[locale]
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  puts "wrote agent-tools.md in en + fr (#{entries.size} tools)"
end

generate
