# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Assistant
    module Workspace
      # Typed view of the `agent_conversations.context` jsonb column for a
      # workspace conversation.
      #
      # Stored as a jsonb string (not a separate table) — see
      # `doc/backend/agent-conversations.md` for the conversation schema.
      # The streaming route parses `context` via `.from_conversation_context`
      # and — on a hit — wires the workspace registrar onto the `Agent`.
      struct Context
        KIND = "workspace"

        getter created_by : String

        def initialize(@created_by : String)
        end

        # Parses a workspace `Context` from the conversation's stored
        # `context` jsonb. Returns `nil` when the payload is absent, is not
        # an object, does not name the workspace kind, or carries no
        # `created_by`.
        #
        # `created_by` is the conversation's owner and the only account the
        # read surfaces (get / stream / list) admit. It never defaults: a
        # workspace context without an owner fails closed here, and the
        # generic conversation-create route rejects the kind outright, so a
        # stored context can only be written by the dedicated route.
        def self.from_conversation_context(json : JSON::Any) : self?
          return nil unless json.as_h? && json["kind"]?.try(&.as_s?) == KIND

          created_by = json["created_by"]?.try(&.as_s?)
          return nil if created_by.nil? || created_by.empty?

          new(created_by: created_by)
        end

        # Serialises the context to a JSON string suitable for the
        # `agent_conversations.context` jsonb column.
        def to_json : String
          JSON.build do |json|
            json.object do
              json.field "kind", KIND
              json.field "created_by", @created_by
            end
          end
        end
      end
    end
  end
end
