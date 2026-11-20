# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"

require "../../database"
require "../../http/helpers"
require "../../rbac"
require "../config"
require "../conversation"
require "./context"
require "./registrar"
require "./system_prompt"
require "../custom_prompt"
require "../language"

module Facet
  module Assistant
    module Workspace
      # HTTP route for the workspace conversation surface.
      #
      # `POST /Api/assistant/workspace/conversations` creates the
      # conversation — the streaming endpoint is the same
      # `POST /Api/assistant/conversations/:id/stream` as for any other
      # conversation. The streaming route resolves the conversation kind
      # via `Context.from_conversation_context`, runs the workspace access
      # gate, and wires the workspace registrar onto the `Agent` (see
      # `src/assistant/routes.cr#handle_stream`).
      #
      # Reads have no workspace path of their own: the shared conversation
      # routes own them (`GET /Api/assistant/conversations/:id`). The GET
      # route below exists only to keep the conversation path away from the
      # REST catch-all: the catch-all reads `assistant.workspace` as a
      # document doctype and answers `404 "Unknown doctype:
      # assistant.workspace"` — a body that leaks resolution internals.
      # This route answers the standard opaque `404 "Not found"` instead.
      #
      # The create route is gated twice: unauthenticated callers get a 401,
      # and any authenticated caller whose held roles do not enable the
      # assistant gets a 403 before any row is written (see
      # `Assistant::Access`).
      module Routes
        # The HTTP route for creating a workspace conversation. Exposed as
        # a constant so the generic conversation-create handler can point
        # at it when it rejects a forged `context.kind = "workspace"`
        # payload (see `Assistant::Routes::RESERVED_CONTEXT_KINDS`).
        CREATE_ROUTE = "/Api/assistant/workspace/conversations"

        # Registers the workspace routes on the Kemal router.
        def self.register : Nil
          post CREATE_ROUTE do |env|
            handle_create(env)
          end

          # Static route segments win over the REST catch-all's path
          # parameters, so this opaque 404 answers before the catch-all can
          # resolve `assistant.workspace` as a document doctype.
          get "#{CREATE_ROUTE}/:id" do |env|
            Facet::HTTP::Helpers.error_response(env, 404, "Not found")
          end
        end

        # ── Handler ───────────────────────────────────────────────

        private def self.handle_create(env) : Nil
          return unless Facet::HTTP::Helpers.require_csrf(env)

          # The body is validated as JSON. The one field the route reads is
          # `language` — the client's current language tag, baked into the
          # prompt as the `## Language` directive. Everything else stays
          # server-owned: the model, endpoint, system prompt, tool set, and
          # the conversation context (the kind and the owner, who is always
          # the caller — never a request-supplied value).
          body = Facet::HTTP::Helpers.require_body(env) || return
          parsed = Facet::HTTP::Helpers.parse_json_body(env, body) || return

          auth_context = Facet::HTTP::Helpers.auth_context(env)

          # Unauthenticated callers get 401, not 403 — the gate below
          # answers an authorization question, and the denied principal
          # fails closed there anyway.
          account_id = caller_account_id(auth_context)
          unless account_id
            Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
            return
          end

          # Availability gate: at least one held role must carry
          # `assistant_access`. No conversation row is written on denial.
          allowed = Facet::Database.with_db(:read_only) do |db|
            Access.allowed?(db, auth_context)
          end
          unless allowed
            Facet::HTTP::Helpers.error_response(env, 403,
              "You do not have access to the workspace assistant")
            return
          end

          session_id = Facet::Util::ScriptHelpers.ulid
          cache_key = Facet::Util::ScriptHelpers.ulid

          # The backend owns the model, endpoint, system prompt, and tool
          # set — the frontend is a pure consumer. The context names the
          # kind and the owner; the owner never comes from the request.
          context = Context.new(created_by: account_id)

          result = Facet::Database.with_transaction do |db|
            Facet::Assistant::Conversation.create(
              db,
              session_id: session_id,
              cache_key: cache_key,
              # The custom-instructions setting is read inside the
              # transaction and baked into the row at create; later turns
              # reuse the stored prompt. The language directive comes from
              # the request body.
              system_prompt: SystemPrompt.build(CustomPrompt.block(db), request_language(parsed)),
              context: context.to_json,
              enabled_tools: Registrar.tool_names.to_json,
            )
          end

          case result
          when Facet::Assistant::Conversation::Result::Created
            env.response.status_code = 201
            env.response.print({data: Facet::Assistant::Conversation.api_hash(result.record)}.to_json)
          when Facet::ServiceError
            Facet::HTTP::Helpers.error_response(env, result.status, result.message)
          else
            # Unreachable — the transaction's result union narrows above.
            Facet::HTTP::Helpers.error_response(env, 500, "Unexpected result type")
          end
        end

        # ── Helpers ───────────────────────────────────────────────

        # The language tag from the create body. `nil` when absent or not a
        # string — `Language.block` guards the value again.
        private def self.request_language(parsed : JSON::Any) : String?
          parsed["language"]?.try(&.as_s?)
        end

        # The account id the conversation is attributed to, or `nil` when
        # the request carries no real identity: the fail-closed denied
        # principal (`anonymous`). The system bypass is an internal caller
        # and passes.
        private def self.caller_account_id(auth_context : RBAC::AuthContext) : String?
          id = auth_context.account_id
          return nil if id.empty? || id == "anonymous"
          id
        end
      end
    end
  end
end
