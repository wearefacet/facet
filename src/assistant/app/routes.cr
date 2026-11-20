# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"

require "../../database"
require "../../http/helpers"
require "../../rbac"
require "../config"
require "../conversation"
require "../custom_prompt"
require "../language"
require "./context"
require "./gate"
require "./registrar"
require "./system_prompt"

module Facet
  module Assistant
    module App
      # HTTP route for the app-assistant conversation surface.
      #
      # Only `POST /Api/assistant/app/conversations` is implemented here —
      # the streaming endpoint is the same
      # `POST /Api/assistant/conversations/:id/stream` as for any other
      # conversation. The streaming route resolves the conversation kind
      # via `Context.from_conversation_context` and — on a hit — re-runs
      # the app gate on every message and wires the app registrar onto the
      # `Agent` (see `src/assistant/routes.cr#handle_stream`).
      #
      # The create route is gated in order: CSRF, authentication (`401`),
      # the app gate (`403`). The app id comes from the caller's token,
      # never from the body, so a main-app session user (no app token)
      # fails the gate. Every denial is a clean JSON response.
      module Routes
        # The HTTP route for creating an app conversation. Exposed as a
        # constant so the generic conversation-create handler can point at
        # it when it rejects a forged `context.kind = "app"` payload (see
        # `Assistant::Routes::RESERVED_CONTEXT_KINDS`).
        CREATE_ROUTE = "/Api/assistant/app/conversations"

        # Registers the app routes on the Kemal router.
        def self.register : Nil
          post CREATE_ROUTE do |env|
            handle_create(env)
          end
        end

        # ── Handler ───────────────────────────────────────────────

        private def self.handle_create(env) : Nil
          return unless Facet::HTTP::Helpers.require_csrf(env)

          # The body is validated as JSON. The one field the route reads is
          # `language` — the client's current language tag, baked into the
          # prompt as the `## Language` directive. Everything else stays
          # server-owned: the model, endpoint, system prompt, tool set, and
          # the conversation context (the kind, the owner, and the app id).
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

          # The app id is authentication data: the token names the app, the
          # body cannot. A caller without an app token — a main-app session
          # user — has no app to point at.
          app_id = auth_context.app_id
          unless app_id
            Facet::HTTP::Helpers.error_response(env, 403, "You do not have access to the app assistant")
            return
          end

          # Availability gate: the app must be live with the assistant
          # enabled, the token must name this app, and the active role must
          # hold `assistant_access`. The gate reads the app projection
          # live, so a disable applies on the next create. No conversation
          # row is written on denial.
          allowed = Facet::Database.with_db(:read_only) do |db|
            Gate.allowed?(db, auth_context, app_id)
          end
          unless allowed
            Facet::HTTP::Helpers.error_response(env, 403, "You do not have access to the app assistant")
            return
          end

          # The Session context fields read from the app projection live.
          # The gate proved the row exists above; a row that vanished
          # between the two reads fails closed — no conversation for a
          # ghost app.
          app_content = Facet::Database.with_db(:read_only) { |db| Gate.load_app(db, app_id) }
          unless app_content
            Facet::HTTP::Helpers.error_response(env, 403, "You do not have access to the app assistant")
            return
          end

          session_id = Facet::Util::ScriptHelpers.ulid
          cache_key = Facet::Util::ScriptHelpers.ulid

          # The backend owns the model, endpoint, system prompt, and tool
          # set. The context names the kind, the owner (always the
          # caller), and the app (always the token's app) — never a
          # request value.
          context = Context.new(created_by: account_id, app_id: app_id)

          result = Facet::Database.with_transaction do |db|
            Facet::Assistant::Conversation.create(
              db,
              session_id: session_id,
              cache_key: cache_key,
              # The custom-instructions setting is read inside the
              # transaction and baked into the row at create; later turns
              # reuse the stored prompt. The language directive comes from
              # the request body.
              system_prompt: SystemPrompt.build(
                display_name(app_content),
                active_role_name(auth_context),
                app_instructions: app_instructions(app_content),
                custom_instructions: CustomPrompt.block(db),
                language: request_language(parsed),
              ),
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

        # The app's display name. The field is required on the doctype;
        # a missing value falls back to the empty string.
        private def self.display_name(content : JSON::Any) : String
          content["name"]?.try(&.as_s?) || ""
        end

        # The app's own instructions (the `## App instructions` block
        # text). Absent appends nothing.
        private def self.app_instructions(content : JSON::Any) : String?
          content["assistant_prompt"]?.try(&.as_s?)
        end

        # The active role's name from the caller's token. An app-scoped
        # caller is always a real principal, so the fallback never fires.
        private def self.active_role_name(auth_context : RBAC::AuthContext) : String
          auth_context.principal.as?(RBAC::Principal::Real).try(&.active_role.role_id) || ""
        end

        # The language tag from the create body. `nil` when absent or not a
        # string — `Language.block` guards the value again.
        private def self.request_language(parsed : JSON::Any) : String?
          parsed["language"]?.try(&.as_s?)
        end

        # The account id the conversation is attributed to, or `nil` when
        # the request carries no real identity: the fail-closed denied
        # principal (`anonymous`). The system bypass is an internal caller
        # and passes this check — the app gate refuses it next (a bypass
        # principal cannot carry an app id).
        private def self.caller_account_id(auth_context : RBAC::AuthContext) : String?
          id = auth_context.account_id
          return nil if id.empty? || id == "anonymous"
          id
        end
      end
    end
  end
end
