# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-101ext guard. The document GET mask drops every content key the doctype
# schema does not declare, so a GET → PUT round-trip of a definition
# deletes any definition key the `core.DocType` seed schema fails to
# declare (run 35, B-101ext: sidecar, sidecars, surface, scopes, and
# identifier were lost this way). Every key in
# `DoctypeDefinition::KNOWN_KEYS` must therefore be a declared field of the
# seed schema, or sit in the allowlist below with a reason. Add a new
# definition key to `data/seeds/core.DocType/definition.yml` first; the
# allowlist is for accepted losses only.

require "spec"
require "yaml"
require "../../src/doctype"

# Definition keys that are deliberately NOT declared on the `core.DocType`
# seed schema. Each entry carries the reason the loss is accepted.
# Empty today: every KNOWN_KEYS member is declared, including `search`.
#
# `search` needs a note. `Doctype::Validation` rejects any field named
# `search` on a user-authored definition ("is a reserved field name and
# cannot be used"). The seed may still declare it: the seed path
# (`Doctype::Seed.seed_definition`) writes through `Mutation::Client`
# directly and never runs authoring validation. The declaration is what
# keeps the `search` template key on a GET — without it the mask drops the
# template and a GET → PUT round-trip deletes it. The cost: a PUT of the
# `core.DocType` definition itself fails validation, because its fields
# now carry the reserved name. That edit path is not a product surface —
# the system definition evolves through the seed, not the API.
private ALLOWLISTED_KEYS = {} of String => String

private def core_doctype_seed_path : String
  File.join(__DIR__, "..", "..", "data", "seeds", "core.DocType", "definition.yml")
end

# The field names the seed schema declares — the keys the GET mask keeps.
private def seed_declared_fields : Set(String)
  seed_declared_at(["fields"])
end

# The property names declared at a nested position of the seed schema,
# addressed as a path from the root (e.g. `["fields", "values", "properties"]`).
# The GET mask recurses the seed schema the same way, so these are exactly
# the keys it keeps at that level. An absent position resolves to an empty
# set — the guard then names every missing key.
private def seed_declared_at(path : Array(String)) : Set(String)
  node = YAML.parse(File.read(core_doctype_seed_path))
  path.each do |segment|
    map = node.as_h?
    return Set(String).new if map.nil?
    found = map[segment]?
    return Set(String).new if found.nil?
    node = found
  end
  props = node.as_h?
  props ? props.keys.map(&.as_s).to_set : Set(String).new
end

# The field names the seed schema declares — the keys the GET mask keeps.
private def seed_declared_fields : Set(String)
  seed_declared_at(["fields"])
end

describe "core.DocType seed declares every definition key (B-101ext)" do
  it "declares or allowlists every KNOWN_KEYS member" do
    declared = seed_declared_fields

    missing = Facet::Doctype::DoctypeDefinition::KNOWN_KEYS.reject do |key|
      declared.includes?(key) || ALLOWLISTED_KEYS.has_key?(key)
    end
    missing.should(
      be_empty,
      "Definition keys with no declaration on the core.DocType seed schema: #{missing.join(", ")}. " \
      "The document GET mask drops keys the schema does not declare, and a GET → PUT round-trip deletes " \
      "them from the stored definition (B-101ext). Declare each key in " \
      "data/seeds/core.DocType/definition.yml, or add it to ALLOWLISTED_KEYS in this spec with a reason."
    )
  end

  it "keeps the allowlist honest" do
    declared = seed_declared_fields
    ALLOWLISTED_KEYS.each do |key, reason|
      reason.strip.should_not be_empty, "Allowlisted key '#{key}' needs a reason string."
      declared.includes?(key).should be_false,
        "Key '#{key}' is both allowlisted and declared on the seed schema — remove it from ALLOWLISTED_KEYS."
    end
  end

  it "parses the seed so the declarations reach the runtime mask" do
    yaml = YAML.parse(File.read(core_doctype_seed_path))
    content = Facet::Doctype::YamlHelper.to_json_any(yaml)
    defn = Facet::Doctype::DoctypeDefinition.from_json(content)
    seed_declared_fields.each do |key|
      defn.fields.has_key?(key).should be_true,
        "Seed field '#{key}' did not survive DoctypeDefinition parsing — the GET mask cannot see it."
    end
  end
end

# Nested levels of the same contract (B-124, B-125). The GET mask recurses
# through the seed schema's nested `properties`/`values` declarations — a
# key an entry parser reads (the nested KNOWN_KEYS below) must be declared
# at the matching position, or the mask drops it for Real principals and a
# GET → PUT round-trip loses it: `mode` on a secret field (B-124) and an
# action's `description` (B-125) were lost this way. The top-level guard
# above cannot see these levels.
#
# Position paths walk the seed schema: the definition's `fields` map
# declares a field *named* `fields` (type dictionary) whose `values`
# object carries one property per field-definition key — so a field entry
# key lives at `fields.fields.values.properties`. The other container
# fields (`actions`, `children`, `sidecars`, `scopes`) follow the same
# shape; `identifier` is a `data` field with direct `properties`.

NESTED_KEY_POSITIONS = [
  {"field entry", ["fields", "fields", "values", "properties"], Facet::Doctype::FieldDefinition::KNOWN_KEYS},
  {"replicate entry", ["fields", "fields", "values", "properties", "replicate", "properties"], Facet::Doctype::ReplicateConfig::KNOWN_KEYS},
  {"enum value entry", ["fields", "fields", "values", "properties", "values", "items", "properties"], Facet::Doctype::EnumValue::KNOWN_KEYS},
  {"action entry", ["fields", "actions", "values", "properties"], Facet::Doctype::ActionDefinition::KNOWN_KEYS},
  {"action argument entry", ["fields", "actions", "values", "properties", "args", "values", "properties"], Facet::Doctype::ActionArgDefinition::KNOWN_KEYS},
  {"children entry", ["fields", "children", "values", "properties"], Facet::Doctype::ChildrenDefinition::KNOWN_KEYS},
  {"sidecar entry", ["fields", "sidecars", "values", "properties"], Facet::Doctype::SidecarRef::KNOWN_KEYS},
  {"named scope entry", ["fields", "scopes", "values", "properties"], Facet::Doctype::NamedScope::KNOWN_KEYS},
  {"identifier entry", ["fields", "identifier", "properties"], %w[template genonly]},
]

describe "core.DocType seed declares every nested definition key (B-124, B-125)" do
  NESTED_KEY_POSITIONS.each do |label, path, keys|
    it "declares every #{label} key" do
      keys.should_not be_empty, "Position '#{path.join(".")}' resolved no keys — fix the table."
      declared = seed_declared_at(path)
      missing = keys.reject { |key| declared.includes?(key) }
      missing.should(
        be_empty,
        "Keys with no declaration at #{path.join(".")}: #{missing.join(", ")}. " \
        "The document GET mask drops them for Real principals, and a GET → PUT round-trip " \
        "deletes them from the stored definition (B-124, B-125). Declare each key at that " \
        "position in data/seeds/core.DocType/definition.yml."
      )
    end
  end
end
