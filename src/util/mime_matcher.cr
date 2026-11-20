# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # MIME type pattern matcher for `file` field `accept` constraints.
    #
    # A pattern is `type/subtype` where the subtype may be `*` (e.g.
    # `image/*`, `application/pdf`). The type segment must be a concrete
    # token — a bare `*` type is rejected at schema validation time; the
    # absence of `accept` is the intended way to allow any MIME.
    module MimeMatcher
      PATTERN_RE = /^[A-Za-z0-9!#$&^_.+-]+\/(?:\*|[A-Za-z0-9!#$&^_.+-]+)$/

      # True when `pattern` is a well-formed `type/subtype` token whose
      # subtype is `*` or a concrete MIME subtype.
      def self.valid_pattern?(pattern : String) : Bool
        PATTERN_RE.matches?(pattern)
      end

      # True when `mime` (e.g. `image/png`) satisfies any entry in
      # `patterns` (e.g. `["image/*", "application/pdf"]`). An empty or
      # `nil` pattern list accepts anything — callers should pass `accept`
      # straight through without invoking this helper.
      def self.matches?(mime : String, patterns : Array(String)) : Bool
        patterns.any? { |p| pattern_matches?(mime, p) }
      end

      private def self.pattern_matches?(mime : String, pattern : String) : Bool
        slash = pattern.index('/')
        return false unless slash

        p_type = pattern[0...slash]
        p_sub = pattern[(slash + 1)..]

        m_slash = mime.index('/')
        return false unless m_slash

        m_type = mime[0...m_slash]
        m_sub = mime[(m_slash + 1)..]

        p_type == m_type && (p_sub == "*" || p_sub == m_sub)
      end
    end
  end
end
