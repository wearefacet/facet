# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

require "../config"
require "../system_settings/service"

module Facet
  module Assistant
    # The operator's custom instructions for the assistants, appended to the
    # workspace and domain-builder prompts when a conversation starts.
    #
    # The text comes from the `assistant.system_prompt` system setting; the
    # file value is the fallback tier. Resolution mirrors the
    # `SystemSettings::AssistantView` chain: the settings document wins over
    # the file.
    #
    # The block is baked into the conversation row at creation and never
    # re-read on later turns, so a settings change reaches only new
    # conversations and the prompt stays byte-stable across a conversation's
    # turns (the provider KV-cache prefix stays hot).
    module CustomPrompt
      # The markdown heading of the block. Matches the label the admin UI
      # uses for the setting.
      HEADER = "## Custom instructions"

      # Resolves the custom instructions and formats them as a prompt block.
      # Returns `nil` when nothing is set — callers append nothing. A blank
      # or whitespace-only value means "no block".
      def self.block(db : DB::Connection) : String?
        text = Facet::SystemSettings.string_at(db, "assistant.system_prompt") ||
               Facet::Config.instance.assistant.system_prompt
        text = text.try(&.strip)
        return nil if text.nil? || text.empty?
        "#{HEADER}\n\n#{text}"
      end
    end
  end
end
