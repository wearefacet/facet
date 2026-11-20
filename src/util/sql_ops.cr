# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Shared map from filter-operator suffix to SQL comparison operator.
    #
    # Before this module each filter compiler kept its own copy, and the
    # unknown-operator branch had drifted: `FilterSet` silently widened an
    # unknown suffix to `=`, the typed builder skipped the key, the money
    # builder raised. A silent widening is the worst outcome — a filter the
    # caller thinks is special (say `price__includes=100`) quietly behaves
    # as `price = 100` and matches rows it should not match.
    #
    # ## Non-matching policy
    #
    # The mapping is explicit and closed. Nothing outside `MAP` maps to an
    # SQL operator, and an unknown suffix never widens to `=`:
    #
    # - `SQLOPS.for` raises `UnknownOperatorError`. Use it on paths that
    #   are gated upstream (field-type routing, scope authoring), where an
    #   unknown suffix is a programming error, never user input.
    # - `SQLOPS.lookup` returns `nil`; the caller degrades to a no-match
    #   result (`FALSE` clause, or a skipped key). Use it on user-input
    #   paths — a bad filter is a no-match, not a 500.
    module SQLOPS
      MAP = {
        "eq"  => "=",
        "gt"  => ">",
        "gte" => ">=",
        "lt"  => "<",
        "lte" => "<=",
      }

      # Raised by `for` on an unknown operator suffix. A programming error
      # on a gated path; user-input paths use `lookup` instead.
      class UnknownOperatorError < Exception
      end

      # Returns the SQL operator for *op*, or `nil` when unknown. The
      # non-matching entry point for user-input paths.
      def self.lookup(op : String) : String?
        MAP[op]?
      end

      # Returns the SQL operator for *op*; raises `UnknownOperatorError`
      # for an unknown suffix.
      def self.for(op : String) : String
        lookup(op) || raise UnknownOperatorError.new("no SQL operator for filter suffix '#{op}'")
      end
    end
  end
end
