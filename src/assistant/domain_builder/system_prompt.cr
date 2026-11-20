# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./context"
require "../language"

module Facet
  module Assistant
    module DomainBuilder
      # The system prompt for a domain-builder conversation.
      #
      # The static portion is embedded at compile time from
      # `system_prompt.md` via the `read_file` macro. Dynamic values
      # (draft domain, target name, description) are substituted at
      # runtime and placed at the very end of the prompt under
      # "Session context". This keeps the prefix byte-identical across
      # all conversations, so the LLM provider's KV cache (prefix
      # caching) stays hot between turns of the same conversation and
      # across different conversations.
      #
      # `build` takes the operator's custom-instructions block formatted by
      # `Assistant::CustomPrompt.block` and appends it after the session
      # context — the language directive (`Assistant::Language.block`, from
      # the create body's `language` field) comes first, the custom block
      # rides at the very end. Both are baked once at conversation creation;
      # passing nothing keeps the prompt byte-identical to the bare form.
      module SystemPrompt
        # The raw template, read at compile time. Contains `$DRAFT_DOMAIN`,
        # `$TARGET_NAME_LINE`, and `$DESCRIPTION_LINE` placeholders.
        TEMPLATE = {{ `cat #{__DIR__}/system_prompt.md`.stringify }}

        # Builds the system prompt for the given `Context`, with the
        # optional language directive and the optional custom-instructions
        # block appended at the very end (language first).
        def self.build(context : Context, custom_instructions : String? = nil, language : String? = nil) : String
          target_line = context.target_name?.try { |t| "- Target live name: `#{t}` (advisory)." } || ""
          description_line = context.description?.try { |d| "- Intent: #{d}" } || ""

          prompt = TEMPLATE
            .gsub("$DRAFT_DOMAIN", context.draft_domain)
            .gsub("$TARGET_NAME_LINE", target_line)
            .gsub("$DESCRIPTION_LINE", description_line)
          prompt = prompt.rstrip
          if language_block = Language.block(language)
            prompt = "#{prompt}\n\n#{language_block}"
          end
          return prompt if custom_instructions.nil? || custom_instructions.empty?
          "#{prompt}\n\n#{custom_instructions}"
        end
      end
    end
  end
end
