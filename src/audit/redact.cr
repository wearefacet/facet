# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../doctype/definition_store"
require "../doctype/field_path"
require "../mutation/json_diff"

module Facet
  module Audit
    # Shape-aware redaction of mutation arguments for audit history.
    #
    # A tagged-down Real reader must not see invisible field values in the
    # mutation log: a create row carries full content, an update row
    # carries the diff with values. The redactor walks each row's
    # arguments against the target doctype definition — the same recursive
    # visibility walker the read surfaces use — removes invisible values,
    # and lists every removed content path in the out-of-band `redacted`
    # metadata (never `{"__redacted__": true}` markers inside the content,
    # which could collide with a valid object value).
    #
    # Rules by row shape (never by `cause_kind`):
    # - **create / snapshot** (and any row carrying `arguments.content`):
    #   invisible values are removed from `content`, their paths appended.
    # - **update** (any row carrying `arguments.diff`): `diff.set` entries
    #   at invisible paths keep their `path` but lose `value` / `patch`;
    #   a visible parent set with invisible nested content keeps the
    #   visible portion and lists each removed nested path. `diff.unset`
    #   paths stay visible (an unset reveals no value) and never gain a
    #   duplicate redaction entry.
    #   Diff-path resolution is shape-aware and shared with the write
    #   guards (`Doctype::FieldPath`). A path descends through object
    #   `properties`, array `items`, and dictionary `dictionary_value`.
    #   The stored members of the object-valued scalar kinds (money
    #   `value` / `currency`; period and dateperiod `start` / `end`;
    #   secret markers `mode` / `version` / `set_at`) resolve to the
    #   owning field, and so does any segment below a free-form shape
    #   (an `object` without `properties`, `any`, `data`). Visibility is
    #   checked at every level of the descent. A path that does not
    #   resolve fails closed.
    # - **missing definition**: fail closed — all content values are
    #   removed; the root path `[]` marks whole-content redaction, and
    #   each set path marks a redacted diff. Unknown historical fields
    #   (absent from the current definition) redact the same way.
    # - **System and Preview callers** receive raw arguments with an
    #   empty `redacted` array, as does a wildcard-tag role.
    module Redact
      # Redacts one page of mutation records for the given caller. Returns
      # new records (the input list is untouched). Definitions cache per
      # `(domain, doc_type)` inside the call.
      def self.apply(records : Array(List::MutationRecord), auth_context : RBAC::AuthContext, db : DB::Connection) : Array(List::MutationRecord)
        return records if auth_context.system? || auth_context.preview?
        return records if wildcard_tags?(auth_context)

        definitions = {} of String => Doctype::DoctypeDefinition?
        records.map do |record|
          key = "#{record.domain}.#{record.doc_type}"
          unless definitions.has_key?(key)
            definitions[key] = Doctype::DefinitionStore.fetch(db, key)
          end
          redact_record(record, auth_context, definitions[key])
        end
      end

      # ── Private ─────────────────────────────────────────────────────────

      private def self.redact_record(record : List::MutationRecord, auth_context : RBAC::AuthContext, definition : Doctype::DoctypeDefinition?) : List::MutationRecord
        args = record.arguments.as_h?
        return record if args.nil?

        redacted = [] of Array(String)

        if content = args["content"]?
          new_content, removed = redact_content(content, auth_context, definition)
          redacted.concat(removed)
          if !removed.empty? || content_invisible_root?(auth_context, definition)
            args = args.dup
            args["content"] = new_content
          end
        end

        if diff = args["diff"]?
          new_diff, removed = redact_diff(diff, auth_context, definition)
          redacted.concat(removed)
          unless removed.empty? || new_diff == diff
            args = args.dup
            args["diff"] = new_diff
          end
        end

        return record if redacted.empty?

        record.with_arguments(JSON::Any.new(args), redacted)
      end

      # True when a Real caller with this context must not see ANY content
      # of the doctype — the missing-definition fail-closed case.
      private def self.content_invisible_root?(auth_context : RBAC::AuthContext, definition : Doctype::DoctypeDefinition?) : Bool
        definition.nil?
      end

      # Walks one content value against the definition. Returns the
      # redacted content and the list of removed content paths.
      private def self.redact_content(content : JSON::Any, auth_context : RBAC::AuthContext, definition : Doctype::DoctypeDefinition?) : {JSON::Any, Array(Array(String))}
        if definition.nil?
          # Missing definition: remove all content values, mark the root.
          return {JSON::Any.new({} of String => JSON::Any), [[] of String]}
        end

        removed = [] of Array(String)
        content_h = content.as_h?
        return {content, removed} if content_h.nil?

        kept = {} of String => JSON::Any
        content_h.each do |key, value|
          field_def = definition.fields[key]?
          if field_def.nil?
            # Unknown historical field: fail closed for Real readers.
            removed << [key]
            next
          end
          kept_child, child_removed = redact_set_value(value, field_def, [key], auth_context)
          removed.concat(child_removed)
          kept[key] = kept_child unless kept_child.nil?
        end
        {JSON::Any.new(kept), removed}
      end

      # Redacts one `diff` object (set / unset). Set entries at invisible
      # paths keep the path and lose the value; visible parents recurse
      # into their added value. Unset paths never gain a redaction entry.
      private def self.redact_diff(diff : JSON::Any, auth_context : RBAC::AuthContext, definition : Doctype::DoctypeDefinition?) : {JSON::Any, Array(Array(String))}
        removed = [] of Array(String)
        diff_h = diff.as_h?
        return {diff, removed} if diff_h.nil?

        new_set = [] of JSON::Any
        (diff_h["set"]?.try(&.as_a?) || [] of JSON::Any).each do |entry|
          entry_h = entry.as_h?
          next new_set << entry if entry_h.nil?

          path = entry_h["path"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String

          if definition.nil?
            # Missing definition: keep the path, drop the value.
            removed << path
            new_set << JSON::Any.new({"path" => entry_h["path"]} of String => JSON::Any)
            next
          end

          field_def = resolve_visible_field(definition, path, auth_context)

          if field_def.nil?
            # Unknown historical path, or an invisible level inside the
            # descent — fail closed: keep the path, drop the value.
            removed << path
            new_set << JSON::Any.new({"path" => entry_h["path"]} of String => JSON::Any)
            next
          end

          # Visible path: inspect the added value for invisible nested
          # content (a visible parent set with invisible children).
          value = entry_h["value"]?
          if value.nil?
            # Line-patch form: one long string at a declared path — the
            # per-level checks above decided.
            new_set << entry
            next
          end

          kept_value, nested_removed = redact_set_value(value, field_def, path, auth_context)
          if nested_removed.empty?
            new_set << entry
          else
            removed.concat(nested_removed)
            new_entry = entry_h.dup
            if kept_value.nil?
              # The whole added value sits under an invisible field — keep
              # the path only.
              new_entry.delete("value")
            else
              new_entry["value"] = kept_value
            end
            new_set << JSON::Any.new(new_entry)
          end
        end

        new_diff = diff_h.dup
        new_diff["set"] = JSON::Any.new(new_set)
        {JSON::Any.new(new_diff), removed}
      end

      # Redacts one set value sitting at a visible-or-invisible `path`.
      # Returns the kept portion (`nil` when the value itself lands under
      # an invisible field) plus every removed nested path. Every child's
      # visibility is checked; visible leaves survive.
      private def self.redact_set_value(
        value : JSON::Any,
        field_def : Doctype::FieldDefinition,
        path : Array(String),
        auth_context : RBAC::AuthContext,
      ) : {JSON::Any?, Array(Array(String))}
        return {nil, [path]} unless RBAC::FieldVisibility.field_visible?(auth_context, field_def)

        if props = field_def.properties
          redact_object_value(value, props, path, auth_context)
        elsif items = field_def.items
          redact_array_value(value, items, path, auth_context)
        elsif dict_value = field_def.dictionary_value
          redact_dictionary_value(value, dict_value, path, auth_context)
        else
          {value, [] of Array(String)}
        end
      end

      # Redacts an object value against its declared `properties`.
      private def self.redact_object_value(
        value : JSON::Any,
        props : Hash(String, Doctype::FieldDefinition),
        path : Array(String),
        auth_context : RBAC::AuthContext,
      ) : {JSON::Any?, Array(Array(String))}
        removed = [] of Array(String)
        value_h = value.as_h?
        return {value, removed} if value_h.nil?

        kept = {} of String => JSON::Any
        value_h.each do |key, child_value|
          child_def = props[key]?
          if child_def.nil?
            # Unknown nested field — fail closed.
            removed << path + [key]
            next
          end
          kept_child, child_removed = redact_set_value(child_value, child_def, path + [key], auth_context)
          removed.concat(child_removed)
          kept[key] = kept_child unless kept_child.nil?
        end
        {JSON::Any.new(kept), removed}
      end

      # Redacts an array value against its declared `items`. A tagged
      # items descriptor drops the whole element (the array's own path
      # stays visible, so no redaction entry); an object items descriptor
      # redacts per property.
      private def self.redact_array_value(
        value : JSON::Any,
        items : Doctype::FieldDefinition,
        path : Array(String),
        auth_context : RBAC::AuthContext,
      ) : {JSON::Any?, Array(Array(String))}
        removed = [] of Array(String)
        value_arr = value.as_a?
        return {value, removed} if value_arr.nil?

        kept_items = [] of JSON::Any
        value_arr.each do |item|
          unless RBAC::FieldVisibility.field_visible?(auth_context, items)
            # Tagged array elements: the whole element is invisible.
            next
          end
          if (item_props = items.properties) && item.as_h?
            kept_item, item_removed = redact_object_value(item, item_props, path, auth_context)
            removed.concat(item_removed)
            kept_items << kept_item unless kept_item.nil?
          else
            kept_items << item
          end
        end
        {JSON::Any.new(kept_items), removed}
      end

      # Redacts a dictionary value against its declared value descriptor.
      private def self.redact_dictionary_value(
        value : JSON::Any,
        dict_value : Doctype::FieldDefinition,
        path : Array(String),
        auth_context : RBAC::AuthContext,
      ) : {JSON::Any?, Array(Array(String))}
        removed = [] of Array(String)
        value_h = value.as_h?
        return {value, removed} if value_h.nil?

        kept = {} of String => JSON::Any
        value_h.each do |key, child_value|
          kept_child, child_removed = redact_set_value(child_value, dict_value, path + [key], auth_context)
          removed.concat(child_removed)
          kept[key] = kept_child unless kept_child.nil?
        end
        {JSON::Any.new(kept), removed}
      end

      # Resolves one diff path against the definition and checks
      # visibility at every level of the descent. Returns the field
      # definition the last segment points at when every level resolves
      # and is visible. Returns `nil` when the path is unknown, or when
      # any level — the root field included — is invisible to the
      # caller. The decision matches the content walker: an invisible
      # level hides the whole subtree below it.
      private def self.resolve_visible_field(
        definition : Doctype::DoctypeDefinition,
        path : Array(String),
        auth_context : RBAC::AuthContext,
      ) : Doctype::FieldDefinition?
        levels = Doctype::FieldPath.levels(definition, path)
        return nil if levels.nil?
        levels.each do |level|
          return nil unless RBAC::FieldVisibility.field_visible?(auth_context, level)
        end
        levels.last
      end

      private def self.wildcard_tags?(auth_context : RBAC::AuthContext) : Bool
        real = auth_context.principal
        return false unless real.is_a?(RBAC::Principal::Real)
        real.active_role.wildcard_tags?
      end
    end
  end
end
