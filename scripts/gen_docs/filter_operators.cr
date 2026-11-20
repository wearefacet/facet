# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# Generates site-docs/src/content/docs/reference/filter-operators.md from
# src/document/filter_compiler.cr. Run: make gen-docs-filter-operators
#
# Mechanism: this script `require`s the real compiler (filter_compiler.cr and
# the field type registry it routes on — the closure compiles without the
# database) and exercises the live code instead of copying constants:
# - Operator sets come from FilterCompiler.allowed_operators, called on a
#   probe definition with one field of every type from src/doctype/field_types/.
#   All members of one family must return the same set.
# - Value shapes come from FilterCompiler.compile, probed with an object
#   value: the shape validator rejects that value with a 422 message naming
#   the required shape, so the message text IS the shape contract. An
#   operator with no shape constraint (or the money family's value parser)
#   does not raise and reads as "scalar".
# The family map and the meaning texts are curated; both are cross-checked
# against the code-derived data — an operator without a meaning, a meaning
# without an operator, or a probe field outside the family map fails the
# generation.
#
# The French page under fr/reference/ takes its prose from
# scripts/gen_docs/fr_overlay/filter-operators.json; the Meaning and Value
# shape cells stay verbatim English in both locales.
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
  "en" => File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "reference", "filter-operators.md"),
  "fr" => File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "fr", "reference", "filter-operators.md"),
}
# The commit where the page content was last verified; both locales pin it.
VERIFIED_AT    = "008dd880"
REGISTER_REGEX = /register_type "([a-z_]+)"/

record Family, key : String, name : String, blurb : String, types : Array(String)

# The field-type families, in page order. `types` must partition the type
# files on disk (enforced below).
FAMILIES = [
  Family.new(
    key: "comparison",
    name: "Comparison — most field types",
    blurb: "Integer and duration values compare numerically; the other types compare as text.",
    types: ["any", "color", "data", "date", "datetime", "dictionary", "duration", "enum", "file",
            "integer", "longtext", "object", "phone", "secret", "string", "url"],
  ),
  Family.new(
    key: "array",
    name: "Array fields",
    blurb: "Membership on the stored JSON array.",
    types: ["array"],
  ),
  Family.new(
    key: "boolean",
    name: "Boolean fields",
    blurb: "A boolean is a two-state field: equality only.",
    types: ["boolean"],
  ),
  Family.new(
    key: "money",
    name: "Money fields",
    blurb: "The comparison value is an amount string, optionally prefixed with the currency: `USD 12.50`. A bare amount compares across every currency.",
    types: ["money"],
  ),
  Family.new(
    key: "range",
    name: "Range fields (dateperiod, period)",
    blurb: "The stored value is a `{start, end}` interval.",
    types: ["dateperiod", "period"],
  ),
  Family.new(
    key: "reference",
    name: "Reference fields",
    blurb: "A reference is a two-state target: equality only.",
    types: ["reference"],
  ),
]

# System filter targets the compiler serves beside the doctype fields.
TIMESTAMPS = ["created_at", "updated_at", "deleted_at"]

# Curated meanings, keyed "family-key:operator" (plus the special targets).
# Every entry traces to the compiler's clause builders and Util::FilterSet.
MEANINGS = {
  "comparison:eq"          => "Stored value equals the given value (text equality).",
  "comparison:ne"          => "Stored value is not the given value.",
  "comparison:match"       => "Stored value contains the given substring, case-insensitive. `%` and `_` match literally.",
  "comparison:starts_with" => "Stored value starts with the given prefix, case-insensitive.",
  "comparison:gt"          => "Stored value is greater than the given value.",
  "comparison:gte"         => "Stored value is greater than or equal to the given value.",
  "comparison:lt"          => "Stored value is less than the given value.",
  "comparison:lte"         => "Stored value is less than or equal to the given value.",
  "comparison:between"     => "Stored value is inside the inclusive range. The value is a two-element array `[start, end]`.",
  "comparison:in"          => "Stored value equals one of the array entries, at most 100.",
  "array:eq"               => "Stored array contains the given element, or every element of the given array.",
  "array:contains"         => "Same match as `eq`: the stored array contains all given elements.",
  "array:overlaps"         => "Stored array shares at least one element with the given array.",
  "boolean:eq"             => "Value equals the given boolean.",
  "boolean:ne"             => "Value is not the given boolean.",
  "money:eq"               => "Amount equals the given value.",
  "money:gt"               => "Amount is greater than the given value.",
  "money:gte"              => "Amount is greater than or equal to the given value.",
  "money:lt"               => "Amount is less than the given value.",
  "money:lte"              => "Amount is less than or equal to the given value.",
  "money:between"          => "Amount is inside the inclusive range. The value is a two-element array; both bounds must carry the same currency.",
  "money:currency"         => "Stored currency ticker equals the given registered ticker.",
  "range:eq"               => "Stored interval equals the given `[start, end]` interval.",
  "range:contains"         => "Stored interval contains the given point (an ISO-8601 string) or the given `[start, end]` interval.",
  "range:overlaps"         => "Stored interval and the given interval share at least one point.",
  "range:within"           => "Stored interval lies inside the given `[start, end]` interval.",
  "reference:eq"           => "Reference points at the given document. The bare id and the qualified `{domain}.{Doctype}.{id}` form both match.",
  "reference:ne"           => "Reference does not point at the given document (same two forms).",
  "id:eq"                  => "Document id equals the given id.",
  "id:ne"                  => "Document id differs from the given id.",
  "id:match"               => "Document id contains the given substring, case-insensitive.",
  "id:gt"                  => "Document id sorts after the given id. ULIDs sort by creation time, so the order is also chronological.",
  "id:gte"                 => "Document id sorts after the given id or equals it.",
  "id:lt"                  => "Document id sorts before the given id.",
  "id:lte"                 => "Document id sorts before the given id or equals it.",
  "id:between"             => "Document id is inside the inclusive range. The value is a two-element array.",
  "id:in"                  => "Document id equals one of the array entries, at most 100.",
  "timestamps:eq"          => "Column equals the given timestamp. The value normalizes to UTC RFC 3339, so offsets are respected.",
  "timestamps:ne"          => "Column differs from the given timestamp.",
  "timestamps:gt"          => "Column is later than the given timestamp.",
  "timestamps:gte"         => "Column is later than or at the given timestamp.",
  "timestamps:lt"          => "Column is earlier than the given timestamp.",
  "timestamps:lte"         => "Column is earlier than or at the given timestamp.",
  "timestamps:between"     => "Column is inside the inclusive range. The value is a two-element array of timestamps.",
  "search:bare"            => "The document search text contains the given term, case- and accent-insensitive.",
}

# The shape phrase the compiler puts into the malformed_filter_value message,
# mapped to the wording the page uses.
SHAPE_BY_PHRASE = {
  "a JSON array value"                       => "array",
  "an ISO-8601 string or a JSON array value" => "ISO-8601 string or array",
  "a scalar or a JSON array value"           => "scalar or array",
}
PHRASE_REGEX = /requires (a JSON array value|an ISO-8601 string or a JSON array value|a scalar or a JSON array value)/

def fail!(message : String) : NoReturn
  abort "gen_docs/filter_operators: #{message}"
end

# ── Scan the type files on disk ────────────────────────────────────────────
disk_types = [] of String
Dir.children(TYPES_DIR).select(&.ends_with?(".cr")).sort!.each do |file|
  text = File.read(File.join(TYPES_DIR, file))
  found = text.scan(REGISTER_REGEX).map(&.[1])
  if found.size != 1
    fail!("#{file} must carry exactly one register_type call, found #{found.size}")
  end
  disk_types << found.first
end
fail!("no field type files found under src/doctype/field_types/") if disk_types.empty?

# ── Probe definition: one field per type ───────────────────────────────────
definition = Facet::Doctype::DoctypeDefinition.new("probe.Doc", "probe")
disk_types.sort.each do |name|
  definition.fields["f_#{name}"] = Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse(name))
end

# ── Family map cross-check ─────────────────────────────────────────────────
family_of = {} of String => Family
FAMILIES.each do |family|
  family.types.each do |type|
    fail!("type '#{type}' maps to more than one family") if family_of.has_key?(type)
    family_of[type] = family
  end
end
unmapped = disk_types - family_of.keys
unless unmapped.empty?
  fail!("type(s) not mapped to a family: #{unmapped.sort.join(", ")}")
end

# ── Operator sets: run the real routing ────────────────────────────────────
# The probe fields declare no `filters` capability, so the routed set is
# read with the capability gate off: the page documents the operator set
# per type family, not per authored capability.
family_ops = {} of String => Array(String) # family key -> sorted operator list
FAMILIES.each do |family|
  sets = family.types.map do |type|
    allowed = Facet::Document::FilterCompiler.allowed_operators(definition, "f_#{type}", skip_capability_check: true)
    fail!("FilterCompiler serves no operators for type '#{type}'") if allowed.nil? || allowed.empty?
    allowed.to_a.sort
  end
  first = sets.first
  sets.each_with_index do |set, index|
    next if set == first
    fail!("family '#{family.key}' is not uniform: #{family.types[index]} serves #{set.join(", ")} but #{family.types.first} serves #{first.join(", ")}")
  end
  family_ops[family.key] = first
end

id_ops = Facet::Document::FilterCompiler.allowed_operators(definition, "id")
fail!("FilterCompiler serves no operators for 'id'") if id_ops.nil? || id_ops.empty?
timestamp_sets = TIMESTAMPS.map do |column|
  allowed = Facet::Document::FilterCompiler.allowed_operators(definition, column)
  fail!("FilterCompiler serves no operators for '#{column}'") if allowed.nil? || allowed.empty?
  allowed.to_a.sort
end
unless timestamp_sets.all? { |set| set == timestamp_sets.first }
  fail!("the timestamp columns do not share one operator set")
end
search_ops = Facet::Document::FilterCompiler.allowed_operators(definition, "search")
fail!("'search' must serve no operator suffixes") unless search_ops == Set(String).new

# ── Value shapes: probe the real compiler ──────────────────────────────────
def probe_shape(definition, field : String, op : String) : String
  filters = {"#{field}__#{op}" => JSON.parse("{}")} of String => JSON::Any
  begin
    # The probe fields declare no `filters` capability; read the shape
    # contract with the capability gate off.
    Facet::Document::FilterCompiler.compile(definition, filters, skip_capability_check: true)
    "scalar"
  rescue e : Facet::Util::FilterClauses::FilterGrammarError
    unless e.reason == "malformed_filter_value"
      fail!("unexpected grammar error probing #{field}__#{op}: #{e.message}")
    end
    match = e.message.to_s.match(PHRASE_REGEX)
    phrase = match.try(&.[1])
    shape = phrase.try { |text| SHAPE_BY_PHRASE[text]? }
    fail!("unrecognized shape phrase probing #{field}__#{op}: #{e.message}") if shape.nil?
    shape
  rescue Facet::Util::FilterClauses::MoneyFilterError
    "scalar"
  end
end

shapes = {} of String => Hash(String, String) # family key -> op -> shape
FAMILIES.each do |family|
  probe_field = "f_#{family.types.sort.first}"
  shapes[family.key] = family_ops[family.key].to_h do |op|
    {op, probe_shape(definition, probe_field, op)}
  end
end
id_shapes = id_ops.to_a.sort.to_h { |op| {op, probe_shape(definition, "id", op)} }
timestamp_shapes = {} of String => Hash(String, String)
TIMESTAMPS.each do |column|
  timestamp_shapes[column] = timestamp_sets.first.to_h { |op| {op, probe_shape(definition, column, op)} }
end

# ── Meaning cross-check ────────────────────────────────────────────────────────────
used = [] of String

# Records one emitted operator and fails when the curated table has no row for it.
def meaning_for!(used : Array(String), key : String, op : String) : String
  meaning = MEANINGS["#{key}:#{op}"]?
  abort "gen_docs/filter_operators: no curated meaning for #{key}:#{op}" if meaning.nil?
  used << "#{key}:#{op}"
  meaning
end

ov = "filter-operators"

# Table rows are identical in both locales: the operator, value shape, and
# meaning cells stay verbatim English. Only the header line translates.
family_rows = {} of String => String
FAMILIES.each do |family|
  lines = [] of String
  family_ops[family.key].each do |op|
    meaning = meaning_for!(used, family.key, op)
    lines << "| `#{op}` | #{shapes[family.key][op]} | #{meaning} |"
  end
  family_rows[family.key] = lines.join("\n")
end

id_lines = [] of String
id_ops.to_a.sort.each do |op|
  meaning = meaning_for!(used, "id", op)
  id_lines << "| `#{op}` | #{id_shapes[op]} | #{meaning} |"
end

timestamp_lines = [] of String
timestamp_sets.first.each do |op|
  meaning = meaning_for!(used, "timestamps", op)
  timestamp_lines << "| `#{op}` | #{timestamp_shapes[TIMESTAMPS.first][op]} | #{meaning} |"
end

search_row = "| `search` | scalar | #{meaning_for!(used, "search", "bare")} |"

en_page = String.build do |io|
  io << "---\n"
  io << "title: Filter operators\n"
  io << "description: The filter operators each field type accepts on list routes.\n"
  io << "audience: [author, developer]\n"
  io << "features: [DOC-02]\n"
  io << "sidebar:\n"
  io << "  order: 4\n"
  io << "verified_at: #{VERIFIED_AT}\n"
  io << "---\n"
  io << "\n"
  io << "> Generated from `src/document/filter_compiler.cr` by `make gen-docs-filter-operators`. Do not edit this file by hand.\n"
  io << "\n"
  io << "Use this page to build a filter and check which operators a field type accepts.\n"
  io << "\n"
  io << "List routes take filters as query parameters, for example `filters[status__eq]=active`.\n"
  io << "A filter key is a field name with an operator suffix; a bare key is `eq`.\n"
  io << "One table below covers each field-type family.\n"
  io << "\n"
  io << "A bad filter fails with one of two codes:\n"
  io << "\n"
  io << "- `unsupported_filter_operator` — the field does not serve the operator.\n"
  io << "- `malformed_filter_value` — the value has the wrong shape.\n"
  io << "\n"
  io << "Both answer `422`.\n"
  io << "\n"

  FAMILIES.each do |family|
    io << "## #{family.name}\n"
    io << "\n"
    io << "Serves: #{family.types.sort.join(", ")}.\n"
    io << "#{family.blurb}\n"
    io << "\n"
    io << "| Operator | Value shape | Meaning |\n"
    io << "|---|---|---|\n"
    io << family_rows[family.key] << "\n"
    io << "\n"
  end

  io << "## The `id` system column\n"
  io << "\n"
  io << "`id` is the document id column on `projections`; it is not a doctype field.\n"
  io << "\n"
  io << "| Operator | Value shape | Meaning |\n"
  io << "|---|---|---|\n"
  io << id_lines.join("\n") << "\n"
  io << "\n"

  io << "## Timestamp system columns\n"
  io << "\n"
  io << "Serves: #{TIMESTAMPS.join(", ")}.\n"
  io << "`deleted_at` filters the trash listing (`include_deleted: true`); live rows carry `NULL`.\n"
  io << "\n"
  io << "| Operator | Value shape | Meaning |\n"
  io << "|---|---|---|\n"
  io << timestamp_lines.join("\n") << "\n"
  io << "\n"

  io << "## Search\n"
  io << "\n"
  io << "`search` is a keyword of the grammar, not a field.\n"
  io << "Only the bare key is valid; a suffixed form (for example `search__match`) answers `422`.\n"
  io << "\n"
  io << "| Key | Value shape | Meaning |\n"
  io << "|---|---|---|\n"
  io << search_row << "\n"
  io << "\n"
  io << "## Related\n"
  io << "\n"
  io << "- [Named scopes](/build/named-scopes/)\n"
  io << "- [Lists, filters and saved views (table, kanban, calendar)](/workspace/lists-filters-views/)\n"
  io << "- [Use the REST API](/apps/rest-api/)\n"
end

fr_page = String.build do |io|
  io << "---\n"
  io << "title: Opérateurs de filtre\n"
  io << "description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}\n"
  io << "audience: [author, developer]\n"
  io << "features: [DOC-02]\n"
  io << "sidebar:\n"
  io << "  order: 4\n"
  io << "verified_at: #{VERIFIED_AT}\n"
  io << "---\n"
  io << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "generated_note", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "intro", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "params_intro", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "errors_intro", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "err_unsupported", "") << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "err_malformed", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "errors_both", "") << "\n\n"

  FAMILIES.each do |family|
    io << GenDocs::FrOverlay.fetch(ov, "#{family.key}_heading", "## #{family.name}") << "\n\n"
    io << GenDocs::FrOverlay.fetch(ov, "#{family.key}_serves", "") << "\n"
    io << GenDocs::FrOverlay.fetch(ov, "#{family.key}_note", "") << "\n\n"
    io << "| #{GenDocs::FrOverlay.fetch(ov, "col_operator", "Operator")} | #{GenDocs::FrOverlay.fetch(ov, "col_value_shape", "Value shape")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |\n"
    io << "|---|---|---|\n"
    io << family_rows[family.key] << "\n"
    io << "\n"
  end

  io << GenDocs::FrOverlay.fetch(ov, "id_heading", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "id_intro", "") << "\n\n"
  io << "| #{GenDocs::FrOverlay.fetch(ov, "col_operator", "Operator")} | #{GenDocs::FrOverlay.fetch(ov, "col_value_shape", "Value shape")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |\n"
  io << "|---|---|---|\n"
  io << id_lines.join("\n") << "\n"
  io << "\n"

  io << GenDocs::FrOverlay.fetch(ov, "timestamp_heading", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "timestamp_serves", "") << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "timestamp_deleted_note", "") << "\n\n"
  io << "| #{GenDocs::FrOverlay.fetch(ov, "col_operator", "Operator")} | #{GenDocs::FrOverlay.fetch(ov, "col_value_shape", "Value shape")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |\n"
  io << "|---|---|---|\n"
  io << timestamp_lines.join("\n") << "\n"
  io << "\n"

  io << GenDocs::FrOverlay.fetch(ov, "search_heading", "") << "\n\n"
  io << GenDocs::FrOverlay.fetch(ov, "search_intro", "") << "\n\n"
  io << "| #{GenDocs::FrOverlay.fetch(ov, "col_key", "Key")} | #{GenDocs::FrOverlay.fetch(ov, "col_value_shape", "Value shape")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |\n"
  io << "|---|---|---|\n"
  io << search_row << "\n"
  io << "\n"
  io << "## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}\n"
  io << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "related_named_scopes", "") << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "related_lists", "") << "\n"
  io << GenDocs::FrOverlay.fetch(ov, "related_rest", "") << "\n"
end

# Every curated meaning must have been emitted — no dead rows.
stale = MEANINGS.keys - used.uniq
unless stale.empty?
  fail!("curated meanings that no code-derived operator uses: #{stale.sort.join(", ")}")
end

{"en" => en_page, "fr" => fr_page}.each do |locale, text|
  path = PAGE_PATHS[locale]
  Dir.mkdir_p(File.dirname(path))
  File.write(path, text)
end
puts "gen_docs/filter_operators: wrote reference/filter-operators.md + fr twin (#{used.size} operators)"
