# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./field_definition"
require "./children_definition"
require "./doctype_definition"

module Facet
  module Doctype
    # Structural comparison between two `DoctypeDefinition`s.
    #
    # This module is the single authority for the version gate's data-shape
    # contract: **a `schema_version` bump is forced only when the data shape
    # changes in a way existing stored documents could not satisfy without a
    # migration.** Presentation, authoring, and access metadata — titles,
    # descriptions, defaults, operators, view scopes, compute hooks, enum
    # labels/colors — do not alter the shape of existing data.
    #
    # *Data shape* = the fields (recursive structural attributes), the
    # `children` map (compared on `doctype` and `collection` only), and
    # `member_of`. The diff API (`data_shape_changes`) applies the add rule
    # at every level: a change that only *introduces* new named surface (a
    # new field key, a new enum key, a new nested property key, a new
    # `children` entry) is additive and never rejected by the same-version
    # gates.
    #
    # `equal?` (the publish gate's equality) is zero data-shape changes —
    # additive included — **and** unchanged `actions` (action edits keep
    # forcing a version bump at publish).
    module Structure
      # One data-shape difference between a live and a draft definition.
      #
      # - `kind` — `:field`, `:children`, or `:member_of`
      # - `label` — human-readable, for rejection and log messages
      # - `additive` — `true` when the change only introduces new named
      #   surface (the same-version gates never reject additive changes)
      record Change, kind : Symbol, label : String, additive : Bool

      # Every data-shape difference, additive ones included, in a stable
      # order: fields (sorted by key), then `children`, then `member_of`.
      def self.data_shape_changes(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
      ) : Array(Change)
        changes = [] of Change
        field_map_changes(live.fields, draft.fields, "field", changes)
        children_changes(live, draft, changes)
        member_of_change(live, draft, changes)
        changes
      end

      # Returns `true` when at least one difference is non-additive — the
      # condition the same-version gates reject on.
      def self.data_shape_changes?(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
      ) : Bool
        data_shape_changes(live, draft).any? { |change| !change.additive }
      end

      # Returns `true` when no non-additive data-shape difference exists.
      # Additive changes do not count — they are the documented non-breaking
      # edits.
      def self.data_shape_equal?(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
      ) : Bool
        !data_shape_changes?(live, draft)
      end

      # Publish equality: zero data-shape changes (additive included) and
      # unchanged `actions`. Deliberately stricter than `data_shape_equal?`
      # — the publish gate forces a version bump for any data-shape edit,
      # even the additive ones, and for action edits.
      def self.equal?(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
      ) : Bool
        data_shape_changes(live, draft).empty? &&
          live.actions.to_json == draft.actions.to_json
      end

      # ── Field maps ───────────────────────────────────────────────────

      # Walks the union of both key sets in sorted order. Field order is not
      # structural (a reordered `Hash` serializes the same JSON). A key only
      # in the draft is an additive addition; a key only in `live` is a
      # removal.
      private def self.field_map_changes(
        live : Hash(String, FieldDefinition),
        draft : Hash(String, FieldDefinition),
        prefix : String,
        changes : Array(Change),
      ) : Nil
        (live.keys | draft.keys).sort!.each do |name|
          path = "#{prefix} '#{name}'"
          live_field = live[name]?
          draft_field = draft[name]?
          if live_field.nil?
            changes << Change.new(:field, "#{path} added", true)
          elsif draft_field.nil?
            changes << Change.new(:field, "#{path} removed", false)
          else
            field_changes(live_field, draft_field, path, changes)
          end
        end
      end

      # ── A single field ───────────────────────────────────────────────

      private def self.field_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        scalar_changes(live, draft, path, changes)
        enum_changes(live, draft, path, changes)
        reference_changes(live, draft, path, changes)
        nested_changes(live, draft, path, changes)
      end

      # Plain scalar / constraint attributes: type, required, unique,
      # collection, min/max, pattern.
      private def self.scalar_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        type_changes(live, draft, path, changes)
        if live.required != draft.required
          changes << Change.new(:field, "#{path} required #{live.required} → #{draft.required}", false)
        end
        if live.unique != draft.unique
          changes << Change.new(:field, "#{path} unique #{live.unique} → #{draft.unique}", false)
        end
        if live.collection != draft.collection
          changes << Change.new(:field, "#{path} collection #{live.collection} → #{draft.collection}", false)
        end
        constraint_changes(live, draft, path, changes)
      end

      private def self.type_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        live_type = live.type.try(&.type_name)
        draft_type = draft.type.try(&.type_name)
        return if live_type == draft_type
        changes << Change.new(:field, "#{path} type #{live_type || "none"} → #{draft_type || "none"}", false)
      end

      private def self.constraint_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        return unless live.min != draft.min || live.max != draft.max ||
                      live.pattern != draft.pattern || live.pattern_flags != draft.pattern_flags
        changes << Change.new(:field, "#{path} min/max/pattern changed", false)
      end

      # Enum structural identity is the ordered set of keys. Labels and
      # colors are presentation and are intentionally ignored. Pure key
      # additions (no removal, no reorder) are additive — existing stored
      # values stay valid. Removal and reorder gate.
      private def self.enum_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        live_keys = live.values.try(&.map(&.key))
        draft_keys = draft.values.try(&.map(&.key))
        return if live_keys == draft_keys
        additive = !live_keys.nil? && !draft_keys.nil? &&
                   draft_keys.size > live_keys.size &&
                   draft_keys.select { |key| live_keys.includes?(key) } == live_keys
        changes << Change.new(:field, "#{path} enum keys #{additive ? "added" : "changed"}", additive)
      end

      # Reference-target attributes: the target doctype, ownership flags,
      # replication config, on-delete behaviour, and the reference filter.
      private def self.reference_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        if live.doctype != draft.doctype
          changes << Change.new(:field, "#{path} reference target #{live.doctype || "none"} → #{draft.doctype || "none"}", false)
        end
        if live.owned != draft.owned || live.on_source_delete != draft.on_source_delete ||
           live.replicate != draft.replicate || filter_changed?(live.filter, draft.filter)
          changes << Change.new(:field, "#{path} owned / on_source_delete / replicate / filter changed", false)
        end
      end

      # `filter` (the reference filter hash) is structural: it changes the
      # predicate existing references must satisfy. Compared via canonical
      # JSON so key order and `JSON::Any` value identity do not matter.
      private def self.filter_changed?(
        live : Hash(String, JSON::Any)?,
        draft : Hash(String, JSON::Any)?,
      ) : Bool
        return false if live.nil? && draft.nil?
        return true if live.nil? || draft.nil?
        live.to_json != draft.to_json
      end

      # Recurses through the three sub-schema-bearing attributes. Any
      # data-shape change inside a nested field is a data-shape change of
      # the parent. The add rule applies at every level: a new property key
      # inside `properties` is additive; `items` / `dictionary_value` are
      # single slots, so appearing or disappearing is non-additive.
      private def self.nested_changes(
        live : FieldDefinition,
        draft : FieldDefinition,
        path : String,
        changes : Array(Change),
      ) : Nil
        nested_slot_changes(live.items, draft.items, "#{path} items", changes)
        properties_changes(live.properties, draft.properties, path, changes)

        live_value = live.dictionary_value
        draft_value = draft.dictionary_value
        if live_value.nil? && draft_value.nil?
          # Identical.
        elsif live_value.nil? || draft_value.nil?
          changes << Change.new(:field, "#{path} dictionary value changed", false)
        else
          field_changes(live_value, draft_value, "#{path} dictionary value", changes)
        end
      end

      # One nullable sub-field slot: two `nil`s are equal, a `nil` vs a
      # present field is a non-additive change.
      private def self.nested_slot_changes(
        live : FieldDefinition?,
        draft : FieldDefinition?,
        path : String,
        changes : Array(Change),
      ) : Nil
        if live.nil? && draft.nil?
          # Identical.
        elsif live.nil? || draft.nil?
          changes << Change.new(:field, "#{path} changed", false)
        else
          field_changes(live, draft, path, changes)
        end
      end

      # The add rule applies to the properties map: a missing map or a new
      # key is additive, a missing key is a removal. Two absent maps (or two
      # empty ones) produce nothing.
      private def self.properties_changes(
        live : Hash(String, FieldDefinition)?,
        draft : Hash(String, FieldDefinition)?,
        path : String,
        changes : Array(Change),
      ) : Nil
        empty = {} of String => FieldDefinition
        field_map_changes(live || empty, draft || empty, "#{path} property", changes)
      end

      # ── children / member_of ─────────────────────────────────────────

      # The `children` map is compared on `doctype` and `collection` only —
      # a `description` edit is presentation noise. The add rule applies: a
      # new entry is additive (no existing rows are affected); removal,
      # retarget, and collection flip gate.
      private def self.children_changes(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
        changes : Array(Change),
      ) : Nil
        (live.children.keys | draft.children.keys).sort!.each do |name|
          live_child = live.children[name]?
          draft_child = draft.children[name]?
          if live_child.nil?
            changes << Change.new(:children, "children: entry '#{name}' added", true)
          elsif draft_child.nil?
            changes << Change.new(:children, "children: entry '#{name}' removed", false)
          elsif live_child.doctype != draft_child.doctype || live_child.collection? != draft_child.collection?
            changes << Change.new(:children, "children: entry '#{name}' changed", false)
          end
        end
      end

      # `member_of` re-parents the composition semantics of existing rows —
      # any change gates.
      private def self.member_of_change(
        live : DoctypeDefinition,
        draft : DoctypeDefinition,
        changes : Array(Change),
      ) : Nil
        return if live.member_of == draft.member_of
        changes << Change.new(:member_of, "member_of: #{render_member_of(live.member_of)} → #{render_member_of(draft.member_of)}", false)
      end

      private def self.render_member_of(member_of : String?) : String
        member_of || "none"
      end
    end

    # The doctype version gate shared by `Doctype::Update` and the portable
    # domain import's merge path. One authority for the three rules:
    #
    # 1. `schema_version` never decreases.
    # 2. `schema_version` jumps at most +1 (a breaking change, carrying a
    #    migration per version gap).
    # 3. A same-version edit must be additive. The migrations guard is never
    #    bypassed; `$force` relaxes only the destructive data-shape
    #    rejections (field removal, type change, remaining shape changes).
    #
    # `check` returns structured violations. `render` produces the
    # message strings in guard order; `style` selects the caller's
    # historical wording. `Update` maps the first message to a
    # `ServiceError`. The import prefixes it with the qualified doctype
    # id and raises `ImportError`.
    module DefinitionGate
      # The same-version guard outcome, in guard order. `migrations_present`
      # is checked even under `$force`; the remaining three are collected
      # only when the edit is not forced.
      record SameVersionViolations,
        migrations_present : Bool,
        removed_fields : Array(String),
        type_changes : Array({field: String, from: String?, to: String?}),
        shape_labels : Array(String)

      # Version-monotonicity violations, rendered in the wording both call
      # sites share (the import prefixes each message with the qualified
      # doctype id). Empty when the version move is legal.
      def self.version_violations(current_version : Int32, new_version : Int32) : Array(String)
        violations = [] of String
        if new_version < current_version
          violations << "schema_version cannot decrease (current: #{current_version}, got: #{new_version})"
        end
        if new_version > current_version + 1
          violations << "schema_version must be exactly #{current_version + 1} (got: #{new_version}) for a breaking change"
        end
        violations
      end

      # Runs the same-version guards. Returns `nil` when nothing gates:
      # a breaking update, a clean edit, or — under `$force` — an edit whose
      # only issue would be the data-shape rejections. All checks are pure
      # structure comparisons, so collecting every violation has no side
      # effects; the renderers short-circuit in guard order.
      def self.same_version_violations(
        current_def : DoctypeDefinition,
        new_def : DoctypeDefinition,
        is_breaking : Bool,
        force : Bool,
      ) : SameVersionViolations?
        return nil if is_breaking

        migrations_present = !new_def.migrations.empty?
        return SameVersionViolations.new(true, [] of String, [] of {field: String, from: String?, to: String?}, [] of String) if force && migrations_present
        return nil if force

        removed_fields = current_def.fields.keys.to_set - new_def.fields.keys.to_set
        type_changes = collect_type_changes(current_def, new_def)
        shape_labels = Structure.data_shape_changes(current_def, new_def).reject(&.additive).map(&.label)

        return nil if !migrations_present && removed_fields.empty? && type_changes.empty? && shape_labels.empty?

        SameVersionViolations.new(
          migrations_present,
          removed_fields.to_a,
          type_changes,
          shape_labels,
        )
      end

      # Caller style for `render`. Each gate caller keeps its historical
      # message wording, so no user-visible text changes in this refactor.
      enum Style
        Update
        Import
      end

      # Renders same-version guard rejections as message strings, in guard
      # order. `style` selects the historical wording of the caller. Callers
      # map the first string to their own error type: `Update` wraps it in a
      # `ServiceError`; the import prefixes the qualified doctype id and
      # raises `ImportError`.
      def self.render(violations : SameVersionViolations, style : Style) : Array(String)
        messages = [] of String

        if violations.migrations_present
          messages << case style
          in .update? then "Non-breaking update (same schema_version) must not include migrations"
          in .import? then "same-version edit must not include migrations (use schema_version + 1)"
          end
        end

        unless violations.removed_fields.empty?
          messages << "#{prefix(style)}cannot remove fields: #{violations.removed_fields.sort.join(", ")}. Use schema_version bump with a migration, or pass $force: true#{suffix(style)}"
        end

        if type_change = violations.type_changes.first?
          messages << "#{prefix(style)}cannot change type of field '#{type_change[:field]}' (#{type_change[:from]} #{arrow(style)} #{type_change[:to]}). Use schema_version bump with a migration, or pass $force: true#{suffix(style)}"
        end

        unless violations.shape_labels.empty?
          messages << "#{prefix(style)}cannot change the doctype's data shape: #{violations.shape_labels.join("; ")}. Use schema_version bump with a migration, or pass $force: true#{suffix(style)}"
        end

        messages
      end

      private def self.prefix(style : Style) : String
        case style
        in .update? then "Non-breaking update "
        in .import? then "same-version edit "
        end
      end

      private def self.arrow(style : Style) : String
        case style
        in .update? then "->"
        in .import? then "→"
        end
      end

      private def self.suffix(style : Style) : String
        case style
        in .update? then ""
        in .import? then "."
        end
      end

      # Fields whose declared type changed between the two definitions.
      private def self.collect_type_changes(
        current_def : DoctypeDefinition,
        new_def : DoctypeDefinition,
      ) : Array({field: String, from: String?, to: String?})
        type_changes = [] of {field: String, from: String?, to: String?}
        current_def.fields.each do |name, current_field|
          next unless new_field = new_def.fields[name]?
          current_type = current_field.type.try(&.type_name)
          new_type = new_field.type.try(&.type_name)
          type_changes << {field: name, from: current_type, to: new_type} if current_type != new_type && new_type != nil
        end
        type_changes
      end
    end
  end
end
