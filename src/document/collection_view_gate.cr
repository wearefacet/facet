# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../validation_error"

module Facet
  module Document
    # Write-time semantic gate for the `core.CollectionView` `config` field.
    #
    # `config` is a free-form `object` at the document layer — the definition
    # declares no properties, so the generic schema validation accepts any
    # nested shape. The per-surface rules live in the frontend editor
    # (`frontend/src/lib/collectionView/config.ts`, `validateDraft`) and in
    # the renderer's tolerant fallbacks, so a config the renderer cannot use
    # used to land with a `201` and then render an empty surface. This gate
    # runs those rules against the **parent** doctype's definition at the
    # document write doors and answers `422` with field paths, mirroring
    # `Document::ViewTemplateGate` for `core.DocumentView`.
    #
    # The rules, per `surface`:
    #
    # | Surface    | Rule |
    # |------------|------|
    # | `table`    | at least one column; every column `key` is declared on the parent doctype (or is a system timestamp) |
    # | `calendar` | `discriminator` exists and serves the window filter (`gte` + `lte`, or a `period` / `dateperiod` range type) |
    # | `kanban`   | `mode ∈ {values, custom}`; `values` needs a `group_by` that exists, is writable, is `enum` / `boolean`, and serves `eq`; `custom` needs at least one lane |
    #
    # The field rules mirror the frontend pickers (`discriminatorFields`,
    # `groupableFields`), which read the derived operator set — the same set
    # `FieldDefinition#operators` exposes here.
    module CollectionViewGate
      # Calendar discriminator types — the range types fetch their window
      # with no field filter (native range), the others need `gte` + `lte`.
      CALENDAR_DISCRIMINATOR_TYPES = Set{"date", "datetime", "period", "dateperiod"}

      # Kanban group-by types — one lane per declared enum value, or the
      # True / False pair for a boolean.
      KANBAN_GROUP_BY_TYPES = Set{"enum", "boolean"}

      # System-managed timestamp columns. Every projection row carries them,
      # and the view editor offers them as table columns and calendar
      # discriminators, so the gate resolves them beside the declared fields.
      SYSTEM_TIMESTAMP_FIELDS = Set{"created_at", "updated_at"}

      # Kanban lane modes.
      KANBAN_MODES = Set{"values", "custom"}

      # Validates a `core.CollectionView` content object's `config` against
      # the parent doctype definition (the `core.DocType` projection the
      # view attaches to). `surface` is the view's surface — `config` alone
      # does not carry it; `errors` reads it from the document and the
      # update door passes the submitted one (the patch's, else the stored
      # one). Returns one `ValidationError` per problem, empty when there is
      # nothing to check: no `config`, no resolvable `surface`, no parent
      # id, or an unresolvable parent definition.
      #
      # Shared by the create and update dispatches, and by
      # `Doctype::Check` for the post-hoc diagnostics pass.
      def self.errors(
        db : DB::Connection,
        parent_id : String?,
        document : JSON::Any,
      ) : Array(ValidationError)
        errors(db, parent_id, document["config"]?, document["surface"]?.try(&.as_s?))
      end

      # The config-and-surface form of `errors`: resolves the parent
      # definition, then runs the pure rule set (`validate`). Empty when
      # there is no `config`, no `surface`, no parent id, or the parent
      # definition cannot be resolved.
      def self.errors(
        db : DB::Connection,
        parent_id : String?,
        config : JSON::Any?,
        surface : String?,
      ) : Array(ValidationError)
        return [] of ValidationError unless config
        return [] of ValidationError unless surface
        return [] of ValidationError unless parent_id

        case defn = Doctype::DefinitionStore.fetch!(db, parent_id)
        when Doctype::DoctypeDefinition
          validate(config, surface, defn)
        else
          # An absent or corrupt parent definition skips the check — the
          # write path's other guards own that failure.
          [] of ValidationError
        end
      end

      # The pure rule set: validates `config` against `surface` and the
      # parent doctype definition. No database access — `errors` resolves
      # the parent and delegates here.
      def self.validate(
        config : JSON::Any,
        surface : String?,
        parent_definition : Doctype::DoctypeDefinition,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        case surface
        when "table"
          validate_table(config, parent_definition, errors)
        when "calendar"
          validate_calendar(config, parent_definition, errors)
        when "kanban"
          validate_kanban(config, parent_definition, errors)
        end
        errors
      end

      private def self.validate_table(
        config : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        columns = config["columns"]?.try(&.as_a?)
        if columns.nil? || columns.empty?
          errors << ValidationError.new(
            field: "config.columns",
            message: "a table view needs at least one column",
            code: "required",
          )
          return
        end

        columns.each_with_index do |column, index|
          key = column["key"]?.try(&.as_s?)
          if key.nil? || key.empty?
            errors << ValidationError.new(
              field: "config.columns.#{index}.key",
              message: "column #{index + 1} has no key",
              code: "required",
            )
            next
          end
          next if field_known?(defn, key)
          errors << ValidationError.new(
            field: "config.columns.#{index}.key",
            message: "column '#{key}' is not a field of the parent doctype",
            code: "unknown_field",
          )
        end
      end

      private def self.validate_calendar(
        config : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        calendar = config["calendar"]?
        unless calendar
          errors << ValidationError.new(
            field: "config.calendar",
            message: "a calendar view needs a calendar configuration",
            code: "required",
          )
          return
        end

        discriminator = calendar["discriminator"]?.try(&.as_s?)
        if discriminator.nil? || discriminator.empty?
          errors << ValidationError.new(
            field: "config.calendar.discriminator",
            message: "a calendar view needs a discriminator field",
            code: "required",
          )
          return
        end

        unless serves_calendar_window?(defn, discriminator)
          errors << ValidationError.new(
            field: "config.calendar.discriminator",
            message: "discriminator '#{discriminator}' cannot serve the calendar window filter — it must be a date, datetime, period, or dateperiod field, and a date or datetime must serve the 'gte' and 'lte' filters (the 'comparison' capability)",
            code: "unsupported_field",
          )
        end
      end

      private def self.validate_kanban(
        config : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        kanban = config["kanban"]?
        unless kanban
          errors << ValidationError.new(
            field: "config.kanban",
            message: "a kanban view needs a kanban configuration",
            code: "required",
          )
          return
        end

        mode = kanban["mode"]?.try(&.as_s?)
        unless mode && KANBAN_MODES.includes?(mode)
          errors << ValidationError.new(
            field: "config.kanban.mode",
            message: "kanban mode must be 'values' or 'custom'",
            code: "invalid_value",
          )
          return
        end

        if mode == "values"
          validate_kanban_values(kanban, defn, errors)
        else
          validate_kanban_custom(kanban, errors)
        end
      end

      private def self.validate_kanban_values(
        kanban : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        group_by = kanban["group_by"]?.try(&.as_s?)
        if group_by.nil? || group_by.empty?
          errors << ValidationError.new(
            field: "config.kanban.group_by",
            message: "values mode needs a group-by field",
            code: "required",
          )
          return
        end

        unless groupable_field?(defn, group_by)
          errors << ValidationError.new(
            field: "config.kanban.group_by",
            message: "group-by '#{group_by}' cannot serve the lanes' equality filter — it must be a writable enum or boolean field with an equality capability",
            code: "unsupported_field",
          )
        end
      end

      private def self.validate_kanban_custom(
        kanban : JSON::Any,
        errors : Array(ValidationError),
      ) : Nil
        lanes = kanban["lanes"]?.try(&.as_a?)
        return if lanes && !lanes.empty?

        errors << ValidationError.new(
          field: "config.kanban.lanes",
          message: "custom mode needs at least one lane",
          code: "required",
        )
      end

      # True when `key` names a declared parent field or a system timestamp.
      private def self.field_known?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        SYSTEM_TIMESTAMP_FIELDS.includes?(key) || defn.fields.has_key?(key)
      end

      # The calendar rule: a range type serves its window natively; a
      # date / datetime needs both `gte` and `lte` on the field itself.
      private def self.serves_calendar_window?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        return true if SYSTEM_TIMESTAMP_FIELDS.includes?(key)
        field = defn.fields[key]?
        return false unless field
        type_name = field.type.try(&.type_name)
        return false unless type_name && CALENDAR_DISCRIMINATOR_TYPES.includes?(type_name)
        return true if type_name == "period" || type_name == "dateperiod"

        operators = field.operators
        operators.includes?(Doctype::Operator::Gte) && operators.includes?(Doctype::Operator::Lte)
      end

      # The kanban values rule: a writable enum or boolean field that serves
      # `eq` (every lane filters `field__eq`).
      private def self.groupable_field?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        field = defn.fields[key]?
        return false unless field
        return false if field.read_only? || field.write_only
        type_name = field.type.try(&.type_name)
        return false unless type_name && KANBAN_GROUP_BY_TYPES.includes?(type_name)

        field.operators.includes?(Doctype::Operator::Eq)
      end
    end
  end
end
