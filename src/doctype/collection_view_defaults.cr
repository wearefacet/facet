# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./doctype_definition"

module Facet
  module Doctype
    module CollectionView
      # Computes the default `core.CollectionView` row seeded for every
      # doctype that declares a `collection_view` child slot.
      #
      # The seeded view is a general (shared, `owner_id` absent) `table`
      # surface whose columns are the first eight **scalar** fields of the
      # doctype, in declaration order. Non-scalar field types
      # (`object`, `array`, `dictionary`, `child`, `data`, `any`, `file`)
      # and the `longtext` blob type are excluded — `longtext` is a
      # primitive, but its bulk makes it a poor default column.
      #
      # Boolean columns carry `editable: true` (unless the field is
      # `read_only` / `write_only`): a boolean is a state flag, and the
      # table renders those cells as toggles gated on the viewer's `update`
      # permission. The flag is a column-config member the frontend owns —
      # see `frontend/src/lib/collectionView/types.ts`.
      #
      # This mirrors the frontend fallback in
      # `frontend/src/lib/components/Data/ListView.svelte` →
      # `fallbackColumns()`. Keep the two skip sets aligned: a doctype
      # that gets the seeded view from this module must produce the same
      # column set the frontend would synthesise on the rare empty-views
      # path (legacy doctypes, or all views deleted).
      module Defaults
        # Field type names eligible for the seeded default columns.
        # See the module docs for the exclusion rationale.
        SCALAR_COLUMN_TYPES = Set{
          "string", "integer", "boolean", "enum", "money",
          "datetime", "date", "dateperiod", "period",
          "reference", "color", "duration", "phone", "url",
        }

        # Maximum number of columns in the seeded default view.
        MAX_COLUMNS = 8

        # The tab label of the seeded view. The user may rename it after
        # creation — this value is only the seed initial content.
        DEFAULT_NAME = "All Records"

        record Column, key : String, label : String?, editable : Bool?

        # Returns the ordered column list the seeded view would carry
        # for the given doctype definition. Walks `defn.fields` in
        # declaration order, keeps the first `MAX_COLUMNS` fields whose
        # `FieldType#type_name` is in `SCALAR_COLUMN_TYPES`, and uses
        # the field's `title` (or `nil` to fall back to the key) as the
        # column label. Boolean fields carry `editable: true` so the
        # table offers an inline toggle — except `read_only`/
        # `write_only` fields, which user input can never set.
        def self.columns_for(defn : DoctypeDefinition) : Array(Column)
          selected = [] of Column
          defn.fields.each do |key, field|
            break if selected.size >= MAX_COLUMNS
            type_name = field.type.try(&.type_name)
            next unless type_name && SCALAR_COLUMN_TYPES.includes?(type_name)
            editable = type_name == "boolean" && !field.read_only? && !field.write_only?
            # `title` is the user-authored label; `nil` lets the
            # frontend fall back to the field key.
            selected << Column.new(key: key, label: field.title, editable: editable)
          end
          selected
        end

        # Builds the full `core.CollectionView` content JSON for the
        # seeded default view of `defn`. The shape matches
        # `data/seeds/core.CollectionView/definition.yml`:
        # `name`, `surface` (`table`), `config.columns` (key + optional
        # label). `owner_id` is deliberately omitted so the row is a
        # general (shared) view.
        def self.build_content(defn : DoctypeDefinition) : JSON::Any
          columns = columns_for(defn)
          columns_arr = columns.map do |col|
            h = {} of String => JSON::Any
            h["key"] = JSON::Any.new(col.key)
            if label = col.label
              h["label"] = JSON::Any.new(label)
            end
            if col.editable
              h["editable"] = JSON::Any.new(true)
            end
            JSON::Any.new(h)
          end

          config = {} of String => JSON::Any
          config["columns"] = JSON::Any.new(columns_arr)

          root = {} of String => JSON::Any
          root["name"] = JSON::Any.new(DEFAULT_NAME)
          root["surface"] = JSON::Any.new("table")
          root["config"] = JSON::Any.new(config)
          JSON::Any.new(root)
        end
      end
    end
  end
end
