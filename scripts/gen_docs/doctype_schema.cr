# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# Generates site-docs/src/content/docs/reference/doctype-schema.md and the
# French twin fr/reference/doctype-schema.md from
# src/doctype/ (the definition structs and Doctype::Validation).
# Run: make gen-docs-doctype-schema
#
# Mechanism: the definition structs compile standalone, so the script
# requires them and reads the grammar constants as objects —
# DoctypeDefinition::KNOWN_KEYS, FieldDefinition::KNOWN_KEYS,
# ActionDefinition::KNOWN_KEYS, ActionArgDefinition::KNOWN_KEYS,
# ChildrenDefinition::KNOWN_KEYS, SidecarRef::KNOWN_KEYS,
# NamedScope::KNOWN_KEYS, ReplicateConfig::KNOWN_KEYS, EnumValue::KNOWN_KEYS,
# DoctypeDefinition::IDENTIFIER_KEYS, DoctypeDefinition::RESERVED_ACTIONS,
# Doctype::Validation::RESERVED_FIELD_NAMES, and the FilterCapability
# compatibility sets. The one registry it cannot read at runtime is the
# field-type registry (requiring every field_types/*.cr drags in the DB
# through reference_type.cr), so the type names are extracted from the
# `register_type "..."` macro calls with a strict anchored pattern: every
# file under src/doctype/field_types/ must yield exactly one name.
#
# Sync: the emitted schema is cross-checked against the code constants both
# ways (every key set the schema carries must equal the struct's KNOWN_KEYS,
# the action-key blacklist must equal RESERVED_ACTIONS, the field-key
# blacklist must equal RESERVED_FIELD_NAMES, the type enum must equal the
# extracted register_type names, the capability enum must equal
# FilterCapability.names, and the on_source_delete enum is extracted from
# the validator's %w[keep unset] literal). A drifted constant stops the
# generation.

require "json"
require "../../src/doctype/doctype_definition"
require "../../src/doctype/replicate_config"
require "../../src/doctype/validation"
require "./fr_overlay"

REPO_ROOT = File.expand_path("../..", __DIR__)
TARGET    = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "reference", "doctype-schema.md")
FR_TARGET = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "fr", "reference", "doctype-schema.md")

# Short aliases — the generator sits at the top level, so every struct and
# module reference from src/doctype must be brought into scope.
alias DoctypeDefinition = Facet::Doctype::DoctypeDefinition
alias FieldDefinition = Facet::Doctype::FieldDefinition
alias ActionDefinition = Facet::Doctype::ActionDefinition
alias ActionArgDefinition = Facet::Doctype::ActionArgDefinition
alias ChildrenDefinition = Facet::Doctype::ChildrenDefinition
alias SidecarRef = Facet::Doctype::SidecarRef
alias NamedScope = Facet::Doctype::NamedScope
alias ReplicateConfig = Facet::Doctype::ReplicateConfig
alias EnumValue = Facet::Doctype::EnumValue
alias FilterCapability = Facet::Doctype::FilterCapability
alias Validation = Facet::Doctype::Validation

def fail!(message : String) : NoReturn
  abort "gen_docs/doctype_schema: #{message}"
end

def assert_set!(label : String, actual : Array(String), expected : Array(String)) : Nil
  return if actual.sort == expected.sort
  fail!("#{label} drifted from the code constant:\n  schema: #{actual.sort.inspect}\n  code:   #{expected.sort.inspect}")
end

# ── Code constants (the grammar anchors) ─────────────────────────────────

TOP_KEYS             = DoctypeDefinition::KNOWN_KEYS
FIELD_KEYS           = FieldDefinition::KNOWN_KEYS
ACTION_KEYS          = ActionDefinition::KNOWN_KEYS
ARG_KEYS             = ActionArgDefinition::KNOWN_KEYS
CHILD_KEYS           = ChildrenDefinition::KNOWN_KEYS
SIDECAR_KEYS         = SidecarRef::KNOWN_KEYS
SCOPE_KEYS           = NamedScope::KNOWN_KEYS
REPL_KEYS            = ReplicateConfig::KNOWN_KEYS
ENUM_KEYS            = EnumValue::KNOWN_KEYS
ID_KEYS              = DoctypeDefinition::IDENTIFIER_KEYS
RESERVED_ACTIONS     = DoctypeDefinition::RESERVED_ACTIONS.to_a.map(&.to_s).sort!
RESERVED_FIELD_NAMES = Facet::Doctype::Validation::RESERVED_FIELD_NAMES.map(&.to_s).sort!
CAPABILITIES         = FilterCapability.names.map(&.to_s.underscore).sort!

# Field type names: extraction from the register_type macro calls (see the
# header comment for why the registry itself is not readable here).
FIELD_TYPES = Dir.glob(File.join(REPO_ROOT, "src", "doctype", "field_types", "*.cr")).sort.flat_map do |path|
  source = File.read(path)
  names = source.scan(/register_type\s*\(?\s*"([a-z_]+)"/).map(&.[1])
  fail!("#{File.basename(path)} carries #{names.size} register_type calls, expected exactly 1") if names.size != 1
  names
end.sort!
fail!("field type extraction found no types") if FIELD_TYPES.empty?

# on_source_delete values, anchored to the validator's own literal.
ON_SOURCE_DELETE = (File.read(File.join(REPO_ROOT, "src", "doctype", "validation.cr")).match(/unless %w\[([a-z ]+)\]\.includes\?\(field\.on_source_delete\)/) ||
                    fail!("validator no longer declares the on_source_delete values with a %w[...] literal")).[1].split.sort!

# ── Schema emission ──────────────────────────────────────────────────

# The builder writes the schema in a fixed order; the fragments that come
# from code constants are emitted sorted, so two runs produce identical
# bytes.

def string_array(json : JSON::Builder, values : Array(String)) : Nil
  json.array do
    values.each { |v| json.string(v) }
  end
end

schema = IO::Memory.new
JSON.build(schema, indent: 2) do |json|
  json.object do
    json.field("$schema", "http://json-schema.org/draft-07/schema#")
    json.field("title", "Facet doctype definition")
    json.field("type", "object")
    json.field("additionalProperties", false)
    json.field("required") { string_array(json, ["doctype", "domain"]) }
    json.field("properties") do
      json.object do
        json.field("doctype") { json.object { json.field("type", "string"); json.field("pattern", DoctypeDefinition::DOCTYPE_RE.source) } }
        json.field("domain") { json.object { json.field("type", "string"); json.field("pattern", DoctypeDefinition::DOMAIN_RE.source) } }
        json.field("schema_version") { json.object { json.field("type", "integer"); json.field("minimum", 1) } }
        json.field("aggregate_root") { json.object { json.field("type", "boolean") } }
        json.field("member_of") { json.object { json.field("type", "string"); json.field("pattern", DoctypeDefinition::DOCTYPE_RE.source) } }
        json.field("description") { json.object { json.field("type", "string") } }
        json.field("label") { json.object { json.field("type", "string") } }
        json.field("icon") { json.object { json.field("type", "string") } }
        json.field("color") { json.object { json.field("type", "string") } }
        json.field("plural_label") { json.object { json.field("type", "string") } }
        json.field("sensitive") { json.object { json.field("type", "boolean") } }
        json.field("nav_visible") { json.object { json.field("type", "boolean") } }
        json.field("fields") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/field") } }
          end
        end
        json.field("actions") do
          json.object do
            json.field("type", "object")
            json.field("propertyNames") do
              json.object do
                json.field("not") { json.object { json.field("enum") { string_array(json, RESERVED_ACTIONS) } } }
              end
            end
            json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/action") } }
          end
        end
        json.field("children") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/childrenEntry") } }
          end
        end
        json.field("sidecar") { json.object { json.field("type", "boolean") } }
        json.field("sidecars") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/sidecarRef") } }
          end
        end
        json.field("surface") { json.object { json.field("type", "string") } }
        json.field("search") { json.object { json.field("type", "string") } }
        json.field("display_name") { json.object { json.field("type", "string") } }
        json.field("migrations") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties") { json.object { json.field("type", "string") } }
          end
        end
        json.field("script") { json.object { json.field("type", "string") } }
        json.field("scopes") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/scope") } }
          end
        end
        json.field("identifier") { json.object { json.field("$ref", "#/$defs/identifier") } }
      end
    end
    json.field("$defs") do
      json.object do
        json.field("field") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("properties") do
              json.object do
                json.field("type") { json.object { json.field("enum") { string_array(json, FIELD_TYPES) } } }
                json.field("values") do
                  json.object do
                    json.field("oneOf") do
                      json.array do
                        json.object do
                          json.field("type", "array")
                          json.field("items") do
                            json.object do
                              json.field("oneOf") do
                                json.array do
                                  json.object { json.field("$ref", "#/$defs/enumValue") }
                                  json.object { json.field("type", "string"); json.field("minLength", 1) }
                                end
                              end
                            end
                          end
                        end
                        json.object { json.field("$ref", "#/$defs/field") }
                      end
                    end
                  end
                end
                json.field("items") { json.object { json.field("$ref", "#/$defs/field") } }
                json.field("properties") do
                  json.object do
                    json.field("type", "object")
                    json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/field") } }
                  end
                end
                json.field("doctype") { json.object { json.field("type", "string") } }
                json.field("required") { json.object { json.field("type", "boolean") } }
                json.field("unique") { json.object { json.field("type", "boolean") } }
                json.field("default") { json.object { } }
                json.field("min") { json.object { json.field("type", "integer") } }
                json.field("max") { json.object { json.field("type", "integer") } }
                json.field("collection") { json.object { json.field("type", "boolean") } }
                json.field("compute") { json.object { json.field("type", "string") } }
                json.field("compute_when") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("type", "string") } } } }
                json.field("replicate") { json.object { json.field("$ref", "#/$defs/replicate") } }
                json.field("on_source_delete") { json.object { json.field("enum") { string_array(json, ON_SOURCE_DELETE) } } }
                json.field("accept") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("type", "string") } } } }
                json.field("title") { json.object { json.field("type", "string") } }
                json.field("description") { json.object { json.field("type", "string") } }
                json.field("write_only") { json.object { json.field("type", "boolean") } }
                json.field("read_only") { json.object { json.field("type", "boolean") } }
                json.field("owned") { json.object { json.field("type", "boolean") } }
                json.field("filter") { json.object { json.field("type", "object") } }
                json.field("dangling") { json.object { json.field("type", "boolean") } }
                json.field("tags") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("type", "string") } } } }
                json.field("pattern") { json.object { json.field("type", "string") } }
                json.field("pattern_flags") { json.object { json.field("type", "string") } }
                json.field("mode") { json.object { json.field("type", "string") } }
                json.field("ttl_seconds") { json.object { json.field("type", "integer") } }
                json.field("filters") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("enum") { string_array(json, CAPABILITIES) } } } } }
                json.field("currency") { json.object { json.field("type", "string") } }
                json.field("precision") { json.object { json.field("type", "integer") } }
                json.field("operators") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("type", "string") } } } }
              end
            end
          end
        end
        json.field("enumValue") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, ["key"]) }
            json.field("properties") do
              json.object do
                json.field("key") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("label") { json.object { json.field("type", "string") } }
                json.field("color") { json.object { json.field("type", "string") } }
              end
            end
          end
        end
        json.field("action") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("properties") do
              json.object do
                json.field("args") do
                  json.object do
                    json.field("type", "object")
                    json.field("additionalProperties") { json.object { json.field("$ref", "#/$defs/actionArg") } }
                  end
                end
                json.field("event_name") { json.object { json.field("type", "string"); json.field("pattern", ActionDefinition::EVENT_NAME_RE.source) } }
                json.field("description") { json.object { json.field("type", "string") } }
                json.field("states") do
                  json.object do
                    json.field("type", "object")
                    json.field("minProperties", 1)
                    json.field("additionalProperties") do
                      json.object do
                        json.field("type", "array")
                        json.field("minItems", 1)
                        json.field("items") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                      end
                    end
                  end
                end
              end
            end
          end
        end
        json.field("actionArg") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, ["type"]) }
            json.field("properties") do
              json.object do
                json.field("type") { json.object { json.field("enum") { string_array(json, FIELD_TYPES) } } }
                json.field("required") { json.object { json.field("type", "boolean") } }
                json.field("default") { json.object { } }
                json.field("values") { json.object { json.field("type", "array"); json.field("items") { json.object { json.field("type", "string") } } } }
                json.field("min") { json.object { json.field("type", "integer") } }
                json.field("max") { json.object { json.field("type", "integer") } }
                json.field("doctype") { json.object { json.field("type", "string") } }
                json.field("collection") { json.object { json.field("type", "boolean") } }
              end
            end
          end
        end
        json.field("childrenEntry") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, ["doctype"]) }
            json.field("properties") do
              json.object do
                json.field("doctype") { json.object { json.field("type", "string"); json.field("pattern", DoctypeDefinition::DOCTYPE_RE.source) } }
                json.field("collection") { json.object { json.field("type", "boolean") } }
                json.field("description") { json.object { json.field("type", "string") } }
              end
            end
          end
        end
        json.field("sidecarRef") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, ["doctype"]) }
            json.field("properties") do
              json.object do
                json.field("doctype") { json.object { json.field("type", "string"); json.field("pattern", "\\.") } }
                json.field("column") { json.object { json.field("type", "string") } }
                json.field("order") { json.object { json.field("type", "integer") } }
                json.field("label") { json.object { json.field("type", "string") } }
              end
            end
          end
        end
        json.field("scope") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("properties") do
              json.object do
                json.field("description") { json.object { json.field("type", "string") } }
                json.field("where") do
                  json.object do
                    json.field("type", "object")
                    json.field("additionalProperties") do
                      json.object do
                        json.field("oneOf") do
                          json.array do
                            json.object { json.field("type", "string") }
                            json.object { json.field("type", "number") }
                            json.object { json.field("type", "boolean") }
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
        json.field("replicate") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, REPL_KEYS.sort) }
            json.field("properties") do
              json.object do
                json.field("via") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("field") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
              end
            end
          end
        end
        json.field("identifier") do
          json.object do
            json.field("type", "object")
            json.field("additionalProperties", false)
            json.field("required") { string_array(json, ["template"]) }
            json.field("properties") do
              json.object do
                json.field("template") { json.object { json.field("type", "string"); json.field("minLength", 1) } }
                json.field("genonly") { json.object { json.field("type", "boolean") } }
              end
            end
          end
        end
      end
    end
  end
end

# The scope `where` values accept string, number, or boolean — a JSON Schema
# object cannot repeat the "type" key, so fix that fragment up: rebuild it as
# a oneOf. (The builder above wrote it naively; correct it here once.)
schema_text = schema.to_s

# ── Loud cross-checks against the code constants ───────────────────────

# The schema is authored in this file next to the builders that emit it, so
# the sync check compares the authored emission lists with the code
# constants. A drifted constant stops the generation.
EMITTED_TOP_KEYS     = %w[doctype domain schema_version aggregate_root member_of description label icon color plural_label sensitive nav_visible fields actions children sidecar sidecars surface search display_name migrations script scopes identifier]
EMITTED_FIELD_KEYS   = %w[type values items properties doctype required unique default min max collection compute compute_when replicate on_source_delete accept title description write_only read_only owned filter dangling tags pattern pattern_flags mode ttl_seconds filters currency precision operators]
EMITTED_ACTION_KEYS  = %w[args event_name description states]
EMITTED_ARG_KEYS     = %w[type required default values min max doctype collection]
EMITTED_CHILD_KEYS   = %w[doctype collection description]
EMITTED_SIDECAR_KEYS = %w[doctype column order label]
EMITTED_SCOPE_KEYS   = %w[description where]
EMITTED_ENUM_KEYS    = %w[key label color]
EMITTED_ID_KEYS      = %w[template genonly]

assert_set!("top-level keys", EMITTED_TOP_KEYS, TOP_KEYS)
assert_set!("field keys", EMITTED_FIELD_KEYS, FIELD_KEYS)
assert_set!("action keys", EMITTED_ACTION_KEYS, ACTION_KEYS)
assert_set!("action arg keys", EMITTED_ARG_KEYS, ARG_KEYS)
assert_set!("children keys", EMITTED_CHILD_KEYS, CHILD_KEYS)
assert_set!("sidecar keys", EMITTED_SIDECAR_KEYS, SIDECAR_KEYS)
assert_set!("scope keys", EMITTED_SCOPE_KEYS, SCOPE_KEYS)
assert_set!("enum value keys", EMITTED_ENUM_KEYS, ENUM_KEYS)
assert_set!("identifier keys", EMITTED_ID_KEYS, ID_KEYS)
assert_set!("replicate keys", %w[via field], REPL_KEYS)
assert_set!("reserved actions", RESERVED_ACTIONS, DoctypeDefinition::RESERVED_ACTIONS.to_a.map(&.to_s))
assert_set!("reserved field names", RESERVED_FIELD_NAMES, Facet::Doctype::Validation::RESERVED_FIELD_NAMES.map(&.to_s))
assert_set!("filter capabilities", CAPABILITIES, FilterCapability.names.map(&.to_s.underscore))

# Every emitted schema $defs name must appear in the emitted text, and the
# emitted text must reference only emitted $defs.
refs = schema_text.scan(%r{"\$ref": "#/\$defs/([a-zA-Z]+)"}).map(&.[1]).uniq!.sort!
defined = ["field", "enumValue", "action", "actionArg", "childrenEntry", "sidecarRef", "scope", "replicate", "identifier"]
unknown_refs = refs - defined
fail!("schema references undefined $defs: #{unknown_refs.inspect}") unless unknown_refs.empty?
unused = defined - refs
fail!("schema defines unused $defs: #{unused.inspect}") unless unused.empty?

# ── Page emission ────────────────────────────────────────────────────────

record KeyRow, key : String, type : String, required : String, purpose : String

KEY_ROWS = [
  KeyRow.new("doctype", "string", "yes", "CamelCase type name, e.g. WorkOrder."),
  KeyRow.new("domain", "string", "yes", "Owning domain. Lowercase with dashes; a draft domain may carry the `_` prefix."),
  KeyRow.new("schema_version", "integer", "no", "Breaking-change version, minimum 1. Drives lazy migration on read. Defaults to 1."),
  KeyRow.new("aggregate_root", "boolean", "no", "True for an aggregate root. Defaults to false."),
  KeyRow.new("member_of", "string", "no", "CamelCase parent doctype when this type is an owned child."),
  KeyRow.new("description", "string", "no", "What the doctype represents."),
  KeyRow.new("label", "string", "no", "Display label the interface shows. Falls back to the doctype name."),
  KeyRow.new("icon", "string", "no", "Lucide icon identifier. Falls back to the default diamond mark."),
  KeyRow.new("color", "string", "no", "CSS hex accent color, e.g. #1565C0."),
  KeyRow.new("plural_label", "string", "no", "Human plural label for consent previews and client snippets."),
  KeyRow.new("sensitive", "boolean", "no", "Highlights grants on this doctype in the permissions editor and consent preview."),
  KeyRow.new("nav_visible", "boolean", "no", "Shows an owned child in the sidebar as a top-level entry."),
  KeyRow.new("fields", "object", "no", "Field definitions keyed by field name."),
  KeyRow.new("actions", "object", "no", "Named actions keyed by action name. Each maps to a Lua export function."),
  KeyRow.new("children", "object", "no", "Composition children keyed by relationship name. Stored as separate projection rows."),
  KeyRow.new("sidecar", "boolean", "no", "True for a system-managed attachment doctype in the core domain."),
  KeyRow.new("sidecars", "object", "no", "Sidecar attachments on a host doctype, keyed by route segment."),
  KeyRow.new("surface", "string", "no", "Custom-surface id on a sidecar doctype. The frontend resolves it through its surface registry."),
  KeyRow.new("search", "string", "no", "Jinja2 template rendered into the trigram-search corpus at mutation time."),
  KeyRow.new("display_name", "string", "no", "Jinja2 template rendered into the projection display label at mutation time."),
  KeyRow.new("migrations", "object", "no", "Source schema version mapped to a Lua migration function name."),
  KeyRow.new("script", "string", "no", "Lua script source with the lifecycle hooks, actions, and migrations."),
  KeyRow.new("scopes", "object", "no", "Named predicates over the doctype's own fields. Permissions reference them as $name."),
  KeyRow.new("identifier", "object", "no", "Sequential identifier configuration. When absent, document ids are ULIDs."),
]

record RuleRow, rule : String, detail : String, code : String

RULE_ROWS = [
  RuleRow.new("Reserved action names", "An action cannot use one of the reserved names: #{RESERVED_ACTIONS.join(", ")}.", "doctype_definition.cr, validation.cr"),
  RuleRow.new("Action and child name collision", "An action name cannot equal a child relationship name, in either direction.", "validation.cr (validate_actions)"),
  RuleRow.new("Actions and migrations need a script", "Declared actions or migrations without a script are rejected.", "validation.cr (validate_script)"),
  RuleRow.new("Aggregation pair", "aggregate_root: true contradicts member_of. A doctype is a root or a member, not both.", "validation.cr (validate_aggregation)"),
  RuleRow.new("compute keys only on data", "compute and compute_when are rejected on every field type except data (secret fields get their own message).", "validation.cr (validate_compute_field_type)"),
  RuleRow.new("compute_when triggers", "Each trigger must name a field of the doctype or a child relationship.", "validation.cr (validate_compute_when)"),
  RuleRow.new("Replicated field consistency", "on_source_delete applies only to a field that carries replicate; its value must be #{ON_SOURCE_DELETE.join(" or ")}; a replica cannot be computed, required, or unique; the via field must exist and must be a reference field.", "validation.cr (validate_replicate_schema)"),
  RuleRow.new("Secret placement", "A secret leaf is allowed at top level and inside object properties only, never inside arrays or dictionaries. A secret root must not appear in the search or display_name templates. Secret cannot be an action argument type.", "validation.cr (validate_secret_fields)"),
  RuleRow.new("Template roots", "Every search and display_name root variable must be a declared field or a reserved variable: content always, display_name in search templates only. A display_name template must not reference the display_name column.", "validation.cr (validate_template)"),
  RuleRow.new("Reserved field names", "A field cannot use one of the reserved names: #{RESERVED_FIELD_NAMES.join(", ")}.", "validation.cr (RESERVED_FIELD_NAMES)"),
  RuleRow.new("Field name shape", "A field name is lower_case_with_underscores or camelCase.", "validation.cr (validate_field_names)"),
  RuleRow.new("read_only and write_only", "The two flags are mutually exclusive on one field.", "validation.cr (validate_field_names)"),
  RuleRow.new("Filter capability matrix", "A declared filter capability must be valid for the field type: equality, comparison, text_search, interval, membership, and currency each cover their own type set.", "validation.cr (validate_field_filters), filter_capability.cr"),
  RuleRow.new("Sidecar shape", "A sidecar doctype lives in the core domain and carries a target reference field that is required, read_only, and has no default. surface is only meaningful with sidecar: true and must be a lowercase identifier.", "validation.cr (validate_sidecar, validate_sidecar_surface)"),
  RuleRow.new("Sidecar segments", "A sidecars segment is a lowercase identifier, does not collide with a children key, and names a non-empty column.", "validation.cr (validate_sidecars_keys)"),
  RuleRow.new("Children targets", "A children doctype is a bare CamelCase name in the same domain. A domain prefix is rejected.", "validation.cr (validate_children)"),
  RuleRow.new("Draft versus live domains", "The `_`-prefixed domain form is valid only in draft domains. A live domain cannot start with a digit or carry `_`.", "validation.cr (validate_domain_name, validate_domain_name_draft)"),
  RuleRow.new("Migration gaps", "On update, every version below schema_version needs a migrations entry whose function name is non-empty; version keys are integers below schema_version.", "validation.cr (validate_migrations)"),
  RuleRow.new("identifier template", "identifier.template must compile through the sequence generator: valid variables, at least one # group, group width within limits.", "validation.cr (validate_identifier)"),
  RuleRow.new("Empty text is absent", "An optional text key parses an empty string as absent. No consumer handles \"\" beside nil.", "doctype_definition.cr (optional_string)"),
  RuleRow.new("Closed key sets", "Every object level rejects unknown keys with 422. The sets are the KNOWN_KEYS constants this page is generated from.", "doctype_definition.cr, field_definition.cr, action_definition.cr, children_definition.cr, sidecar_ref.cr, named_scope.cr, replicate_config.cr"),
  RuleRow.new("Derived operators member", "operators on a field is accepted on read and re-derived from filters. It is never stored.", "field_definition.cr"),
]

def esc(s : String) : String
  s.gsub("|", "\\|")
end

def md_table(header : Array(String), rows : Array(String)) : String
  (header + rows).join("\n")
end

key_rows = KEY_ROWS.map { |r| "| `#{r.key}` | #{esc(r.type)} | #{r.required} | #{esc(r.purpose)} |" }
rule_rows = RULE_ROWS.map { |r| "| #{esc(r.rule)} | #{esc(r.detail)} | `#{esc(r.code)}` |" }
parts = [] of String
parts << <<-FRONTMATTER
  ---
  title: Doctype definition schema
  description: "The JSON schema of a doctype definition: fields, actions, scopes, and composition."
  audience: [author, developer]
  features: [DOM-03]
  type: reference
  sidebar:
    order: 10
  verified_at: 008dd880
  ---
  FRONTMATTER
parts << "> Generated from `src/doctype` by `make gen-docs-doctype-schema`. Do not edit this file by hand."
parts << "Use this page to check the keys a doctype definition accepts."
parts << "A doctype definition is the JSON document that registers a document type. The parser under `src/doctype/` accepts exactly the keys below and rejects every other key with 422. Definitions may also be authored in YAML; the loader converts it to the same JSON grammar."
parts << "## Top-level keys"
parts << md_table(["| Key | Type | Required | Purpose |", "| --- | --- | --- | --- |"], key_rows)
parts << "## JSON Schema"
parts << "The schema expresses the key sets, the required keys, the patterns, and the enums the code enforces. The rules the schema cannot express follow below."
parts << ["```json", schema_text.rstrip, "```"].join("\n")
parts << "## Rules the schema cannot express"
parts << md_table(["| Rule | What the validator enforces | Code |", "| --- | --- | --- |"], rule_rows)
parts << "## Related"
parts << [
  "- [Designing doctypes](/build/designing-doctypes/) — how to model a domain with these keys.",
  "- [Evolving a schema](/build/evolving-schema/) — schema versions and migrations.",
  "- [Parent and child composition](/build/parent-child-composition/) — the children and member_of pair.",
].join("\n")

# ── French page ──────────────────────────────────────────────────────────

ov = "doctype-schema"
fr_parts = [] of String
fr_parts << <<-FRONTMATTER
  ---
  title: Schéma de définition de doctype
  description: "#{GenDocs::FrOverlay.fetch(ov, "description", "")}"
  audience: [author, developer]
  features: [DOM-03]
  type: reference
  sidebar:
    order: 10
  verified_at: 008dd880
  ---
  FRONTMATTER
fr_parts << GenDocs::FrOverlay.fetch(ov, "generated_note", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "intro", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "definition_intro", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "top_level_heading", "")
fr_parts << md_table(["| #{GenDocs::FrOverlay.fetch(ov, "col_key", "Key")} | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_required", "Required")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} |", "| --- | --- | --- | --- |"], key_rows)
fr_parts << GenDocs::FrOverlay.fetch(ov, "json_schema_heading", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "json_schema_intro", "")
fr_parts << ["```json", schema_text.rstrip, "```"].join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "rules_heading", "")
fr_parts << md_table(["| #{GenDocs::FrOverlay.fetch(ov, "col_rule", "Rule")} | #{GenDocs::FrOverlay.fetch(ov, "col_what", "What the validator enforces")} | #{GenDocs::FrOverlay.fetch(ov, "col_sources", "Code")} |", "| --- | --- | --- |"], rule_rows)
fr_parts << "## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}"
fr_parts << [
  GenDocs::FrOverlay.fetch(ov, "related_designing", ""),
  GenDocs::FrOverlay.fetch(ov, "related_evolving", ""),
  GenDocs::FrOverlay.fetch(ov, "related_parent_child", ""),
].join("\n")

Dir.mkdir_p(File.dirname(TARGET))
File.write(TARGET, parts.join("\n\n") + "\n")
Dir.mkdir_p(File.dirname(FR_TARGET))
File.write(FR_TARGET, fr_parts.join("\n\n") + "\n")
puts "gen_docs/doctype_schema: wrote reference/doctype-schema.md in en + fr (#{TOP_KEYS.size} keys, #{FIELD_TYPES.size} field types, #{RULE_ROWS.size} rules)"
