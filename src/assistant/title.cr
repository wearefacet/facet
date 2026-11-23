# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Assistant
    # Derives the auto-title of a conversation from its first user message.
    #
    # The stream route calls `.title_from_content` after the first turn
    # opens; `Conversation.set_title` stores the value in the conversation's
    # `context` jsonb. The rule is deliberately mechanical — no model call:
    # collapse all whitespace runs (newlines included) into single spaces,
    # trim, and cap at 60 characters with an ellipsis. A blank or absent
    # content yields `nil` and the caller skips the write.
    module Title
      # Maximum stored title length, ellipsis included.
      MAX_LENGTH = 60

      # Derives the title, or `nil` when the message carries no usable text.
      def self.from_content(content : String?) : String?
        value = content.try(&.gsub(/\s+/, " "))
        return nil if value.nil?
        value = value.strip
        return nil if value.empty?
        return value[0, MAX_LENGTH - 1] + "…" if value.size > MAX_LENGTH
        value
      end
    end
  end
end
