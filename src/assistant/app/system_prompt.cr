# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../language"

module Facet
  module Assistant
    module App
      # The system prompt for an app-assistant conversation.
      #
      # The static portion is embedded at compile time from
      # `system_prompt.md`. The Session context block is built at runtime
      # from server-read values — the app's display name, the token's
      # active role, the creation date — and appended after the static
      # body, so the prefix the provider KV-cache hashes stays
      # byte-identical across all app conversations.
      #
      # Assembly order: the static body, `## Session context`, the optional
      # `## Language` directive (`Assistant::Language.block`, from the
      # create body's `language` field), the optional `## App instructions`
      # block (the app's own `assistant_prompt` field), then the optional
      # `## Custom instructions` block (`Assistant::CustomPrompt.block` —
      # the operator's platform-wide text). All blocks are baked once at
      # conversation creation and never re-read on later turns; a missing
      # or blank block appends nothing.
      module SystemPrompt
        # The raw static body, read at compile time.
        TEMPLATE = {{ `cat #{__DIR__}/system_prompt.md`.stringify }}

        # The heading of the per-conversation runtime block.
        SESSION_HEADER = "## Session context"

        # The heading of the app's own instructions block.
        APP_HEADER = "## App instructions"

        # Builds the system prompt. `app_name` and `role` are server-read
        # values; `today` defaults to now (UTC) and lets a test pin the
        # date. `app_instructions` is the app's raw field text,
        # `custom_instructions` the preformatted operator block; both are
        # optional.
        def self.build(
          app_name : String,
          role : String,
          app_instructions : String? = nil,
          custom_instructions : String? = nil,
          language : String? = nil,
          today : Time = Time.utc,
        ) : String
          prompt = "#{TEMPLATE.rstrip}\n\n#{session_context(app_name, role, today)}"
          if language_block = Language.block(language)
            prompt = "#{prompt}\n\n#{language_block}"
          end
          if app_block = instructions_block(app_instructions)
            prompt = "#{prompt}\n\n#{app_block}"
          end
          return prompt if custom_instructions.nil? || custom_instructions.empty?
          "#{prompt}\n\n#{custom_instructions}"
        end

        # The per-conversation runtime block: the app's display name, the
        # caller's active role, the conversation's creation day (UTC — a
        # conversation that spans midnight keeps its day), and the boundary
        # line.
        private def self.session_context(app_name : String, role : String, today : Time) : String
          <<-BODY
          #{SESSION_HEADER}

          - App: #{app_name}.
          - Active role: #{role}.
          - Today's date: #{today.to_s("%Y-%m-%d")} (UTC).
          - You act strictly within this app's permissions: what you can see
            and change is bounded by the app's grant and the user's role —
            no more.
          BODY
        end

        # The app's own instructions as one markdown block. A blank or
        # whitespace-only value appends nothing.
        private def self.instructions_block(text : String?) : String?
          value = text.try(&.strip)
          return nil if value.nil? || value.empty?
          "#{APP_HEADER}\n\n#{value}"
        end
      end
    end
  end
end
