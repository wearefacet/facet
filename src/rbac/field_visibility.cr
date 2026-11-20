# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./auth_context"
require "./principal"
require "./active_role"
require "../doctype/doctype_definition"
require "../doctype/field_path"
require "../mutation/json_diff"

module Facet
  module RBAC
    # Shared recursive field visibility.
    #
    # One schema walker answers every field-tag question against a
    # `DoctypeDefinition`:
    #
    # - **reads** — `mask_content` omits invisible fields from content for
    #   Real principals, recursing into object `properties`, array `items`,
    #   and dictionary `dictionary_value`. If a parent is invisible, the
    #   whole subtree is invisible. Unknown content keys are omitted for
    #   Real principals (fail closed against historical or junk fields);
    #   System and Preview keep their bypasses and see everything raw.
    # - **writes** — `write_violations` walks the caller-submitted body
    #   (a full document on create, a patch on update) and names every
    #   content path the caller writes into an invisible field. An explicit
    #   `null` is a write.
    # - **transitions** — `changed_violations` compares two content states
    #   and names every changed content path that lands in an invisible
    #   field — the action final-diff guard and the rollback guard. Path
    #   resolution is shape-aware (`Doctype::FieldPath`), so a change that
    #   lands as a member sub-path (a money `value`, a dictionary key, a
    #   secret marker member) is judged by the field or descriptor that
    #   owns it, at every level of the descent.
    #
    # Visibility semantics (identical on every surface): System and Preview
    # see every field; a Real caller with the wildcard tag sees every
    # field; otherwise a field is visible when all of its tags
    # (`field_def.tags || ["default"]`) sit in the active role's
    # `visible_tags`.
    module FieldVisibility
      # Applies the read mask to a whole document content. Idempotent:
      # masking already-masked content returns the same shape.
      def self.mask_content(
        content : JSON::Any,
        auth_context : AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        content_h = content.as_h?
        return content if content_h.nil?

        masked = {} of String => JSON::Any
        content_h.each do |key, value|
          field_def = definition.fields[key]?
          if field_def.nil?
            # Unknown content key: System and Preview keep it raw; Real
            # principals get it omitted (fail closed).
            masked[key] = value unless real?(auth_context)
            next
          end
          masked_value = mask_field(value, field_def, auth_context)
          masked[key] = masked_value unless masked_value.nil?
        end
        JSON::Any.new(masked)
      end

      # Content paths the caller-submitted body writes into invisible
      # fields. `submitted` is a full document (create) or a patch
      # (update) — every key present is a write, an explicit `null`
      # included. Unknown keys are skipped here (doctype validation
      # rejects them with its own error).
      def self.write_violations(
        auth_context : AuthContext,
        definition : Doctype::DoctypeDefinition,
        submitted : JSON::Any,
      ) : Array(Array(String))
        violations = [] of Array(String)
        return violations if bypass?(auth_context)

        submitted_h = submitted.as_h?
        return violations if submitted_h.nil?

        submitted_h.each do |key, value|
          walk_submitted(value, definition.fields[key]?, [key], auth_context, violations)
        end
        violations.uniq!
        violations
      end

      # Content paths a transition (before → after) changes inside
      # invisible fields. Used by the action final-diff guard and the
      # rollback current-versus-replayed guard. A path that does not
      # resolve against the definition is not this guard's concern —
      # doctype validation rejects unknown writes, and a transition
      # guard must not block a rollback on historical junk.
      def self.changed_violations(
        auth_context : AuthContext,
        definition : Doctype::DoctypeDefinition,
        before : JSON::Any,
        after : JSON::Any,
      ) : Array(Array(String))
        violations = [] of Array(String)
        return violations if bypass?(auth_context)

        diff = Mutation::JsonDiff.diff(before, after)
        diff.set.each do |entry|
          levels = Doctype::FieldPath.levels(definition, entry.path)
          next if levels.nil?

          if levels.any? { |level| !field_visible?(auth_context, level) }
            # The change lands under an invisible field or descriptor —
            # refuse at the changed path itself.
            violations << entry.path
          elsif value = entry.value
            # A visible path: inspect the added value for invisible
            # nested content (a visible parent set with invisible
            # children). A `nil` value is the line-patch form — one
            # long string, decided at the levels above.
            walk_submitted(value, levels.last, entry.path, auth_context, violations)
          end
        end
        diff.unset.each do |path|
          levels = Doctype::FieldPath.levels(definition, path)
          next if levels.nil?
          violations << path if levels.any? { |level| !field_visible?(auth_context, level) }
        end
        violations.uniq!
        violations
      end

      # One field's visibility under the given auth context — the shared
      # predicate for the read mask, the aggregate field gate, and the
      # write guards. System, Preview, and the wildcard tag see everything;
      # otherwise all of the field's tags must sit in the caller's
      # visible_tags (untagged fields resolve to `["default"]`).
      def self.field_visible?(
        auth_context : AuthContext,
        field_def : Doctype::FieldDefinition,
      ) : Bool
        return true if auth_context.system?
        return true if auth_context.preview?

        p = auth_context.principal.as(Principal::Real)
        return true if p.active_role.wildcard_tags?

        field_visible?(field_def, p.active_role.visible_tags)
      end

      # Tag-subset form shared with the aggregate gate.
      def self.field_visible?(
        field_def : Doctype::FieldDefinition,
        active_tags : Set(String),
      ) : Bool
        field_tags = field_def.tags || ["default"]
        field_tags.all? { |t| active_tags.includes?(t) }
      end

      # ── Private ────────────────────────────────────────────────────────

      # Masks one field's value against its definition. Returns `nil` when
      # the field is invisible (omit from the output), otherwise the value
      # with invisible nested content removed.
      private def self.mask_field(
        value : JSON::Any,
        field_def : Doctype::FieldDefinition,
        auth_context : AuthContext,
      ) : JSON::Any?
        return nil unless field_visible?(auth_context, field_def)
        mask_nested(value, field_def, auth_context)
      end

      # Recurses into a visible field's structural children: object
      # `properties`, array `items`, dictionary `dictionary_value`.
      # Structural shapes without a sub-schema (objects without
      # properties, arrays without items) keep their value verbatim.
      private def self.mask_nested(
        value : JSON::Any,
        field_def : Doctype::FieldDefinition,
        auth_context : AuthContext,
      ) : JSON::Any
        if props = field_def.properties
          if value_h = value.as_h?
            masked_h = {} of String => JSON::Any
            value_h.each do |key, child_value|
              child_def = props[key]?
              if child_def.nil?
                masked_h[key] = child_value unless real?(auth_context)
                next
              end
              masked_child = mask_field(child_value, child_def, auth_context)
              masked_h[key] = masked_child unless masked_child.nil?
            end
            return JSON::Any.new(masked_h)
          end
          return value
        end

        if items = field_def.items
          if value_arr = value.as_a?
            masked_arr = [] of JSON::Any
            value_arr.each do |item|
              masked_item = mask_field(item, items, auth_context)
              masked_arr << masked_item unless masked_item.nil?
            end
            return JSON::Any.new(masked_arr)
          end
          return value
        end

        if dict_value = field_def.dictionary_value
          if value_h = value.as_h?
            masked_h = {} of String => JSON::Any
            value_h.each do |key, child_value|
              masked_child = mask_field(child_value, dict_value, auth_context)
              masked_h[key] = masked_child unless masked_child.nil?
            end
            return JSON::Any.new(masked_h)
          end
        end

        value
      end

      # Walks one caller-submitted value at `path`. `field_def` is `nil`
      # for keys the definition does not declare — doctype validation
      # rejects those with its own error, so the write guard skips them.
      private def self.walk_submitted(
        value : JSON::Any,
        field_def : Doctype::FieldDefinition?,
        path : Array(String),
        auth_context : AuthContext,
        violations : Array(Array(String)),
      ) : Nil
        return if field_def.nil?

        unless field_visible?(auth_context, field_def)
          violations << path
          return
        end

        if props = field_def.properties
          if value_h = value.as_h?
            value_h.each do |key, child_value|
              walk_submitted(child_value, props[key]?, path + [key], auth_context, violations)
            end
          end
          return
        end

        if items = field_def.items
          if value_arr = value.as_a?
            value_arr.each do |item|
              walk_submitted(item, items, path, auth_context, violations)
            end
          end
          return
        end

        if dict_value = field_def.dictionary_value
          if value_h = value.as_h?
            value_h.each do |key, child_value|
              walk_submitted(child_value, dict_value, path + [key], auth_context, violations)
            end
          end
        end
      end

      private def self.real?(auth_context : AuthContext) : Bool
        auth_context.principal.is_a?(Principal::Real)
      end

      # System and Preview keep their bypasses on every surface — reads
      # stay raw, and the write guards never refuse them.
      private def self.bypass?(auth_context : AuthContext) : Bool
        auth_context.system? || auth_context.preview?
      end
    end
  end
end
