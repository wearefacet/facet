# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../doctype/doctype_definition"
require "../doctype/structure"
require "../doctype/validation"

module Facet
  module Domain
    # Shared publish version gate.
    #
    # Runs the gate that a draft doctype must pass before it may publish
    # over a live target domain:
    #
    # - The draft whose *structure* differs from the live definition must
    #   carry `schema_version == live + 1`.
    # - The draft (relinked onto the target identity — `domain` rewritten
    #   and same-domain reference targets re-pointed) must pass full live
    #   validation, which also checks every migration gap carries a
    #   migration function.
    #
    # The same relink runs on the persist paths (`Domain::Copy`,
    # `Portable::Import`) through `domained_content`, so what the gate
    # judges is exactly what gets written.
    #
    # `Domain::Publish` maps the returned problems onto a hard `422`
    # ServiceError; `Domain::Check` maps them onto read-only
    # `:publish_gate` diagnostics. The two callers word their messages
    # differently — pass `subject_id` and `context` to control the
    # wording (see the defaults, which reproduce the publish 422 text).
    module PublishGate
      # A single gate failure.
      record Problem,
        kind : Symbol, # `:schema_version` — the version bump is wrong; `:validation` — a definition error
        field : String?,
        message : String

      # Runs the version gate for one draft doctype against its live
      # counterpart. Returns an empty array when the gate passes.
      #
      # The gate always judges the **relinked** draft — the definition that
      # will actually be persisted (`domained_definition`), never the raw
      # draft. Structural equality delegates to `Doctype::Structure.equal?`,
      # which compares only the structural field attributes (type, required,
      # unique, enum keys, min/max, pattern, doctype, owned, collection,
      # replicate, on_source_delete, reference filter, nested sub-schemas)
      # and ignores presentation / authoring metadata (operators, title,
      # description, default, view, compute, compute_when, enum
      # label/color). A draft whose only edits are non-structural publishes
      # over the live domain without a `schema_version` bump — matching
      # what the live `Update` path already accepts. Because the comparison
      # runs after the domain rewrite, a draft derived from a live domain
      # (whose same-domain reference targets point at the draft's own
      # identity) that changed nothing else compares equal to the live
      # definition instead of spuriously demanding a version bump.
      #
      # `subject_id` names the doctype in problem messages (defaults to the
      # target-qualified id); `context` completes the "to publish over …"
      # clause (defaults to "the existing domain").
      def self.check(
        db : DB::Connection,
        live_def : Doctype::DoctypeDefinition,
        draft_def : Doctype::DoctypeDefinition,
        target_domain : String,
        *,
        subject_id : String? = nil,
        context : String? = nil,
      ) : Array(Problem)
        domained = domained_definition(draft_def, target_domain)
        return [] of Problem if Doctype::Structure.equal?(live_def, domained)

        id = subject_id || "#{target_domain}.#{domained.doctype}"
        tail = context || "the existing domain"
        problems = [] of Problem

        if domained.schema_version != live_def.schema_version + 1
          problems << Problem.new(
            kind: :schema_version,
            field: nil,
            message: "Doctype '#{id}' changed structure: schema_version must be " \
                     "#{live_def.schema_version + 1} (draft has #{domained.schema_version}) to publish over #{tail}",
          )
          # If the version itself is wrong, further migration-gap checks are
          # meaningless — the gate would fail on the version first.
          return problems
        end

        # Full live validation + migration-gap check on the relinked
        # definition — the same shape the persist paths write. The template
        # gate (B-296) runs here: publish is the second creation door.
        Doctype::Validation.validate(domained, live_def.schema_version).each do |err|
          problems << Problem.new(kind: :validation, field: err.field, message: err.message)
        end
        problems
      end

      # Returns a copy of the definition with `domain` rewritten to `to`.
      # Used to validate a draft definition against a live domain.
      def self.domained_definition(
        definition : Doctype::DoctypeDefinition,
        to : String,
      ) : Doctype::DoctypeDefinition
        Doctype::DoctypeDefinition.from_json(domained_content(JSON.parse(definition.to_json), to))
      end

      # Returns `content` with its `domain` field set to `to`, and every
      # same-domain reference target relinked to `to`. Raw-JSON form shared
      # by `Copy` and `Import`, which persist definitions from JSON content
      # and must preserve any fields not modelled on the struct.
      #
      # The definition's own `domain` value (read before the overwrite) is
      # the identity being replaced. A reference field whose declared
      # `doctype` starts with `{domain}.` targets a doctype of that same
      # domain — after the identity change those targets must follow it, or
      # every document write through the field fails with
      # `reference_target_not_found` against the dropped (or renamed-away)
      # source domain. The canonical declared form is fully qualified
      # `{domain}.{Doctype}` — bare targets make `ReferenceType#normalize`
      # qualify values into a form that can never validate. Cross-domain
      # targets (e.g. `iam.Account`) are left untouched.
      def self.domained_content(content : JSON::Any, to : String) : JSON::Any
        h = content.as_h? || {} of String => JSON::Any
        h = h.dup

        from = h["domain"]?.try(&.as_s?)
        if from && from != to && (fields = h["fields"]?)
          h["fields"] = relink_field_set(fields, from, to)
        end

        h["domain"] = JSON::Any.new(to)
        JSON::Any.new(h)
      end

      # Rewrites same-domain reference targets inside a definition's
      # `fields` map. Recurses through the three sub-schema-bearing slots
      # (`items`, `properties`, and `values` on a `dictionary` field) so
      # nested reference fields relink too — the same nesting
      # `FieldDefinition.from_json` parses and `Doctype::Structure`
      # compares.
      private def self.relink_field_set(
        fields : JSON::Any,
        from : String,
        to : String,
      ) : JSON::Any
        map = fields.as_h?
        return fields unless map

        relinked = {} of String => JSON::Any
        map.each do |name, field|
          relinked[name] = relink_field(field, from, to)
        end
        JSON::Any.new(relinked)
      end

      # Relinks one field definition. The declared `doctype` on a
      # reference-typed field (or a field with no `type`, which the parser
      # treats as a reference) is rewritten from `{from}.…` to `{to}.…`.
      # Non-reference fields keep any `doctype` they carry verbatim.
      private def self.relink_field(
        field : JSON::Any,
        from : String,
        to : String,
      ) : JSON::Any
        h = field.as_h?
        return field unless h

        h = h.dup
        type = h["type"]?.try(&.as_s?).try(&.downcase)

        if (type.nil? || type == "reference") && (target = h["doctype"]?.try(&.as_s?))
          h["doctype"] = JSON::Any.new(relink_leading_segment(target, from, to))
        end

        h["items"] = relink_field(h["items"], from, to) if h.has_key?("items")
        h["properties"] = relink_field_set(h["properties"], from, to) if h.has_key?("properties")
        h["values"] = relink_field(h["values"], from, to) if type == "dictionary" && h.has_key?("values")

        JSON::Any.new(h)
      end

      # Rewrites `value` when it starts with `{from}.`. Doctype names never
      # contain dots, so the `{domain}.{Doctype}` target form is exact —
      # the same first-segment discipline
      # `Portable::Import.rewrite_leading_segment` applies.
      private def self.relink_leading_segment(
        value : String,
        from : String,
        to : String,
      ) : String
        prefix = "#{from}."
        return to + value[from.size..] if value.starts_with?(prefix)
        value
      end
    end
  end
end
