# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Lookup table backing `Operator.parse` — kept as a module constant so
    # the parser stays under ameba's cyclomatic-complexity threshold.
    OPERATOR_BY_NAME = {
      "eq"          => Operator::Eq,
      "ne"          => Operator::Ne,
      "gt"          => Operator::Gt,
      "gte"         => Operator::Gte,
      "lt"          => Operator::Lt,
      "lte"         => Operator::Lte,
      "between"     => Operator::Between,
      "in"          => Operator::In,
      "match"       => Operator::Match,
      "starts_with" => Operator::StartsWith,
      "contains"    => Operator::Contains,
      "overlaps"    => Operator::Overlaps,
      "within"      => Operator::Within,
      "currency"    => Operator::Currency,
    }

    # Reverse lookup (`suffix → operator`) backing `Operator.parse_suffix`.
    # The suffix form is the lower-case name with a `__` prefix.
    OPERATOR_BY_SUFFIX = OPERATOR_BY_NAME.each_with_object({} of String => Operator) do |(name, op), acc|
      acc["__#{name}"] = op
    end

    # Comparison / filter operators — the **runtime** query vocabulary.
    #
    # These are the suffix forms parsed out of URL filter keys
    # (`field__gte=...`) and consumed by the `Document::List` clause
    # builders and `FilterSet`. They are **not** authored directly: a
    # doctype field declares `FilterCapability` values (the authoring
    # vocabulary), and `FieldDefinition#operators` derives the operator
    # set from them via `FilterCapability#operators`.
    #
    # Declaration order is significant: `FieldDefinition#operators`
    # returns the derived union sorted by this enum's declaration order,
    # so the family for a capability (`comparison` →
    # `eq, ne, gt, gte, lt, lte, between`) reads in the natural sequence.
    enum Operator
      Eq         # equality
      Ne         # not-equal
      Gt         # greater-than (numeric / datetime)
      Gte        # greater-than-or-equal (numeric / datetime)
      Lt         # less-than (numeric / datetime)
      Lte        # less-than-or-equal (numeric / datetime)
      Between    # inclusive range [start, end] (numeric / datetime)
      In         # set membership — value is a JSON array, matches any entry
      Match      # text pattern — substring match (ILIKE '%term%' ESCAPE '\')
      StartsWith # text pattern — prefix match (ILIKE 'term%' ESCAPE '\')

      # Range-vs-range / range-vs-point operators for `period` and
      # `dateperiod` fields. All GiST-indexable over PostgreSQL range
      # types (`tstzrange`, `daterange`).
      Contains # `@>` — range contains a point or sub-range
      Overlaps # `&&` — range intersects another range
      Within   # `<@` — range is contained by another range

      # Currency-equality operator for `money` fields. Matches the stored
      # `currency` member of the `{"value","currency"}` object (text
      # equality). Indexable via the `btree_money_currency` index.
      Currency

      # Serialise to JSON as the lower-case string.
      def to_json(builder : JSON::Builder) : Nil
        builder.string(to_s.underscore)
      end

      # Case-insensitive parser for JSON deserialisation.
      def self.parse(value : String) : self
        Doctype::OPERATOR_BY_NAME[value.downcase]? || raise ArgumentError.new("Unknown operator: #{value.inspect}")
      end

      # Converts the operator to its URL / query-string suffix form:
      # `__` + the underscored member name. `to_s.downcase` alone is not
      # enough — `StartsWith` would lose the underscore (`startswith`).
      def suffix : String
        "__#{to_s.underscore}"
      end

      # Parses a suffix string back into an operator.
      def self.parse_suffix(suffix : String) : self
        Doctype::OPERATOR_BY_SUFFIX[suffix]? || raise ArgumentError.new("Unknown operator suffix: #{suffix}")
      end

      # Returns true if this operator is one of the range operators
      # (`contains`, `overlaps`, `within`). Used by the index manager
      # to decide whether to emit a GiST range index for `period` /
      # `dateperiod` fields, and by `Document::List` to expand range
      # filter clauses against the doctype field type.
      def range? : Bool
        contains? || overlaps? || within?
      end
    end
  end
end
