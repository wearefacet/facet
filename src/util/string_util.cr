# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # General-purpose string helpers shared across services.
    class StringUtil
      # Truncates `s` to at most `max` characters.
      #
      # - If `s.size <= max`, returns `s` unchanged.
      # - If `s.size > max` and `max > ellipsis.size`, returns the first
      #   `max - ellipsis.size` characters of `s` followed by `ellipsis`,
      #   so the total length equals `max`.
      # - If `max <= ellipsis.size`, returns `ellipsis` truncated to `max`
      #   (this is the degenerate case; the result still honours the cap).
      #
      # Characters are counted by Crystal's `String#size`, which is
      # Unicode-codepoint-aware — multi-byte characters count as one each.
      # Slicing uses `String#[Range]`, which is also codepoint-aware.
      def self.truncate(s : String, max : Int32, ellipsis : String = "...") : String
        return s if s.size <= max
        return ellipsis[0...max] if max <= ellipsis.size
        s[0...(max - ellipsis.size)] + ellipsis
      end

      # Converts a snake_case or kebab-case identifier to a human-readable
      # label: splits on `_` and `-`, capitalises each word, joins with spaces.
      #
      # ```
      # StringUtil.humanize("in_progress") # => "In Progress"
      # StringUtil.humanize("done")        # => "Done"
      # ```
      def self.humanize(key : String) : String
        key.split(/[_\-]/)
          .reject(&.empty?)
          .map { |word| word[0].upcase + word[1..] }
          .join(" ")
      end
    end
  end
end
