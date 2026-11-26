# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# Generates site-docs/src/content/docs/reference/dvt-schema.md and the
# French twin fr/reference/dvt-schema.md from
# src/doctype/view_template_validator.cr (the DocumentView template
# validator). Run: make gen-docs-dvt-schema
#
# Mechanism: the validator compiles standalone, so the script requires it
# and reads ViewTemplateValidator::REQUIRED — the node type to required
# properties map — as an object. The private validator constants
# (CONTAINER_TYPES, LIST_ITEM_TYPES, INPUT_AFFINITY, URL_PROPS) are not
# readable through require, so the script extracts them from the source
# text with strict anchored patterns. A missing or reshaped constant stops
# the generation.
#
# Sync: the emitted schema's per-node required properties are generated
# from the REQUIRED map at run time, so a validator change flows into the
# schema automatically. The extracted constants are cross-checked against
# the REQUIRED keys, and every $ref the schema carries must be defined.

require "json"
require "../../src/doctype/doctype_definition"
require "../../src/doctype/replicate_config"
require "../../src/doctype/view_template_validator"
require "./fr_overlay"

REPO_ROOT = File.expand_path("../..", __DIR__)
TARGET    = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "reference", "dvt-schema.md")
FR_TARGET = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "fr", "reference", "dvt-schema.md")
SOURCE    = File.join(REPO_ROOT, "src", "doctype", "view_template_validator.cr")

def fail!(message : String) : NoReturn
  abort "gen_docs/dvt_schema: #{message}"
end

def string_array(json : JSON::Builder, values : Array(String)) : Nil
  json.array do
    values.each { |v| json.string(v) }
  end
end

REQUIRED = Facet::Doctype::ViewTemplateValidator::REQUIRED
fail!("validator carries no node types") if REQUIRED.empty?

# ── Extracted private constants (anchored patterns over the source) ──────

def extract_set(source : String, label : String) : Array(String)
  m = source.match(/private #{label} = Set\{([^}]*)\}/)
  fail!("view_template_validator.cr no longer declares `private #{label} = Set{...}`") unless m
  m.[1].scan(/"([a-z_]+)"/).map(&.[1]).sort!
end

CONTAINER_TYPES = extract_set(File.read(SOURCE), "CONTAINER_TYPES")
LIST_ITEM_TYPES = extract_set(File.read(SOURCE), "LIST_ITEM_TYPES")

# One keyed hash literal: `private NAME = {` ... `}` with `"key" => value`
# entries, where value is either Set{...} or a "string".
def extract_hash(source : String, label : String, set_values : Bool) : Array(Tuple(String, Array(String)))
  start = source.index("private #{label} = {")
  fail!("view_template_validator.cr no longer declares `private #{label} = {`") unless start
  tail = source[start..]
  entries = [] of Tuple(String, Array(String))
  tail.each_line do |line|
    break if line =~ /^\s*\}\s*$/ && !entries.empty?
    m = line.match(/"([a-z_-]+)"\s*=>\s*(.+?),?\s*$/)
    next unless m
    value_part = m.[2]
    values = if set_values
               v = value_part.match(/Set\{([^}]*)\}/)
               fail!("`#{label}.#{m.[1]}` does not carry a Set{...} value") unless v
               v.[1].scan(/"([a-z_]+)"/).map(&.[1])
             else
               v = value_part.match(/"([a-z_]+)"/)
               fail!("`#{label}.#{m.[1]}` does not carry a string value") unless v
               [v.[1]]
             end
    entries << {m.[1], values.sort}
  end
  fail!("`private #{label} = {` block parsed to zero entries") if entries.empty?
  entries.sort_by(&.[0])
end

INPUT_AFFINITY = extract_hash(File.read(SOURCE), "INPUT_AFFINITY", true)
URL_PROPS      = extract_hash(File.read(SOURCE), "URL_PROPS", false)

# The optional-property enums, anchored to the validator's own literals.
LAYOUT_VALUES = (File.read(SOURCE).match(/layout == "([a-z]+)" \|\| layout == "([a-z]+)"/).try { |m| [m.[1], m.[2]] } ||
                 fail!("validator no longer declares the array layout values with two string literals")).sort
VIEW_VALUES = (File.read(SOURCE).match(/!%w\[([a-z ]+)\]\.includes\?\(view\)/) ||
               fail!("validator no longer declares the relation view values with a %w[...] literal")).[1].split.sort!

# ── Loud cross-checks ────────────────────────────────────────────────────

affinity_unknown = INPUT_AFFINITY.reject { |node, _| REQUIRED.has_key?(node) }
fail!("INPUT_AFFINITY names unknown node types: #{affinity_unknown.map(&.[0]).inspect}") unless affinity_unknown.empty?
url_unknown = URL_PROPS.reject { |node, _| REQUIRED.has_key?(node) }
fail!("URL_PROPS names unknown node types: #{url_unknown.map(&.[0]).inspect}") unless url_unknown.empty?

node_types = REQUIRED.keys.sort!

# ── Schema emission ──────────────────────────────────────────────────────

# The property kinds the validator's required-prop check accepts as arrays
# versus objects versus strings (check_required_prop's case branches).
ARRAY_PROPS  = ["children", "options", "tabs"]
OBJECT_PROPS = ["source"]

schema = IO::Memory.new
JSON.build(schema, indent: 2) do |json|
  json.object do
    json.field("$schema", "http://json-schema.org/draft-07/schema#")
    json.field("title", "Facet DocumentView template (DVT)")
    json.field("$ref", "#/$defs/node")
    json.field("$defs") do
      json.object do
        json.field("node") do
          json.object do
            json.field("type", "object")
            json.field("required") { string_array(json, ["type"]) }
            json.field("properties") do
              json.object do
                json.field("type") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("field") { json.object { json.field("type", "string") } }
                json.field("children") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/node") } } } }
                json.field("else") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/node") } } } }
                json.field("tabs") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/tab") } } } }
                json.field("label") { json.object { json.field("type", "string") } }
                json.field("value") { json.object { json.field("type", "string") } }
                json.field("layout") { json.object { json.field("type", "string") } }
                json.field("src") { json.object { json.field("type", "string") } }
                json.field("href") { json.object { json.field("type", "string") } }
                json.field("options") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/option") } } } }
                json.field("source") { json.object { json.field("$ref", "#/$defs/relationSource") } }
                json.field("doctype") { json.object { json.field("type", "string") } }
                json.field("view") { json.object { json.field("enum") { string_array(json, VIEW_VALUES) } } }
                json.field("editable") { json.object { json.field("type", "boolean") } }
                json.field("columns") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/relationColumn") } } } }
              end
            end
            json.field("allOf") do
              json.array do
                node_types.each do |type|
                  required = REQUIRED[type]
                  json.object do
                    json.field("if") do
                      json.object do
                        json.field("properties") do
                          json.object do
                            json.field("type") { json.object { json.field("const", type) } }
                          end
                        end
                      end
                    end
                    json.field("then") do
                      json.object do
                        json.field("required") { string_array(json, required) }
                        json.field("properties") do
                          json.object do
                            required.each do |prop|
                              if ARRAY_PROPS.includes?(prop)
                                json.field(prop) { json.object { json.field("type", "array") } }
                              elsif OBJECT_PROPS.includes?(prop)
                                json.field(prop) { json.object { json.field("type", "object") } }
                              else
                                json.field(prop) { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                              end
                            end
                            # Node-specific optional properties the validator checks.
                            case type
                            when "relation"
                              json.field("view") { json.object { json.field("enum") { string_array(json, VIEW_VALUES) } } }
                              json.field("editable") { json.object { json.field("type", "boolean") } }
                              json.field("columns") { json.object { json.field("type", "array") } }
                            when "array"
                              json.field("layout") { json.object { json.field("enum") { string_array(json, LAYOUT_VALUES) } } }
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
        json.field("tab") do
          json.object do
            json.field("type", "object")
            json.field("required") { string_array(json, ["label", "children"]) }
            json.field("properties") do
              json.object do
                json.field("label") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("children") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("$ref", "#/$defs/node") } } } }
              end
            end
          end
        end
        json.field("option") do
          json.object do
            json.field("type", "object")
            json.field("required") { string_array(json, ["value", "label"]) }
            json.field("properties") do
              json.object do
                json.field("value") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("label") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
              end
            end
          end
        end
        json.field("relationSource") do
          json.object do
            json.field("type", "object")
            json.field("required") { string_array(json, ["kind"]) }
            json.field("properties") do
              json.object do
                json.field("kind") { json.object { json.field("enum") { string_array(json, ["children", "filter"].sort) } } }
                json.field("rel") { json.object { json.field("type", "string") } }
                json.field("field") { json.object { json.field("type", "string") } }
              end
            end
          end
        end
        json.field("relationColumn") do
          json.object do
            json.field("type", "object")
            json.field("required") { string_array(json, ["key"]) }
            json.field("properties") do
              json.object do
                json.field("key") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("editable") { json.object { json.field("type", "boolean") } }
              end
            end
          end
        end
      end
    end
  end
end
schema_text = schema.to_s

refs = schema_text.scan(%r{"\$ref": "#/\$defs/([a-zA-Z]+)"}).map(&.[1]).uniq!.sort!
defined = ["node", "tab", "option", "relationSource", "relationColumn"]
unknown_refs = refs - defined
fail!("schema references undefined $defs: #{unknown_refs.inspect}") unless unknown_refs.empty?
unused = defined - refs
fail!("schema defines unused $defs: #{unused.inspect}") unless unused.empty?

# ── Page emission ────────────────────────────────────────────────────────

def esc(s : String) : String
  s.gsub("|", "\\|")
end

def family(type : String, required : Array(String)) : String
  return "container" if required.includes?("children") || type == "tabs"
  return "input" if type == "input" || type.starts_with?("input-")
  "display"
end

def prop_shape(prop : String, array_props : Array(String), object_props : Array(String)) : String
  return "array of nodes" if array_props.includes?(prop) && prop != "options"
  return "array of {value, label}" if prop == "options"
  return "object" if object_props.includes?(prop)
  "string"
end

parts = [] of String
parts << <<-FRONTMATTER
  ---
  title: DVT template schema
  description: The JSON schema of a DocumentView template (DVT).
  audience: [author, developer]
  features: [DOM-22]
  type: reference
  sidebar:
    order: 11
  verified_at: 008dd880
  ---
  FRONTMATTER
parts << "> Generated from `src/doctype/view_template_validator.cr` by `make gen-docs-dvt-schema`. Do not edit this file by hand."
parts << "Use this page to check the keys and node types a view template accepts."
parts << "A DocumentView template (DVT) is a JSON tree stored on the `template` field of a `core.DocumentView` document. The validator under `src/doctype/` walks the tree at authoring time. It reports a missing required property or a wrong shape as an error, and a node that would render but degrade as a warning."

# Node types table, sorted.
parts << "## Node types"
parts << "Every node is an object with a `type` discriminator. A node type the validator does not know draws a warning; the frontend renders nothing for it."
node_rows = node_types.map do |type|
  required = REQUIRED[type]
  props = required.empty? ? "—" : required.sort.map { |p| "`#{p}`" }.join(", ")
  "| `#{type}` | #{family(type, required)} | #{props} |"
end
parts << (["| Node type | Family | Required properties |", "| --- | --- | --- |"] + node_rows).join("\n")

# Template keys table.
parts << "## Template keys"
key_rows = [
  {"type", "string", "every node", "Node discriminator. The frontend dispatches on it."},
  {"field", "string", "object, if, array, dict, image-artifact, markdown, input, input-*", "The bound field. Inputs write it; wrappers scope their children to it."},
  {"children", "array of nodes", "containers", "Child nodes. The validator recurses through it."},
  {"else", "array of nodes", "— (optional on if)", "The branch an if node renders when the condition is false."},
  {"tabs", "array of tab entries", "tabs", "Tab descriptors: objects with a label and children."},
  {"label", "string", "input-* (not input), relation, section", "Visible text of the control, relation, or section."},
  {"value", "string", "label, field, title, capsule", "The literal text or bound value the node renders."},
  {"layout", "string", "grid, row", "Layout instruction. On an array node the optional value is #{LAYOUT_VALUES.join(" or ")}."},
  {"src", "string", "image", "Image URL. Carries $field interpolation."},
  {"href", "string", "link, email", "Link target. Carries $field interpolation."},
  {"options", "array of {value, label}", "input-select", "The closed choice set of the select."},
  {"source", "object", "relation", "Query mode of the relation: kind children with rel, or kind filter with field."},
  {"doctype", "string", "relation", "Qualified target doctype of the relation."},
  {"view", "string", "— (optional on relation)", "Relation rendering: #{VIEW_VALUES.join(", ")}. The frontend falls back to capsule."},
  {"editable", "boolean", "— (optional on relation and columns)", "Inline editing toggle. Only a children source may carry it."},
  {"columns", "array of {key, editable?}", "— (optional on relation)", "Table columns for the relation. Each column needs a non-empty key."},
]
key_row_md = key_rows.map { |r| "| `#{r[0]}` | #{esc(r[1])} | #{esc(r[2])} | #{esc(r[3])} |" }
parts << (["| Key | Type | Required on | Purpose |", "| --- | --- | --- | --- |"] + key_row_md).join("\n")

# Schema.
parts << "## JSON Schema"
parts << "The schema expresses the structural contract the validator enforces: the discriminator, the per-type required properties with their shapes, and the relation, tab, option, and column entries. The schema stays as strict as the validator — nothing more, nothing less."
parts << ["```json", schema_text.rstrip, "```"].join("\n")

# Affinity table, sorted.
parts << "## Input node and field type affinity"
parts << "Each specialized input node accepts one set of field types. A binding outside the set draws a warning: the control shows, but the value may fail validation on save. The auto `input` node renders the preferred control for the bound field type."
affinity_rows = INPUT_AFFINITY.map do |node, types|
  "| `#{node}` | #{types.map { |t| "`#{t}`" }.join(", ")} |"
end
parts << (["| Input node | Accepted field types |", "| --- | --- |"] + affinity_rows).join("\n")

# Rules table.
record RuleRow, rule : String, detail : String
rules = [
  RuleRow.new("Missing type discriminator", "A node without a non-empty type is an error. The message lists the keys the node carries."),
  RuleRow.new("Unknown node type", "A type outside the node table draws a warning; the frontend renders nothing for it."),
  RuleRow.new("Required property shapes", "children, tabs, and options must be arrays. source must be an object. Every other required property must be a non-empty string."),
  RuleRow.new("Dotted input bindings", "An input or input-* node bound to a dotted path is an error. Wrap the top-level field in an object node and bind the bare sub-field name."),
  RuleRow.new("Unknown binding target", "An input bound to a field that does not exist at the current scope is an error."),
  RuleRow.new("Container and computed bindings", "A scalar input cannot bind an array, object, dictionary, or data field, or a field with no type definition. input-list is the one array editor."),
  RuleRow.new("read_only bindings", "An input bound to a read_only field draws a warning: the value can never be saved."),
  RuleRow.new("input-list item types", "input-list warns when its items are not #{LIST_ITEM_TYPES.join(", ")}. A target that is not an array field warns too."),
  RuleRow.new("File tokens in URLs", "A link, email, or image node that interpolates a $token resolving to a file field draws a warning: show files with a field row and pictures with image-artifact."),
  RuleRow.new("Wrapper targets", "object and dict need an object or dictionary target; array needs an array target. A mismatching shape warns. An if node accepts any field type."),
  RuleRow.new("Relation source kinds", "source.kind must be children (with rel) or filter (with field). Anything else is an error."),
  RuleRow.new("Relation editability", "editable: true on a filter-bound relation is an error: the parent does not own those rows."),
  RuleRow.new("Relation columns", "A column must be an object with a non-empty key. editable on a dotted column key warns: the toggle writes the row document's own fields only."),
  RuleRow.new("Select options", "An empty options array warns. An option entry that is not an object, or misses a value or label string, is an error."),
  RuleRow.new("Tab entries", "A tabs entry must be an object with a label and children."),
  RuleRow.new("Container field types", "The validator treats #{CONTAINER_TYPES.join(", ")} as container types for binding checks."),
]
parts << "## Rules the schema cannot express"
rule_row_md = rules.map { |r| "| #{esc(r.rule)} | #{esc(r.detail)} |" }
parts << (["| Rule | What the validator enforces |", "| --- | --- |"] + rule_row_md).join("\n")

parts << "## Related"
parts << "- [View templates](/build/view-templates/) — how to author the tree this schema describes."

# ── French page ──────────────────────────────────────────────────────────

ov = "dvt-schema"
fr_parts = [] of String
fr_parts << <<-FRONTMATTER
  ---
  title: Schéma du modèle DVT
  description: "#{GenDocs::FrOverlay.fetch(ov, "description", "")}"
  audience: [author, developer]
  features: [DOM-22]
  type: reference
  sidebar:
    order: 11
  verified_at: 008dd880
  ---
  FRONTMATTER
fr_parts << GenDocs::FrOverlay.fetch(ov, "generated_note", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "intro", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "definition_intro", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "node_types_heading", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "node_types_intro", "")
fr_parts << (["| #{GenDocs::FrOverlay.fetch(ov, "col_node_type", "Node type")} | #{GenDocs::FrOverlay.fetch(ov, "col_family", "Family")} | #{GenDocs::FrOverlay.fetch(ov, "col_required_props", "Required properties")} |", "| --- | --- | --- |"] + node_rows).join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "template_keys_heading", "")
fr_parts << (["| #{GenDocs::FrOverlay.fetch(ov, "col_key", "Key")} | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_required_on", "Required on")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} |", "| --- | --- | --- | --- |"] + key_row_md).join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "json_schema_heading", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "json_schema_intro", "")
fr_parts << ["```json", schema_text.rstrip, "```"].join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "affinity_heading", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "affinity_intro", "")
fr_parts << (["| #{GenDocs::FrOverlay.fetch(ov, "col_input_node", "Input node")} | #{GenDocs::FrOverlay.fetch(ov, "col_accepted_types", "Accepted field types")} |", "| --- | --- |"] + affinity_rows).join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "rules_heading", "")
fr_parts << (["| #{GenDocs::FrOverlay.fetch(ov, "col_rule", "Rule")} | #{GenDocs::FrOverlay.fetch(ov, "col_enforced", "What the validator enforces")} |", "| --- | --- |"] + rule_row_md).join("\n")
fr_parts << "## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}"
fr_parts << GenDocs::FrOverlay.fetch(ov, "related_view_templates", "")

Dir.mkdir_p(File.dirname(TARGET))
File.write(TARGET, parts.join("\n\n") + "\n")
Dir.mkdir_p(File.dirname(FR_TARGET))
File.write(FR_TARGET, fr_parts.join("\n\n") + "\n")
puts "gen_docs/dvt_schema: wrote reference/dvt-schema.md in en + fr (#{node_types.size} node types, #{INPUT_AFFINITY.size} affinity sets, #{rules.size} rules)"
