# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../../database"
require "../../http/helpers"
# include "../../http/helpers"  # NOT needed; we use fully-qualified Helpers calls
require "../../rbac"
require "../../rbac/write_enforcer"
require "../../domain/draft"
require "../../event"
require "../../util/script_helpers"
require "../config"
require "../conversation"
require "./context"
require "./system_prompt"
require "./auth"
require "./tools"
require "../custom_prompt"
require "../language"

module Facet
  module Assistant
    module DomainBuilder
      # HTTP routes for the domain-builder conversation surface.
      #
      # Only `POST /Api/assistant/domain-builder/conversations` is implemented
      # here — the streaming endpoint is the same
      # `POST /Api/assistant/conversations/:id/stream` as for any other
      # conversation. The streaming route detects a domain-builder
      # conversation via `Context.from_conversation_context(conversation.context)`
      # (see `src/assistant/routes.cr#handle_stream`) and, on a hit, wires
      # the domain-builder tool registrar on the `Agent` before `ask`.
      module Routes
        # The HTTP route for creating a domain-builder conversation. Exposed
        # as a constant so the generic conversation-create handler can
        # reference it in the error message it emits when a client tries to
        # forge a `context.kind = "domain-builder"` payload via
        # `POST /Api/assistant/conversations`.
        CREATE_ROUTE = "/Api/assistant/domain-builder/conversations"

        # Registers the domain-builder routes on the Kemal router.
        def self.register : Nil
          post CREATE_ROUTE do |env|
            handle_create(env)
          end
        end

        # ── 1. Authorise the originating user ────────────────────────────
        #
        # The user is asking the assistant to create/update doctypes on their
        # behalf. Two authorisation shapes exist:
        #
        # - A real principal: the gate is "can this user write `core.DocType`
        #   AND `core.Domain`?" — the same permissions the editor/admin roles
        #   already carry.
        # - A preview-capability principal: while a preview session is active
        #   the frontend's `apiFetch` overlays the preview Bearer on every
        #   request, including this one, so the caller arrives as a
        #   `Principal::Preview` bound to one draft domain. The capability was
        #   issued only after the caller's real identity proved
        #   `update core.Domain` on that draft (the preview-session gate),
        #   which is a strictly stronger proof than re-running the role-based
        #   enforcers against a role-less principal — so the capability itself
        #   authorises the conversation. The conversation binds to the preview
        #   domain: a `draft_domain` that names any other domain is rejected,
        #   and an absent one binds to the token's draft (never a fresh draft
        #   creation — the preview session is bound to the draft it was issued
        #   for). The schema edits the tools make later still ride the
        #   system-tier registrar and stay attributed to `created_by`; the
        #   preview token itself remains data-only on the REST surface.
        #
        # Returns `{allowed, draft_domain}`: the draft domain the conversation
        # binds to (the caller's `draft_domain` for real principals — nil keeps
        # the fresh-draft creation path — or the token's preview domain for
        # preview callers), and `allowed: false` after writing the 403 response.
        private def self.authorize_caller(
          env,
          existing_draft : String?,
        ) : {Bool, String?}
          auth_context = Facet::HTTP::Helpers.auth_context(env)

          if preview_domain = auth_context.preview_domain
            requested = existing_draft
            if requested && requested != preview_domain
              env.response.status_code = 403
              env.response.print(Facet::HTTP::Helpers.json_error(403, "Forbidden: preview token is bound to draft '#{preview_domain}'"))
              return {false, nil}
            end
            return {true, preview_domain}
          end

          # Also need `write core.Domain` to create the draft domain.
          create_domain_ok = Facet::Database.with_db(:read_only) do |db|
            Facet::RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth_context)
          end
          create_doctype_ok = Facet::Database.with_db(:read_only) do |db|
            Facet::RBAC::WriteEnforcer.authorize_create(db, "core", "DocType", auth_context)
          end

          unless create_domain_ok && create_doctype_ok
            env.response.status_code = 403
            env.response.print(Facet::HTTP::Helpers.json_error(403, "Forbidden: requires write core.Domain and write core.DocType"))
            return {false, nil}
          end

          {true, existing_draft}
        end

        # ── Handler ───────────────────────────────────────────────

        private def self.handle_create(env) : Nil
          return unless Facet::HTTP::Helpers.require_csrf(env)

          body = Facet::HTTP::Helpers.require_body(env) || return
          parsed = Facet::HTTP::Helpers.parse_json_body(env, body) || return

          # All fields are advisory — they are interpolated into the system
          # prompt to give the model a sense of destination.
          target_name = parsed["target_name"]?.try(&.as_s?)
          description = parsed["description"]?.try(&.as_s?)

          # The user's current language tag, baked into the prompt as the
          # `## Language` directive.
          language = parsed["language"]?.try(&.as_s?)

          # When `draft_domain` is provided, the conversation is created
          # against an existing draft domain (lazy creation — the frontend's
          # builder mode creates drafts independently and asks for a
          # conversation on demand). When absent, a new empty draft domain
          # is created as part of this call (original behaviour).
          existing_draft = parsed["draft_domain"]?.try(&.as_s?)

          caller_allowed, existing_draft = authorize_caller(env, existing_draft)
          return unless caller_allowed
          auth_context = Facet::HTTP::Helpers.auth_context(env)

          session_id = Facet::Util::ScriptHelpers.ulid
          cache_key = Facet::Util::ScriptHelpers.ulid

          result = Facet::Database.with_transaction do |db|
            # ── 2. Resolve the draft domain ──────────────────────────
            #
            # If an existing draft_domain id was provided, verify it points
            # at a real draft domain projection before proceeding. This is
            # the same trust boundary that `Context#verify_draft_domain?`
            # enforces on the streaming path — a forged draft_domain id
            # must never reach the system-tier tool callbacks.
            draft_domain = if existing_draft
                             is_draft = db.query_one?(
                               "SELECT 1 FROM projections WHERE domain='core' AND doc_type='Domain' " \
                               "AND id=$1 AND content->>'draft'='true' AND deleted_at IS NULL",
                               existing_draft,
                               as: Int32?,
                             )
                             unless is_draft
                               next Facet::ServiceError.new(422, "draft_domain '#{existing_draft}' does not exist or is not a draft")
                             end
                             existing_draft
                           else
                             # `Domain::Draft.create` autogenerates the `_`-prefixed name
                             # and persists a `core.Domain` document with `draft:true`.
                             # We pass the user's account_id as the actioner so the audit
                             # log attributes the draft creation to the originating user.
                             draft_body = ({} of String => JSON::Any).to_json
                             draft_result = Facet::Domain::Draft.create(db, draft_body, auth_context.account_id)

                             case draft_result
                             in Facet::Domain::Draft::Result
                               draft_result.projection.id
                             in Facet::ServiceError
                               next draft_result
                             end
                           end

            # ── 3. Build the conversation context ─────────────────────
            context = Context.new(
              draft_domain: draft_domain,
              target_name: target_name,
              description: description,
              created_by: auth_context.account_id,
            )

            # ── 4. Build the system prompt (baked into the conversation) ─
            # The custom-instructions setting is read inside the
            # transaction and baked into the row at create; later turns
            # reuse the stored prompt. The language directive comes from
            # the request body.
            system_prompt = SystemPrompt.build(context, CustomPrompt.block(db), language)

            # ── 5. Create the conversation ──────────────────────────
            conversation_result = Facet::Assistant::Conversation.create(
              db,
              session_id: session_id,
              cache_key: cache_key,
              system_prompt: system_prompt,
              context: context.to_json,
              enabled_tools: Registrar::TOOL_NAMES.to_json,
            )

            # Tag on the draft domain name so the route can return it.
            case conversation_result
            in Facet::Assistant::Conversation::Result::Created
              conversation_result
            in Facet::ServiceError
              conversation_result
            end
          end

          # Flush events enqueued during draft domain creation.
          Facet::Event::Publisher.flush

          case result
          when Facet::Assistant::Conversation::Result::Created
            record = result.record
            env.response.status_code = 201
            env.response.print({data: Facet::Assistant::Conversation.api_hash(record)}.to_json)
          when Facet::ServiceError
            Facet::HTTP::Helpers.error_response(env, result.status, result.message)
          else
            # Unreachable — the transaction's result union narrows above.
            Facet::HTTP::Helpers.error_response(env, 500, "Unexpected result type")
          end
        end
      end
    end
  end
end
