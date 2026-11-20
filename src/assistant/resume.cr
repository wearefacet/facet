# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "agent-cr"
require "json"
require "pg"
require "../error"
require "./config"
require "./conversation"
require "./turn"

module Facet
  module Assistant
    # Reconstructs an `Agent` session from stored conversation + turn rows.
    #
    # This is the read-side counterpart to `Conversation.create` /
    # `Turn.create`. It rebuilds the JSON shape `Agent#load` consumes
    # (`session_id`, `cache_key`, `history`, `enabled_tools`) by concatenating
    # `request_messages` ++ `response_messages` across turns in `idx` order.
    #
    # The reconstructed history is byte-identical to the original at the
    # persisted boundary, so the provider hashes the same message prefix
    # under the same `cache_key` and the KV cache stays hot.
    #
    # The assistant connection is NOT reconstructed here: the model, key,
    # and sampling knobs resolve from the effective runtime settings at turn
    # start (`SystemSettings::AssistantView`), and tool callbacks are
    # registered by the caller after `Agent.new`, driven by `context`
    # (mirroring how `Agent#load` already requires the app to re-register
    # tools before calling `#load`).
    module Resume
      # The retrieved session fields plus the reconstructed history.
      record Session,
        conversation : Conversation::Record,
        history : Array(Agent::Message),
        # The json the `Agent#load` API expects — ready to pass to `agent.load`.
        session_json : String

      module Result
        record Restored, session : Session
      end

      # Reconstructs a session from the database.
      def self.call(
        db : DB::Connection,
        conversation_id : String,
      ) : Result::Restored | Facet::ServiceError
        conversation = Conversation.find(db, conversation_id)
        return Facet::ServiceError.new(404, "Conversation #{conversation_id} not found") unless conversation

        turns = Turn.list(db, conversation_id)

        history = [] of Agent::Message
        turns.each do |turn|
          # Only completed turns contribute to the replay context. A
          # `running` row has no response yet — appending its request would
          # leave a dangling user message in the history. An `error` row is
          # a failed attempt the provider never answered as a consumable
          # turn — replayed, it would also poison the KV-cache prefix.
          # `done` and `cancelled` (partial response) turns both replay.
          # So does `capped`: the tool-loop cap stopped the turn between
          # iterations, so the partial exchange is a complete
          # assistant-tool_calls + tool-results prefix the next ask
          # continues from.
          next unless turn.status == "done" || turn.status == "cancelled" ||
                      turn.status == "capped"
          append_messages(history, turn.request_messages)
          append_messages(history, turn.response_messages)
        end

        session_json = build_session_json(
          conversation.session_id,
          conversation.cache_key,
          history,
          conversation.enabled_tools,
        )

        Result::Restored.new(Session.new(
          conversation: conversation,
          history: history,
          session_json: session_json,
        ))
      rescue ex : DB::Error
        Facet::ServiceError.new(500, "Database error: #{ex.message}")
      rescue ex : JSON::Error
        Facet::ServiceError.new(500, "Stored session data is malformed: #{ex.message}")
      end

      # Builds the JSON shape `Agent#load` consumes.
      private def self.build_session_json(
        session_id : String,
        cache_key : String,
        history : Array(Agent::Message),
        enabled_tools : JSON::Any,
      ) : String
        JSON.build do |json|
          json.object do
            json.field "version", 1
            json.field "session_id", session_id
            json.field "cache_key", cache_key
            json.field "history", history
            names = enabled_tools.as_a?
            if names && !names.empty?
              json.field "enabled_tools", names.map(&.as_s)
            end
          end
        end
      end

      # Appends the messages from a stored jsonb array column to `history`.
      # `column` is a `JSON::Any` that should be an array of message objects;
      # we re-parse through `Agent::Message.from_json` to keep types honest.
      private def self.append_messages(
        history : Array(Agent::Message),
        column : JSON::Any,
      ) : Nil
        return unless column.raw.is_a?(Array)

        column.as_a.each do |msg_raw|
          history << Agent::Message.from_json(msg_raw.to_json)
        end
      end
    end
  end
end
