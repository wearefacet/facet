# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../doctype"

module Facet
  module Index
    # Describes a single PostgreSQL partial index we want to manage.
    record DesiredIndex,
      domain : String,
      doc_type : String,
      field_name : String,
      index_type : String

    # Computes the index set that a doctype definition needs. Pure
    # computation: no database access and no DDL. `Manager` diffs this
    # set against the `doctype_indexes` table and runs the DDL lifecycle.
    module Planner
      # ── Desired index computation ──────────────────────────────────────

      # Walks the doctype definition fields and produces the set of indexes
      # that should exist.
      def self.compute_desired(definition : Doctype::DoctypeDefinition) : Set(DesiredIndex)
        result = Set(DesiredIndex).new
        domain = definition.domain
        doc_type = definition.doctype

        definition.fields.each do |field_name, field_def|
          compute_field_desired(domain, doc_type, field_name, field_def, result)
        end

        result
      end

      # Recursively compute desired indexes for a single field definition.
      private def self.compute_field_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        # Skip computed, write-only, read-only, and child fields.
        # Reference fields are NOT skipped — they always get a reference
        # index (see `compute_reference_desired`) because replication and
        # cross-doctype joins depend on O(1) lookup by reference id.
        return if field_def.computed? || field_def.write_only? || field_def.read_only?
        return if field_type_skipped?(field_def)

        dispatch_by_category(field_type_category(field_def), domain, doc_type, field_name, field_def, result)
      end

      private def self.dispatch_by_category(
        type_category : Symbol,
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        case type_category
        when :reference
          compute_reference_desired(domain, doc_type, field_name, field_def, result)
        when :range_tstz, :range_date
          compute_range_desired(domain, doc_type, field_name, field_def, type_category, result)
        when :money
          compute_money_desired(domain, doc_type, field_name, field_def, result)
        when :scalar
          compute_scalar_desired(domain, doc_type, field_name, field_def, result)
        when :container
          compute_container_desired(domain, doc_type, field_name, field_def, result)
        when :object_with_properties
          # Recurse into sub-fields — the object itself is not indexed directly
          if props = field_def.properties
            props.each do |sub_name, sub_def|
              nested_name = "#{field_name}.#{sub_name}"
              compute_field_desired(domain, doc_type, nested_name, sub_def, result)
            end
          end
        when :skip
          # Not indexable
        end
      end

      # Returns the index category for a field definition.
      private def self.field_type_category(field_def : Doctype::FieldDefinition) : Symbol
        type = field_def.type
        return :skip if type.nil?

        case type.type_name
        when "reference"
          :reference
        when "period"
          :range_tstz
        when "dateperiod"
          :range_date
        when "money"
          :money
        when "string", "integer", "duration", "datetime", "date", "boolean", "enum", "longtext", "phone", "url"
          :scalar
        when "array", "dictionary"
          :container
        when "object"
          field_def.properties.nil? ? :skip : :object_with_properties
        else
          :skip
        end
      end

      # Returns true if a field type should always be skipped for indexing.
      private def self.field_type_skipped?(field_def : Doctype::FieldDefinition) : Bool
        type = field_def.type
        return true if type.nil?

        case type.type_name
        when "data", "secret"
          true
        else
          false
        end
      end

      # Reference fields always get a btree index on `content->>'field_name'`
      # restricted to their (domain, doc_type) and to non-deleted rows.
      #
      # The user-writable `filters` array is deliberately ignored for
      # references: a reference is an exact-id equality lookup, never a
      # range or pattern match. Replication and cross-doctype joins rely on
      # this index existing for every reference field.
      private def self.compute_reference_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        result << DesiredIndex.new(domain, doc_type, field_name, "btree")
      end

      # Computes desired indexes for a scalar field (string, integer, etc.).
      # Index choice is driven by the field's declared `FilterCapability`
      # values — each capability maps 1:1 to an index family:
      # - `equality` / `comparison` → btree (text-extract or numeric).
      # - `text_search`            → `gin_trgm`.
      private def self.compute_scalar_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        # Unique fields need a UNIQUE btree index for DB-level enforcement
        if field_def.unique
          result << DesiredIndex.new(domain, doc_type, field_name, "unique_btree")
        end

        caps = field_def.filters
        return if caps.nil? || caps.empty?

        has_btree_cap = caps.any? { |c| c.equality? || c.comparison? }
        has_text_cap = caps.any?(&.text_search?)

        if has_btree_cap
          # `integer` / `duration` fields need a typed btree index
          # (`jsonb_as_numeric(content->'field')`) so range scans and typed
          # ORDER BY align with the filter/sort expressions emitted by
          # `Document::List`. Other scalar types use the text-extract btree.
          btree_type = numeric_field?(field_def) ? "btree_numeric" : "btree"
          result << DesiredIndex.new(domain, doc_type, field_name, btree_type)
        end
        result << DesiredIndex.new(domain, doc_type, field_name, "gin_trgm") if has_text_cap
      end

      # Computes desired indexes for a `money` field.
      #
      # Two index types are emitted (per `Naming.access_expression`):
      #
      # - `btree_money` — composite `(numeric_value, currency_text)` btree.
      #   Serves value comparison operators (`eq`, `gte`, `lte`, `between`)
      #   with an optional currency constraint, and currency-agnostic value
      #   filters via the leading column.
      # - `btree_money_currency` — plain btree on the currency text extract.
      #   Serves the `currency` operator (text equality on the ticker).
      #
      # A `unique: true` money field keeps the standard `unique_btree` on
      # `content->>'field'` (text equality on the whole JSON object string)
      # for DB-level uniqueness enforcement.
      # Capability-driven: both
      # `btree_money` (composite value+currency) and `btree_money_currency`
      # (currency text) are emitted whenever *any* money capability is
      # declared — the composite value index is kept as a cheap secondary
      # even when only `currency` is requested (and vice-versa).
      private def self.compute_money_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        # Unique fields need a UNIQUE btree index for DB-level enforcement
        if field_def.unique
          result << DesiredIndex.new(domain, doc_type, field_name, "unique_btree")
        end

        caps = field_def.filters
        return if caps.nil? || caps.empty?

        has_money_cap = caps.any? { |c| c.equality? || c.comparison? || c.currency? }
        return unless has_money_cap

        # `btree_money` — composite `(numeric_value, currency_text)` btree.
        # Serves value comparison operators (`eq`, `gt`, `gte`, `lt`, `lte`,
        # `between`) with an optional currency constraint, and
        # currency-agnostic value filters via the leading column.
        result << DesiredIndex.new(domain, doc_type, field_name, "btree_money")

        # `btree_money_currency` — plain btree on the currency text extract.
        # Serves the `currency` operator (text equality on the ticker). Kept
        # as a cheap secondary even when only value caps are
        # declared.
        result << DesiredIndex.new(domain, doc_type, field_name, "btree_money_currency")
      end

      # Returns true if the field's declared type is a numeric scalar
      # (`integer` or `duration`) — the types whose btree index must use
      # `jsonb_as_numeric(content->'field')` to preserve numeric ordering.
      # `money` is NOT included here: it has its own category (`:money`) and
      # the `btree_money` composite index.
      private def self.numeric_field?(field_def : Doctype::FieldDefinition) : Bool
        type = field_def.type
        return false if type.nil?
        case type.type_name
        when "integer", "duration"
          true
        else
          false
        end
      end

      # Computes the desired index for a range field (`period` /
      # `dateperiod`). The range type is dispatched via `type_category`,
      # which carries the PostgreSQL range flavour (tstzrange vs
      # daterange); the access expression is generated by `Naming`
      # using the corresponding index_type string (`gist_tstzrange` /
      # `gist_daterange`).
      #
      # A single GiST range index serves all range operators (`eq`,
      # `contains`, `overlaps`, `within`). Range fields never get btree,
      # gin_trgm, or gin_jsonb indexes: those index types have no
      # meaningful semantics over a PostgreSQL range value.
      private def self.compute_range_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        type_category : Symbol,
        result : Set(DesiredIndex),
      ) : Nil
        caps = field_def.filters
        return if caps.nil? || caps.empty?

        # `equality` (`eq` range equality) and `interval` (GiST range
        # operators) both map to the same GiST range index. Cross-cutting
        # validation already rejected other capabilities on range fields,
        # so the absence of either means no filterable capability was
        # declared — emit nothing.
        has_range_cap = caps.any? { |c| c.equality? || c.interval? }
        return unless has_range_cap

        index_type = case type_category
                     when :range_tstz then "gist_tstzrange"
                     when :range_date then "gist_daterange"
                     else
                       return
                     end

        result << DesiredIndex.new(domain, doc_type, field_name, index_type)
      end

      # Computes desired indexes for a container field (`array`). Index
      # choice is driven by the field's declared `FilterCapability`:
      # - `membership` → `gin_jsonb` (array containment `@>` / `&&`).
      # `dictionary` fields are not supported for `membership` (validation
      # rejects it at authoring time) and never receive `gin_jsonb` here.
      private def self.compute_container_desired(
        domain : String,
        doc_type : String,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        result : Set(DesiredIndex),
      ) : Nil
        caps = field_def.filters
        return if caps.nil? || caps.empty?

        return unless caps.any?(&.membership?)

        result << DesiredIndex.new(domain, doc_type, field_name, "gin_jsonb")
      end
    end
  end
end
