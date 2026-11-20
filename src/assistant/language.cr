# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Assistant
    # The user-language directive for the assistant prompts.
    #
    # The client sends the user's current language as a BCP-47 tag in the
    # `language` field of a conversation-create request. `block` formats it
    # as one markdown block, `## Language`, which states the language and
    # tells the model to write in it. The user can still ask for another
    # language in the conversation; the directive yields to that explicit
    # request.
    #
    # The block is baked into the conversation row at creation and never
    # re-read on later turns, so the prompt stays byte-stable across the
    # conversation (the provider KV-cache prefix stays hot). A request with
    # no language appends nothing.
    module Language
      # The markdown heading of the block.
      HEADER = "## Language"

      # A language tag is short and has a small charset. The check keeps
      # junk, newlines, and free text out of the baked prompt. 35 is the
      # BCP-47 length upper bound.
      TAG_PATTERN    = /^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$/
      MAX_TAG_LENGTH = 35

      # Formats the directive block. Returns `nil` when the tag is absent,
      # blank, or not a valid language tag — callers append nothing.
      def self.block(tag : String?) : String?
        value = tag.try(&.strip)
        return nil if value.nil? || value.empty?
        return nil if value.size > MAX_TAG_LENGTH
        return nil unless TAG_PATTERN.matches?(value)
        "#{HEADER}\n\nThe user's current language is `#{value}`. Write all " \
        "your replies in that language. Use another language only when the " \
        "user explicitly asks for it."
      end
    end
  end
end
