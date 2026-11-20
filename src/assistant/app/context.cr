# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Assistant
    module App
      # Typed view of the `agent_conversations.context` jsonb column for an
      # app-assistant conversation.
      #
      # Stored as a jsonb string (not a separate table) — see
      # `doc/backend/agent-conversations.md` for the conversation schema.
      # The streaming route parses `context` via `.from_conversation_context`
      # and — on a hit — re-runs the app gate on every message and wires the
      # app registrar onto the `Agent`.
      #
      # Both stored values are server-derived at creation: `created_by` is
      # the caller (the conversation's owner), `app_id` is the app the
      # caller's token named (`RBAC::AuthContext#app_id`). The create route
      # never reads either from the body, and the generic create route
      # rejects the kind outright, so a stored context can only be written
      # by the dedicated route.
      struct Context
        KIND = "app"

        getter created_by : String
        getter app_id : String

        def initialize(@created_by : String, @app_id : String)
        end

        # Parses an app `Context` from the conversation's stored `context`
        # jsonb. Returns `nil` when the payload is absent, is not an object,
        # does not name the app kind, or misses either value.
        #
        # Both fields fail closed: an app conversation without an owner has
        # no account the read surfaces can scope to, and one without an app
        # id has no app the per-message gate can re-check.
        def self.from_conversation_context(json : JSON::Any) : self?
          return nil unless json.as_h? && json["kind"]?.try(&.as_s?) == KIND

          created_by = json["created_by"]?.try(&.as_s?)
          app_id = json["app_id"]?.try(&.as_s?)
          return nil if created_by.nil? || created_by.empty?
          return nil if app_id.nil? || app_id.empty?

          new(created_by: created_by, app_id: app_id)
        end

        # Serialises the context to a JSON string suitable for the
        # `agent_conversations.context` jsonb column.
        def to_json : String
          JSON.build do |json|
            json.object do
              json.field "kind", KIND
              json.field "created_by", @created_by
              json.field "app_id", @app_id
            end
          end
        end
      end
    end
  end
end
