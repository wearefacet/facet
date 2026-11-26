# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# Generates site-docs/src/content/docs/reference/field-types.md from
# src/doctype/field_types/ (the field type registry) and
# src/document/filter_compiler.cr (the served filter operators).
# Run: make gen-docs-field-types
#
# Mechanism: this script `require`s the real sources — the type registry
# (field_type.cr plus every file under field_types/) and the filter compiler
# (filter_compiler.cr, which pulls the doctype definition grammar). The whole
# closure compiles without the database, so the page reads live code data:
# the type list, and the operator set per type straight from
# FilterCompiler.allowed_operators.
#
# Columns:
# - Type: code-derived. The script scans field_types/ on disk for
#   `register_type` names, verifies each against the live registry
#   (FieldType.parse), and requires the curated rows below to cover exactly
#   the scanned set — a new or removed type file fails the generation.
#   Add a new type file to the require list, the curated rows, and the
#   family map of scripts/gen_docs/filter_operators.cr in the same change.
# - Validation and Normalization: curated (they describe behaviour, not
#   data the registry exposes). Every wording below traces to the type's
#   validate/normalize implementation.
# - Filter operators: code-derived from FilterCompiler.allowed_operators.
#
# The French page under fr/reference/ takes its prose from
# scripts/gen_docs/fr_overlay/field-types.json; the Validation and
# Normalization cells stay verbatim English in both locales.
require "json"
require "db"
require "./fr_overlay"

require "../../src/doctype/field_type"
require "../../src/doctype/field_definition"
require "../../src/doctype/replicate_config"
require "../../src/doctype/field_types/any_type"
require "../../src/doctype/field_types/array_type"
require "../../src/doctype/field_types/boolean_type"
require "../../src/doctype/field_types/color_type"
require "../../src/doctype/field_types/data_type"
require "../../src/doctype/field_types/date_type"
require "../../src/doctype/field_types/dateperiod_type"
require "../../src/doctype/field_types/datetime_type"
require "../../src/doctype/field_types/dictionary_type"
require "../../src/doctype/field_types/duration_type"
require "../../src/doctype/field_types/enum_type"
require "../../src/doctype/field_types/file_type"
require "../../src/doctype/field_types/integer_type"
require "../../src/doctype/field_types/long_text_type"
require "../../src/doctype/field_types/money_type"
require "../../src/doctype/field_types/object_type"
require "../../src/doctype/field_types/period_type"
require "../../src/doctype/field_types/phone_type"
require "../../src/doctype/field_types/reference_type"
require "../../src/doctype/field_types/secret_type"
require "../../src/doctype/field_types/string_type"
require "../../src/doctype/field_types/url_type"
require "../../src/document/filter_compiler"

REPO_ROOT  = File.expand_path("../..", __DIR__)
TYPES_DIR  = File.join(REPO_ROOT, "src", "doctype", "field_types")
PAGE_PATHS = {
  "en" => File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "reference", "field-types.md"),
  "fr" => File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "fr", "reference", "field-types.md"),
}
# The commit where the page content was last verified; both locales pin it.
VERIFIED_AT    = "008dd880"
REGISTER_REGEX = /register_type "([a-z_]+)"/

# Curated per-type wording. Every entry traces to the type's `validate` and
# `normalize` implementation; the keys must cover exactly the type files on
# disk (enforced below).
VALIDATION = {
  "any"        => "Accepts any JSON value.",
  "array"      => "JSON array. Every non-null item validates against the declared `items` type; the definition must declare `items`.",
  "boolean"    => "JSON boolean (`true` or `false`).",
  "color"      => "String in an accepted color form: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()`/`rgba()`, or `hsl()`/`hsla()`.",
  "data"       => "Client input is always rejected: the field is computed server-side (read-only).",
  "date"       => "String in `YYYY-MM-DD` form that names a real calendar date.",
  "dateperiod" => "Object with `start` and `end`; both bounds are ISO dates (`YYYY-MM-DD`); start may equal end.",
  "datetime"   => "String parseable as ISO 8601 datetime; the input carries an explicit offset (or `Z`).",
  "dictionary" => "Object with string keys. Every non-null value validates against the declared `values` type; the definition must declare `values`.",
  "duration"   => "Non-negative integer (seconds).",
  "enum"       => "String equal to one of the declared `values` keys.",
  "file"       => "String holding a 26-character ULID (Crockford Base32) — an artifact id.",
  "integer"    => "64-bit integer; honors the declared `min` and `max`.",
  "longtext"   => "String; honors the declared `min` and `max` length bounds and `pattern` (same rules as `string`).",
  "money"      => "Object with a decimal-string `value` and a `currency` ticker registered in the currency registry.",
  "object"     => "Object. Validates against the declared `properties` sub-schema: unknown keys are rejected and required sub-fields are enforced. Free-form when the definition declares no `properties`.",
  "period"     => "Object with `start` and `end`; both bounds are ISO datetimes with a time component; start is strictly before end.",
  "phone"      => "Non-empty string (deliberately loose: number formats vary by locale).",
  "reference"  => "Qualified document id `{domain}.{Doctype}.{id}` whose prefix matches the declared target doctype, or the URN form `urn:facet:{domain}:{Doctype}:{id}`. `null` unsets. A collection field validates each element.",
  "secret"     => "A stage handle (`sh_` plus a 26-character ULID), a marker object `{mode, version, set_at}`, or `null`. Plaintext is never accepted in content.",
  "string"     => "String; honors the declared `min` and `max` length bounds and `pattern`.",
  "url"        => "Absolute `http(s)` URL whose host is a DNS-style name or a bracketed IPv6 literal.",
}
NORMALIZATION = {
  "any"        => "None.",
  "array"      => "Applies the `items` type normalization to every non-null item.",
  "boolean"    => "None.",
  "color"      => "Rewrites the value to its canonical `#RRGGBBAA` form; alpha defaults to `FF`. Unparseable values pass through unchanged so validation rejects them.",
  "data"       => "None.",
  "date"       => "None.",
  "dateperiod" => "None.",
  "datetime"   => "Converts the value to UTC RFC 3339 form (`...Z`).",
  "dictionary" => "Applies the `values` type normalization to every non-null value.",
  "duration"   => "None.",
  "enum"       => "None.",
  "file"       => "None.",
  "integer"    => "None.",
  "longtext"   => "Rewrites `\\r\\n` and bare `\\r` to `\\n` before validation.",
  "money"      => "Fills the `currency` member from the field's declared default currency when the payload omits it.",
  "object"     => "Applies each declared `properties` type normalization to the matching sub-values.",
  "period"     => "Converts both bounds to UTC RFC 3339 form.",
  "phone"      => "None.",
  "reference"  => "Converts the URN form to the dotted storage form; qualifies a bare id with the declared target doctype. Collection elements are qualified in turn.",
  "secret"     => "None.",
  "string"     => "None.",
  "url"        => "Completes a scheme-less dotted host (for example `www.acme.tld`) with `https://`.",
}

def fail!(message : String) : NoReturn
  abort "gen_docs/field_types: #{message}"
end

# ── Scan the type files on disk ────────────────────────────────────────────
disk_types = {} of String => String # type name -> file name
Dir.children(TYPES_DIR).select(&.ends_with?(".cr")).sort!.each do |file|
  text = File.read(File.join(TYPES_DIR, file))
  found = text.scan(REGISTER_REGEX).map(&.[1])
  if found.size != 1
    fail!("#{file} must carry exactly one register_type call, found #{found.size}")
  end
  disk_types[found.first] = file
end
fail!("no field type files found under src/doctype/field_types/") if disk_types.empty?

# ── Cross-check against the live registry ──────────────────────────────────
definition = Facet::Doctype::DoctypeDefinition.new("probe.Doc", "probe")
disk_types.keys.each do |name|
  field = Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse(name))
  definition.fields["f_#{name}"] = field
end

# The probe definition above only compiles when every scanned type exists in
# the registry (FieldType.parse raises on an unknown name) — that guards the
# require list at the top of this script.

# ── Cross-check the curated columns ────────────────────────────────────────
missing = disk_types.keys - VALIDATION.keys
extra = VALIDATION.keys - disk_types.keys
unless missing.empty? && extra.empty?
  fail!("curated validation rows do not match the type files: missing #{missing.sort.join(", ")}; unknown #{extra.sort.join(", ")}")
end
missing = disk_types.keys - NORMALIZATION.keys
extra = NORMALIZATION.keys - disk_types.keys
unless missing.empty? && extra.empty?
  fail!("curated normalization rows do not match the type files: missing #{missing.sort.join(", ")}; unknown #{extra.sort.join(", ")}")
end

# ── Operator column: run the real routing ──────────────────────────────────
# The probe fields declare no `filters` capability, so the routed set is
# read with the capability gate off: the page documents the operator set
# per type, not per authored capability.
operators = {} of String => Array(String)
disk_types.keys.sort!.each do |name|
  allowed = Facet::Document::FilterCompiler.allowed_operators(definition, "f_#{name}", skip_capability_check: true)
  if allowed.nil? || allowed.empty?
    fail!("FilterCompiler serves no operators for type '#{name}'")
  end
  operators[name] = allowed.to_a.sort
end

ov = "field-types"

rows = disk_types.keys.sort!.map do |name|
  ops = operators[name].map { |op| "`#{op}`" }.join(", ")
  "| `#{name}` | #{VALIDATION[name]} | #{NORMALIZATION[name]} | #{ops} |"
end

en_page = <<-MARKDOWN
  ---
  title: Field types
  description: Every field type with validation, normalization, and filter operators.
  audience: [author, developer]
  features: [DOM-04, DOC-13]
  type: reference
  sidebar:
    order: 3
  verified_at: #{VERIFIED_AT}
  ---

  > Generated from `src/doctype/field_types/` by `make gen-docs-field-types`. Do not edit this file by hand.

  Use this page to pick a field type and check how it validates, normalizes, and filters.

  A doctype field declares one of the types below.
  The generator reads the type registry and the filter compiler;
  the validation and normalization wording is maintained in the generator.

  - **Normalization** runs before validation on every create and update.
  - **Filter operators** lists the suffixes the list routes serve for the type;
    the [filter operators](/reference/filter-operators/) page gives each one a
    meaning.

  | Type | Validation | Normalization | Filter operators |
  |---|---|---|---|
  #{rows.join("\n")}

  ## Related

  - [Field types (guide)](/build/field-types/)
  - [Designing doctypes](/build/designing-doctypes/)
  - [Filter operators](/reference/filter-operators/)
  MARKDOWN

fr_page = <<-MARKDOWN
  ---
  title: Types de champs
  description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}
  audience: [author, developer]
  features: [DOM-04, DOC-13]
  type: reference
  sidebar:
    order: 3
  verified_at: #{VERIFIED_AT}
  ---

  #{GenDocs::FrOverlay.fetch(ov, "generated_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "body", "")}

  #{GenDocs::FrOverlay.fetch(ov, "bullet_normalization", "")}
  #{GenDocs::FrOverlay.fetch(ov, "bullet_operators", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_validation", "Validation")} | #{GenDocs::FrOverlay.fetch(ov, "col_normalization", "Normalization")} | #{GenDocs::FrOverlay.fetch(ov, "col_operators", "Filter operators")} |
  |---|---|---|---|
  #{rows.join("\n")}

  ## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}

  #{GenDocs::FrOverlay.fetch(ov, "related_guide", "")}
  #{GenDocs::FrOverlay.fetch(ov, "related_designing", "")}
  #{GenDocs::FrOverlay.fetch(ov, "related_operators", "")}
  MARKDOWN

{"en" => en_page, "fr" => fr_page}.each do |locale, text|
  path = PAGE_PATHS[locale]
  # The heredoc drops the final newline; the pages end with one.
  Dir.mkdir_p(File.dirname(path))
  File.write(path, text + "\n")
end
puts "gen_docs/field_types: wrote reference/field-types.md + fr twin (#{disk_types.size} types)"
