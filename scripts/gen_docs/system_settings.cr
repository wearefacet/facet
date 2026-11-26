# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
# Generates site-docs/src/content/docs/reference/system-settings-keys.md from
# the SystemSettings registry (src/system_settings/spec.cr) and the settings
# doctype seed (data/seeds/core.SystemSettings/definition.yml).
# Run: make gen-docs-system-settings
#
# Mechanism: requires the real registry (`src/system_settings/spec.cr`, after
# `src/config.cr`, whose types the entry procs reference) and reads
# `SystemSettings::SPEC` — key paths, kinds, and secret flags come from the
# compiled code. Defaults are computed, not stored: the script builds the
# built-in config from a minimal in-memory YAML (the required keys only) and
# runs each entry's file fallback — the code's own third tier. Purpose text
# comes from the seed definition's per-field descriptions (first sentence);
# `artifact.storage.type` has deliberately no field in the definition, so the
# script carries one override line for it. The script fails loud when the
# SPEC paths, the definition leaves, and the overrides do not match exactly.
# Nothing connects to a database at require or generation time.
#
# Writes the English page and its French twin under
# site-docs/src/content/docs/fr/reference/. The French prose lives in
# scripts/gen_docs/fr_overlay/system-settings-keys.json (see
# doc/site-docs-fr-style.md). Table cells (key paths, types, defaults,
# purposes) stay verbatim English; only the page prose, headings, and column
# headers translate.

require "yaml"
require "../../src/config"
require "../../src/system_settings/spec"
require "./fr_overlay"

REPO_ROOT  = File.expand_path("../..", __DIR__)
PAGE_PATHS = {
  "en" => File.join(REPO_ROOT, "site-docs/src/content/docs/reference/system-settings-keys.md"),
  "fr" => File.join(REPO_ROOT, "site-docs/src/content/docs/fr/reference/system-settings-keys.md"),
}
DEFINITION = File.join(REPO_ROOT, "data/seeds/core.SystemSettings/definition.yml")

# The minimal file the script needs to build the built-in config. These are
# exactly the keys `Facet::Config` fails loud on when missing; everything
# else keeps its built-in default.
MINIMAL_YAML = <<-YAML
host: localhost:3000
artifact_base_url: "http://localhost:3001"
artifact_grant_secret: "docs-generator-only"
event:
  url: "redis://localhost:6379/0"
secrets:
  master_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVm"
artifact:
  storage:
    type: filesystem
    directory: tmp/uploads/docs-generator
YAML

# Purpose lines for registered paths the seed definition does not describe.
PURPOSE_OVERRIDES = {
  # spec.cr: registered for read visibility only — the storage adapter wires
  # once per process from the config file, and the write gate refuses a pin.
  "artifact.storage.type" => "Shows the effective storage adapter; the adapter wires at boot from the config file and the write gate refuses a pin.",
}

private def esc(text : String) : String
  text.gsub("|", "\\|")
end

# The purpose of a key is the first sentence of its field description.
# A sentence ends at a single period followed by whitespace; a period inside
# an ellipsis run or an abbreviation stem never ends one.
ABBREVIATIONS = ["e.g", "i.e", "etc", "cf", "vs"]

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

# Walks the seed definition and collects one description per leaf field.
# A field with a `properties` mapping is a container; every other field is a
# leaf whose dot path matches a registered setting path.
private def collect_leaves(fields : YAML::Any, prefix : String, leaves : Hash(String, String)) : Nil
  raise "definition.yml: field list under '#{prefix}' is not a mapping" unless mapping = fields.as_h?
  mapping.each do |name_node, field|
    name = name_node.as_s?
    raise "definition.yml: non-string field name under '#{prefix}'" unless name
    path = prefix.empty? ? name : "#{prefix}.#{name}"
    raise "definition.yml: field '#{path}' is not a mapping" unless field.as_h?
    if properties = field["properties"]?
      collect_leaves(properties, path, leaves)
    else
      description = field["description"]?.try(&.as_s?)
      if description.nil? || description.strip.empty?
        raise "definition.yml: leaf field '#{path}' has no description"
      end
      leaves[path] = first_sentence(description)
    end
  end
end

private def generate : Nil
  config = Facet::Config.from_yaml_node(YAML.parse(MINIMAL_YAML))

  definition = YAML.parse(File.read(DEFINITION))
  leaves = {} of String => String
  raise "definition.yml: no top-level 'fields' mapping" unless top_fields = definition["fields"]?
  collect_leaves(top_fields, "", leaves)

  spec_paths = Facet::SystemSettings::SPEC.keys
  described = leaves.keys + PURPOSE_OVERRIDES.keys
  missing = (spec_paths - described).sort
  extra = (described - spec_paths).sort
  raise "Registered paths with no purpose: #{missing.join(", ")}" unless missing.empty?
  raise "Purposes for unregistered paths: #{extra.join(", ")}" unless extra.empty?

  rows = spec_paths.sort.map do |path|
    entry = Facet::SystemSettings::SPEC[path]
    default = entry.fallback.call(config)
    default_cell = default ? default.to_json : "—"
    purpose = PURPOSE_OVERRIDES[path]? || leaves[path]
    "| `#{esc(path)}` | #{entry.kind.to_s.downcase} | #{esc(default_cell)} | #{esc(purpose)} |"
  end

  # Front-matter and body reproduce the committed English page byte for byte:
  # the sidebar block and the pinned verified_at change only on re-verification.
  en_body = <<-MARKDOWN
  ---
  title: System settings keys
  description: Every system settings key with its type and default.
  audience: [operator, admin]
  features: [PLT-02]
  type: reference
  sidebar:
    order: 14
  verified_at: 008dd880
  ---

  > Generated from `src/system_settings/spec.cr` and `data/seeds/core.SystemSettings/definition.yml` by `make gen-docs-system-settings`. Do not edit this file by hand.

  Use this page to find a system settings key, its type, and its default.

  System settings are the runtime platform configuration. One document,
  `core.SystemSettings` (id `settings`), holds every key.

  - **A non-null field pins the value.**
  - **An explicit null returns the key to the config file.**

  The registry lists every key, its type, and the built-in default the file tier
  supplies.

    The defaults are computed, not stored. The generator builds the built-in
    config from a minimal in-memory YAML and runs each entry's file fallback —
    the code's own third tier. At runtime a pinned document value overrides
    the default.

    Secret keys never appear in a read API response. An operator sets them
    through the stage-and-adopt flow; the value lives in the secret store, and
    clearing it returns the key to the config file.

  | Key | Type | Default | Purpose |
  |---|---|---|---|
  #{rows.join("\n")}

  ## Related

  - [/operate/system-settings/](/operate/system-settings/)
  MARKDOWN

  ov = "system-settings-keys"
  fr_body = <<-MARKDOWN
  ---
  title: Clés de réglage système
  description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}
  audience: [operator, admin]
  features: [PLT-02]
  type: reference
  sidebar:
    order: 14
  verified_at: 008dd880
  ---

  #{GenDocs::FrOverlay.fetch(ov, "generated_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "doc_intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "rule_pin", "")}
  #{GenDocs::FrOverlay.fetch(ov, "rule_null", "")}

  #{GenDocs::FrOverlay.fetch(ov, "registry_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "computed_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "secrets_note", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_key", "Key")} | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_default", "Default")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} |
  |---|---|---|---|
  #{rows.join("\n")}

  ## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}

  #{GenDocs::FrOverlay.fetch(ov, "related_system_settings", "")}
  MARKDOWN

  {"en" => en_body, "fr" => fr_body}.each do |locale, text|
    path = PAGE_PATHS[locale]
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  puts "wrote system-settings-keys.md in en + fr (#{spec_paths.size} keys)"
end

generate
