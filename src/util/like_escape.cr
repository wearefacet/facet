# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Shared LIKE/ILIKE pattern escaping.
    #
    # Escapes the PostgreSQL `LIKE` / `ILIKE` special characters (`\`, `%`,
    # `_`) so a user-supplied value is matched literally rather than acting
    # as a wildcard. Every SQL fragment that binds an escaped value must
    # carry an explicit `ESCAPE '\'` clause.
    #
    # Used by `Util::FilterSet` (the `__match` / `__starts_with` text
    # operators), `Document::List#add_search_filter`, and
    # `Assistant::Conversation` (plain text-column `__match`).
    module LikeEscape
      # Escapes the LIKE/ILIKE special characters (\, %, _) so a user
      # value is matched literally. Always paired with an explicit
      # ESCAPE '\' clause in the emitted SQL fragment.
      def self.escape(value : String) : String
        value.gsub(/[\\%_]/) { |c| "\\#{c}" }
      end
    end
  end
end
