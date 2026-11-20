# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./operator"
require "./field_type"

module Facet
  module Doctype
    # Field type names where `equality` is valid. Single-value scalar /
    # numeric / datetime / money / enum fields, the range types (`period`,
    # `dateperiod` — equality on a range is range equality), and the
    # pointer type `reference` (a reference is an exact-id
    # equality lookup — `equality` is a valid declaration there even though
    # `Index::Manager` always emits a btree on references regardless).
    # Containers (`array`, `dictionary`) use `membership`; `data` / `object`
    # / `file` / `any` are not filterable by equality.
    EQUALITY_TYPES = {
      "string", "longtext", "integer", "duration", "datetime", "date",
      "boolean", "enum", "phone", "url", "money", "color",
      "period", "dateperiod",
      "reference",
    }

    # Field type names where `comparison` is valid. Strict subset of
    # `EQUALITY_TYPES` minus the range types — `period` / `dateperiod` use
    # `interval` — minus the containers — `array` uses `membership` — and
    # minus `boolean`: a two-state field serves `equality` only (the runtime
    # grammar derives no ordering or match operators on it).
    COMPARISON_TYPES = {
      "string", "longtext", "integer", "duration", "datetime", "date",
      "enum", "phone", "url", "money", "color",
    }

    # Field type names where `text_search` is valid (string-like only).
    TEXT_SEARCH_TYPES = {
      "string", "longtext", "phone", "url", "enum",
    }

    # Field type names where `interval` is valid (range types only).
    RANGE_TYPES = {"period", "dateperiod"}

    # The runtime operator ceilings per field type — the operator suffixes the
    # clause builders can compile (`Document::FilterCompiler` routes by the
    # same sets). `FieldDefinition#operators` and `DerivedOperators` intersect
    # the derived set with this ceiling, so the stored metadata and the
    # frontend filter bar never advertise an operator the runtime would
    # reject with `unsupported_filter_operator` (`comparison` on a money
    # field fans out to `ne`, but the money builder does not serve it).
    RANGE_OPERATOR_SET     = Set{"eq", "contains", "overlaps", "within"}
    MONEY_OPERATOR_SET     = Set{"eq", "gt", "gte", "lt", "lte", "between", "currency"}
    CONTAINER_OPERATOR_SET = Set{"eq", "contains", "overlaps"}
    REFERENCE_OPERATOR_SET = Set{"eq", "ne"}
    # A boolean is a two-state field: equality only. The full comparison
    # family is legal PG on booleans (`false < true`) but meaningless as a
    # filter, and a substring match over the stored `true`/`false` text is
    # noise — the grammar serves neither.
    BOOLEAN_OPERATOR_SET = Set{"eq", "ne"}
    # The ceiling for every type without a dedicated clause-builder routing
    # (string-like, numeric, datetime, enum, color, …).
    COMPARISON_OPERATOR_SET = Set{"eq", "ne", "match", "starts_with", "gt", "gte", "lt", "lte", "between", "in"}

    # Returns the operator suffixes the clause builders compile for a field
    # of the named type. Unknown type names get the general comparison
    # ceiling (the type validator reports the type separately).
    def self.supported_operators(type_name : String?) : Set(String)
      case type_name
      when "period", "dateperiod" then RANGE_OPERATOR_SET
      when "money"                then MONEY_OPERATOR_SET
      when "array"                then CONTAINER_OPERATOR_SET
      when "boolean"              then BOOLEAN_OPERATOR_SET
      when "reference"            then REFERENCE_OPERATOR_SET
      else                             COMPARISON_OPERATOR_SET
      end
    end

    # Authoring vocabulary for the filters a field supports.
    #
    # A capability is what the doctype author picks in the editor (one or
    # more per field). It maps 1:1 to (a) a family of runtime `Operator`s
    # (the URL / query-suffix surface) and (b) a physical index family.
    # The user never authors raw operators; the backend derives both the
    # operator set and the indexes from the declared capabilities.
    #
    # Two concerns, two enums:
    # - `FilterCapability` — authoring (what the user picks, stored on the
    #   field as `filters: Array(FilterCapability)?`).
    # - `Operator` — runtime (query parsing, `Document::List` clause
    #   builders). `FieldDefinition#operators` is a computed getter that
    #   fans `filters` out into the union operator set.
    enum FilterCapability
      # Equality on the stored scalar value. Valid on every field type
      # that stores a single value. Backed by a btree / unique_btree /
      # btree_numeric / btree_money / GiST-range `eq` index depending on
      # the field type.
      Equality

      # Full comparison: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between`.
      # Valid on scalar / numeric / datetime / money fields — **not** on
      # `period` / `dateperiod` (range types — use `interval`), **not** on
      # `array` (use `membership`), and **not** on `boolean` (a two-state
      # field takes `equality` only). Emits the same btree as `equality`
      # (one index serves the whole family).
      Comparison

      # Substring / pattern match (`match`). Valid on string-like fields
      # (`string`, `longtext`, `phone`, `url`, `enum`). Emits `gin_trgm`.
      TextSearch

      # Range-vs-range / range-vs-point operators (`eq`, `contains`,
      # `overlaps`, `within`) over a PostgreSQL range type. Valid only on
      # `period` and `dateperiod`. Emits a GiST range index
      # (`gist_tstzrange` / `gist_daterange`).
      Interval

      # Array-containment operators (`eq`, `contains`, `overlaps`) over a
      # stored JSONB array. Valid only on `array` (deliberately **not**
      # `dictionary` in this iteration). Emits `gin_jsonb`.
      Membership

      # Currency equality (`currency`) on a `money` field's stored ticker.
      # Valid only on `money`. Emits `btree_money_currency` (plus
      # `btree_money`, shared with `comparison` / `equality`).
      Currency

      # The lowercase snake_case string form used for JSON / YAML
      # serialisation and for error messages. `to_s.downcase` would yield
      # `textsearch` (no underscore) for `TextSearch`, so the wire form is
      # the underscored member name.
      def to_s_lowercase : String
        to_s.underscore
      end

      # Serialise to JSON as the lower-case snake_case name.
      def to_json(builder : JSON::Builder) : Nil
        builder.string(to_s_lowercase)
      end

      # Case-insensitive parser for JSON / YAML deserialisation. Matches
      # the wire form produced by `to_s_lowercase`.
      def self.parse(value : String) : self
        target = value.downcase
        found = values.find { |capability| capability.to_s_lowercase == target }
        found || raise ArgumentError.new("Unknown filter capability: #{value.inspect}")
      end

      # The capability names a field of the named type may declare, from
      # the compatibility tables above. Unknown type names yield the empty
      # set — the type validation reports the type separately.
      def self.valid_names_for_type(type_name : String?) : Array(String)
        return [] of String if type_name.nil?
        values.select do |capability|
          case capability
          in .equality?    then EQUALITY_TYPES.includes?(type_name)
          in .comparison?  then COMPARISON_TYPES.includes?(type_name)
          in .text_search? then TEXT_SEARCH_TYPES.includes?(type_name)
          in .interval?    then RANGE_TYPES.includes?(type_name)
          in .membership?  then type_name == "array"
          in .currency?    then type_name == "money"
          end
        end.map(&.to_s_lowercase)
      end

      # The runtime `Operator` family this capability expands to. Used by
      # `FieldDefinition#operators` to derive the URL-surface operator
      # set from the authored capabilities.
      def operators : Array(Operator)
        case self
        in .equality?    then [Operator::Eq] of Operator
        in .comparison?  then [Operator::Eq, Operator::Ne, Operator::Gt, Operator::Gte, Operator::Lt, Operator::Lte, Operator::Between] of Operator
        in .text_search? then [Operator::Match, Operator::StartsWith] of Operator
        in .interval?    then [Operator::Eq, Operator::Contains, Operator::Overlaps, Operator::Within] of Operator
        in .membership?  then [Operator::Eq, Operator::Contains, Operator::Overlaps] of Operator
        in .currency?    then [Operator::Currency] of Operator
        end
      end

      # Authoring compatibility: returns `true` when this capability may
      # be declared on a field whose declared type is `field_type`.
      # Drives `Doctype::Validation#validate_field_filters`.
      def valid_for?(field_type : FieldType) : Bool
        name = field_type.type_name
        case self
        in .equality?    then Doctype::EQUALITY_TYPES.includes?(name)
        in .comparison?  then Doctype::COMPARISON_TYPES.includes?(name)
        in .text_search? then Doctype::TEXT_SEARCH_TYPES.includes?(name)
        in .interval?    then Doctype::RANGE_TYPES.includes?(name)
        in .membership?  then name == "array"
        in .currency?    then name == "money"
        end
      end
    end
  end
end
