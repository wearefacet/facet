# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # Describes a named, domain-owned context set used for custom scopes.
    #
    # Context sets are stored on the `core.Domain` definition (free-form JSONB,
    # validated by `RBAC::Validator`). They are resolved at request time
    # against the `projections` table.
    #
    # Example:
    #   my_teams:
    #     from: TeamMembership
    #     where: { account: $self }
    #     select: team
    struct ContextSet
      getter name : String
      getter from : String                # DocType name within the same domain
      getter where : Hash(String, String) # map of field -> value (may contain $self/$set references)
      getter select_field : String        # field name to project

      def initialize(
        @name : String,
        @from : String,
        @where : Hash(String, String),
        @select_field : String,
      )
      end

      # Reserved value tokens that are not context-set references. A `where`
      # value starting with `$` is a dependency reference unless it is one of
      # these built-in tokens.
      RESERVED_VALUE_TOKENS = ["$self", "$null", "$organizational_unit"]

      # Returns the set reference names used in the `where` clause (values
      # starting with $ but not a reserved token).
      def dependencies : Array(String)
        @where.values.select do |v|
          v.starts_with?("$") && !RESERVED_VALUE_TOKENS.includes?(v)
        end.map { |v| v[1..] }
      end

      def to_s : String
        "ContextSet(#{@name}: from #{@from} select #{@select_field} where #{@where})"
      end
    end
  end
end
