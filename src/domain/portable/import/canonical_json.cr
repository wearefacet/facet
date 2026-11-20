# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Domain
    module Portable
      module Import
        # ── Helpers — canonical JSON ─────────────────────────────────────

        # Two contents are identical when their canonical JSON forms
        # match. The canonical form strips key ordering so an unnecessary
        # diff is never produced.
        private def self.content_identical?(a : JSON::Any, b : JSON::Any) : Bool
          canonical_json(a) == canonical_json(b)
        end

        # Canonicalises JSON for stable comparison. Crystal's
        # `JSON::Any#to_json` is deterministic for a given tree; we
        # sort Hash keys at each level so nested object ordering does
        # not produce a false diff.
        private def self.canonical_json(value : JSON::Any) : String
          String.build { |io| canonical_into(io, value) }
        end

        private def self.canonical_into(io : IO, value : JSON::Any) : Nil
          case raw = value.raw
          when Hash
            io << '{'
            sorted = raw.to_a.sort_by(&.[0])
            sorted.each_with_index do |(k, v), i|
              io << ',' if i > 0
              k.to_json(io)
              io << ':'
              canonical_into(io, v)
            end
            io << '}'
          when Array
            io << '['
            raw.each_with_index do |v, i|
              io << ',' if i > 0
              canonical_into(io, v)
            end
            io << ']'
          else
            value.to_json(io)
          end
        end
      end
    end
  end
end
