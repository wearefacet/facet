# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./operator"
require "./filter_capability"

module Facet
  module Doctype
    # Stamps the derived per-field `operators` surface onto raw definition
    # content.
    #
    # The authoring paths (`Doctype::Create` / `Doctype::Update`) serialize
    # the parsed `DoctypeDefinition` struct, whose `FieldDefinition#to_json`
    # writes both the authored `filters` capabilities and the derived
    # `operators` member (the runtime URL-suffix vocabulary `Document::List`
    # clause builders and the frontend filter bar consume —
    # `FieldDef.operators`). The raw-persist paths store content verbatim and
    # would silently drop that derived member: every field is then
    # non-filterable in the UI on definitions that never rode the authoring
    # pipeline — seeded doctypes, imported bundles, and published domains.
    #
    # Every raw-persist path stamps through this module before the write, so
    # a raw-persisted definition carries exactly the member the struct writer
    # would have produced. The derivation mirrors
    # `FieldDefinition#operators`: the union of each capability's operator
    # family, de-duplicated, in `Operator` declaration order — plus the same
    # type-specific supplements (`in` on enum fields, `ne` on boolean and
    # reference fields; see the `#operators` comment there), intersected
    # with the type's runtime ceiling (`Doctype.supported_operators`) so the
    # stamp never advertises an operator the backend would reject.
    module DerivedOperators
      # Returns `content` with a derived `operators` array stamped onto every
      # field that declares `filters`. Content without a `fields` object (not
      # a definition — e.g. a domain document) passes through untouched.
      # Unparseable capabilities leave the field alone — the definition
      # validator rejects them on the authoring paths.
      def self.apply(content : JSON::Any) : JSON::Any
        fields = content.as_h?.try(&.["fields"]?.try(&.as_h?))
        return content if fields.nil?

        fields = fields.transform_values do |field|
          obj = field.as_h?
          next field unless obj
          caps = obj["filters"]?.try(&.as_a?)
          next field unless caps

          operators = caps.flat_map do |cap|
            value = cap.as_s?
            parsed = value ? FilterCapability.parse?(value) : nil
            next [] of Operator unless parsed
            parsed.operators
          end
          next field if operators.empty?

          apply_type_supplements(operators, obj["type"]?.try(&.as_s?))

          ceiling = Doctype.supported_operators(obj["type"]?.try(&.as_s?))
          derived = Operator.values.select do |op|
            operators.includes?(op) && ceiling.includes?(op.to_s.underscore)
          end
          next field if derived.empty?
          object = obj.dup
          object["operators"] = JSON::Any.new(derived.map { |op| JSON::Any.new(op.to_s.underscore) })
          JSON::Any.new(object)
        end

        object = content.as_h.dup
        object["fields"] = JSON::Any.new(fields)
        JSON::Any.new(object)
      end

      # Adds the type-specific equality supplements (`in` on enum, `ne` on
      # boolean / reference) when `eq` is present. Mirrors
      # `FieldDefinition#operators`.
      private def self.apply_type_supplements(operators : Array(Operator), type_name : String?) : Nil
        return unless operators.includes?(Operator::Eq)

        if type_name == "enum" && !operators.includes?(Operator::In)
          operators << Operator::In
        end
        if (type_name == "boolean" || type_name == "reference") && !operators.includes?(Operator::Ne)
          operators << Operator::Ne
        end
      end
    end
  end
end
