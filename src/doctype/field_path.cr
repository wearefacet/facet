# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./doctype_definition"

module Facet
  module Doctype
    # Shared value-shape path descent.
    #
    # One resolver answers "which field definition governs this content
    # path?" for every consumer that walks a path against a definition:
    # the audit redactor on the read plane, and the field-visibility
    # write guards on the write plane. The walker resolves only. Each
    # consumer holds the auth context and applies its own visibility
    # checks to the returned levels — an invisible level must hide the
    # whole subtree below it on every plane.
    #
    # Descent rules, in the same order the content walkers use:
    #
    # - Declared object `properties` name the child definition. An
    #   unknown property does not resolve (fail closed on the read
    #   plane, skipped on the write plane).
    # - Array `items` governs the element level. Diffs always carry an
    #   array whole, so real diffs never descend past an array; a
    #   historical path that does still resolves to the element
    #   descriptor.
    # - Dictionary `dictionary_value` governs every key level.
    # - The object-valued scalar kinds expose their stored members,
    #   which resolve to the owning field definition — the members
    #   carry no visibility of their own. Money stores
    #   `{"value", "currency"}`; period and dateperiod store
    #   `{"start", "end"}`; a secret stores the marker
    #   `{"mode", "version", "set_at"}`.
    # - An `object` field without declared `properties`, and the
    #   free-form `any` and `data` kinds, keep their whole value on
    #   every read surface; deeper segments resolve to the owning
    #   field.
    # - Anything else (a true scalar) exposes no members: a segment
    #   below it does not resolve.
    module FieldPath
      # Stored member keys of the object-valued scalar kinds.
      VALUE_SHAPE_MEMBERS = {
        "money"      => %w[value currency],
        "period"     => %w[start end],
        "dateperiod" => %w[start end],
        "secret"     => %w[mode version set_at],
      } of String => Array(String)

      # Kinds whose stored value is free-form JSON.
      OPAQUE_VALUE_KINDS = %w[object any data]

      # Resolves a content path level by level. Returns one governing
      # definition per segment, root first. Returns `nil` when the path
      # is empty or any segment does not resolve against the definition
      # (an unknown or historical path). The list is never empty for a
      # non-`nil` return.
      def self.levels(definition : DoctypeDefinition, path : Array(String)) : Array(FieldDefinition)?
        return nil if path.empty?
        field_def = definition.fields[path[0]]?
        return nil if field_def.nil?

        levels = [field_def]
        path[1..].each do |segment|
          field_def = descend(field_def, segment)
          return nil if field_def.nil?
          levels << field_def
        end
        levels
      end

      # ── Private ───────────────────────────────────────────────────────

      # One descent hop.
      private def self.descend(field_def : FieldDefinition, segment : String) : FieldDefinition?
        if props = field_def.properties
          return props[segment]?
        end
        return field_def.items if field_def.items
        return field_def.dictionary_value if field_def.dictionary_value

        type_name = field_def.type.try(&.type_name)
        return field_def if !type_name.nil? && OPAQUE_VALUE_KINDS.includes?(type_name)

        members = VALUE_SHAPE_MEMBERS[type_name]?
        return nil if members.nil?
        members.includes?(segment) ? field_def : nil
      end
    end
  end
end
