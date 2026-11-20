# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "db"
require "../../database"
require "./auth"

module Facet
  module Assistant
    module DomainBuilder
      # Typed view of the `agent_conversations.context` jsonb column for a
      # domain-builder conversation.
      #
      # Stored as a jsonb string (not a separate table) — see
      # `doc/backend/agent-conversations.md` for the conversation schema.
      # The streaming route fetches the conversation, parses `context` via
      # `.from_conversation_context`, and — when it returns a `Context` —
      # wires the domain-builder tool registrar onto the `Agent`.
      struct Context
        KIND = "domain-builder"

        getter draft_domain : String
        getter? target_name : String?
        getter? description : String?
        getter created_by : String

        def initialize(
          @draft_domain : String,
          @target_name : String? = nil,
          @description : String? = nil,
          @created_by : String = "system:assistant",
        )
        end

        # Parses a domain-builder `Context` from the conversation's stored
        # `context` jsonb. Returns `nil` when the payload is absent or is not
        # a domain-builder conversation (e.g. a `general-assistance` one).
        #
        # This is pure JSON parsing — it does **not** verify that
        # `draft_domain` actually points at a draft domain. Callers that are
        # about to wire write tools must additionally call
        # `#verify_draft_domain?(db)` (see `Registrar.register` and
        # `Assistant::Routes#handle_stream`). The pair of checks together
        # prevent a forged `context` payload from granting the system-tier
        # assistant tools access to a production domain.
        def self.from_conversation_context(json : JSON::Any) : self?
          return nil unless json.as_h? && json["kind"]?.try(&.as_s?) == KIND

          draft = json["draft_domain"]?.try(&.as_s?)
          return nil if draft.nil? || draft.empty?

          new(
            draft_domain: draft,
            target_name: json["target_name"]?.try(&.as_s?),
            description: json["description"]?.try(&.as_s?),
            created_by: json["created_by"]?.try(&.as_s?) || Auth::ACCOUNT_ID,
          )
        end

        # Verifies that `draft_domain` actually points at a live `core.Domain`
        # projection whose `content->>'draft' = 'true'`. Returns `true` when
        # the draft exists and is marked as a draft, `false` otherwise (missing
        # projection, tombstoned, or not a draft).
        #
        # This is the trust boundary that elevates a stored `draft_domain`
        # string into an actually-draft domain. Without it, an attacker who
        # forges a `context` payload (e.g. via the generic conversation-create
        # route) pointing `draft_domain` at a production domain would bypass
        # all RBAC because the assistant runs with the system-tier
        # `AuthContext`.
        def verify_draft_domain?(db : DB::Connection) : Bool
          row = db.query_one?(
            "SELECT 1 FROM projections WHERE domain='core' AND doc_type='Domain' " \
            "AND id=$1 AND content->>'draft'='true' AND deleted_at IS NULL",
            @draft_domain,
            as: Int32?,
          )
          !row.nil?
        end

        # Serialises the context to a JSON string suitable for the
        # `agent_conversations.context` jsonb column.
        def to_json : String
          JSON.build do |json|
            json.object do
              json.field "kind", KIND
              json.field "draft_domain", @draft_domain
              json.field "target_name", @target_name if @target_name
              json.field "description", @description if @description
              json.field "created_by", @created_by
            end
          end
        end
      end
    end
  end
end
