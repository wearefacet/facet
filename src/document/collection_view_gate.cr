# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../util/filter_set"
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
    # | `grid`     | the table's column rules; a `summary` is a known aggregate on an aggregate-able field; `editable: true` only on a writable field; `grid.frozen` is an integer in `0..columns.length`; `grid.filters` keys serve their operators; `grid.sort` entries are known, sortable fields |
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

      # Grid Σ aggregates — `count` runs field-free on any column; the field
      # aggregates need an aggregate-able numeric type, mirroring
      # `List::Aggregate.AGGREGATE_FIELD_TYPES` (the backend answers 422 for
      # anything else at read time).
      GRID_SUMMARIES       = Set{"count", "sum", "avg", "min", "max"}
      GRID_AGGREGATE_TYPES = Set{"integer", "duration", "money"}

      # Grid column editability — the field types the cell editors cover,
      # mirroring the frontend `WRITABLE_FIELD_TYPES` (`grid/fieldTypes.ts`).
      # Containers, `data`, `file`, `secret`, and `any` never edit in the grid.
      GRID_WRITABLE_FIELD_TYPES = Set{"string", "longtext", "integer", "money", "date",
                                      "datetime", "period", "dateperiod", "enum", "boolean", "reference", "color",
                                      "duration", "phone", "url"}

      # Grid sort — the field types a list sort serves, mirroring
      # `Document::List.sort_expression_for` (the frontend
      # `SORTABLE_FIELD_TYPES`). Anything else answers `422 unsortable_field`
      # at read time.
      GRID_SORTABLE_FIELD_TYPES = Set{"string", "longtext", "integer", "boolean", "enum",
                                      "money", "datetime", "date", "reference", "color", "duration", "phone", "url"}

      # Operators the system timestamp columns serve as filters — the
      # compiler's `TIMESTAMP_OPERATORS` family
      # (`Document::FilterCompiler.allowed_operators`).
      GRID_TIMESTAMP_FILTER_OPERATORS = Set{"eq", "ne", "gt", "gte", "lt", "lte", "between"}

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
        when "grid"
          validate_grid(config, parent_definition, errors)
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
        validate_columns(config, defn, errors, "table")
      end

      private def self.validate_grid(
        config : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        # The grid reuses the table's `config.columns` array, so the column
        # rules are the table's.
        validate_columns(config, defn, errors, "grid")

        columns = config["columns"]?.try(&.as_a?)
        return if columns.nil? # absent or empty — already reported

        columns.each_with_index do |column, index|
          validate_grid_column(column, defn, index, errors)
        end

        grid = config["grid"]?
        validate_grid_settings(grid, columns.size, defn, errors) if grid
      end

      # The shared column walk: at least one column, and every `key` names a
      # declared parent field or a system timestamp. Shared by the table and
      # the grid — the grid keeps the table's columns on a surface switch.
      private def self.validate_columns(
        config : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
        surface : String,
      ) : Nil
        columns = config["columns"]?.try(&.as_a?)
        if columns.nil? || columns.empty?
          errors << ValidationError.new(
            field: "config.columns",
            message: "a #{surface} view needs at least one column",
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

      # The grid column semantics: a `summary` is a known aggregate — `count`
      # runs field-free, the others need an aggregate-able field type — and
      # `editable: true` is only valid on a writable field (the opt-out
      # `editable: false` is always fine). A key the parent doctype does not
      # declare is reported by `validate_columns`; the summary rule skips it.
      private def self.validate_grid_column(
        column : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        index : Int32,
        errors : Array(ValidationError),
      ) : Nil
        key = column["key"]?.try(&.as_s?)
        return if key.nil? || key.empty?

        summary = column["summary"]?.try(&.as_s?)
        if summary
          if GRID_SUMMARIES.includes?(summary)
            unless summary == "count"
              type_name = defn.fields[key]?.try(&.type.try(&.type_name))
              unless type_name && GRID_AGGREGATE_TYPES.includes?(type_name)
                shown = type_name || "of no declared type"
                errors << ValidationError.new(
                  field: "config.columns.#{index}.summary",
                  message: "summary '#{summary}' needs an integer, duration, or money field — column '#{key}' is #{shown}",
                  code: "unsupported_field",
                )
              end
            end
          else
            errors << ValidationError.new(
              field: "config.columns.#{index}.summary",
              message: "summary '#{summary}' is not a known aggregate (count, sum, avg, min, max)",
              code: "invalid_value",
            )
          end
        end

        return unless column["editable"]?.try(&.as_bool?) == true
        return if grid_writable_field?(defn, key)
        errors << ValidationError.new(
          field: "config.columns.#{index}.editable",
          message: "column '#{key}' cannot be editable in the grid — the field is computed, read_only, write_only, or of a type the cell editors do not cover",
          code: "unsupported_field",
        )
      end

      private def self.validate_grid_settings(
        grid : JSON::Any,
        column_count : Int32,
        defn : Doctype::DoctypeDefinition,
        errors : Array(ValidationError),
      ) : Nil
        if frozen = grid["frozen"]?
          count = frozen.as_i?
          if count.nil? || count < 0 || count > column_count
            errors << ValidationError.new(
              field: "config.grid.frozen",
              message: "grid.frozen must be an integer between 0 and the column count",
              code: "invalid_value",
            )
          end
        end

        if filters = grid["filters"]?.try(&.as_h?)
          filters.each do |key, _|
            next if grid_filter_serves?(defn, key)
            errors << ValidationError.new(
              field: "config.grid.filters.#{key}",
              message: "filter '#{key}' does not name a filterable target of the parent doctype with a served operator",
              code: "unsupported_field",
            )
          end
        end

        if sort = grid["sort"]?.try(&.as_a?)
          sort.each_with_index do |entry, index|
            validate_grid_sort_entry(entry, defn, index, errors)
          end
        end
      end

      # One `grid.sort` entry: a field key with an optional leading `-` for
      # descending. The entry must name a known, sortable field — the same
      # strict contract the list endpoint holds (`unknown_sort_field` /
      # `unsortable_field`).
      private def self.validate_grid_sort_entry(
        entry : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        index : Int32,
        errors : Array(ValidationError),
      ) : Nil
        key = entry.try(&.as_s?)
        if key.nil? || key.empty?
          errors << ValidationError.new(
            field: "config.grid.sort.#{index}",
            message: "sort entries must be field keys",
            code: "unknown_field",
          )
          return
        end
        col = key.starts_with?("-") ? key[1..] : key
        if col.empty?
          errors << ValidationError.new(
            field: "config.grid.sort.#{index}",
            message: "sort entry '#{key}' names no field",
            code: "unknown_field",
          )
          return
        end
        unless field_known?(defn, col)
          errors << ValidationError.new(
            field: "config.grid.sort.#{index}",
            message: "sort field '#{col}' is not a field of the parent doctype",
            code: "unknown_field",
          )
          return
        end
        return if grid_sortable_field?(defn, col)
        errors << ValidationError.new(
          field: "config.grid.sort.#{index}",
          message: "field '#{col}' cannot sort the grid — its type has no sort expression",
          code: "unsortable_field",
        )
      end

      # True when `key` names a declared parent field or a system timestamp.
      private def self.field_known?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        SYSTEM_TIMESTAMP_FIELDS.includes?(key) || defn.fields.has_key?(key)
      end

      # The grid edit rule: the field type is one the cell editors cover and
      # the schema does not lock it. System timestamps never resolve here —
      # they render as columns but never edit.
      private def self.grid_writable_field?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        field = defn.fields[key]?
        return false unless field
        return false if field.read_only? || field.write_only?
        type_name = field.type.try(&.type_name)
        return false unless type_name
        GRID_WRITABLE_FIELD_TYPES.includes?(type_name)
      end

      # The grid sort rule: a system timestamp or a declared field whose type
      # has a sort expression (`Document::List.sort_expression_for`).
      private def self.grid_sortable_field?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        return true if SYSTEM_TIMESTAMP_FIELDS.includes?(key)
        field = defn.fields[key]?
        return false unless field
        type_name = field.type.try(&.type_name)
        return false unless type_name
        GRID_SORTABLE_FIELD_TYPES.includes?(type_name)
      end

      # The grid filter rule: the key names a filterable target of the parent
      # doctype and carries an operator that target serves — the same contract
      # the listing compiles under (`FilterCompiler.validate_filters!`). A
      # declared field serves its derived `operators` set (already intersected
      # with the type ceiling); a system timestamp serves the comparison
      # family; `search` is the one bare-key production.
      private def self.grid_filter_serves?(defn : Doctype::DoctypeDefinition, key : String) : Bool
        field, op_suffix = Util::FilterSet.parse_filter_key(key)
        return true if field == "search" && !key.includes?("__")
        return false if field == "search"

        if SYSTEM_TIMESTAMP_FIELDS.includes?(field)
          return GRID_TIMESTAMP_FILTER_OPERATORS.includes?(op_suffix)
        end

        field_def = defn.fields[field]?
        return false unless field_def
        op = Doctype::OPERATOR_BY_NAME[op_suffix]?
        return false unless op
        field_def.operators.includes?(op)
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
