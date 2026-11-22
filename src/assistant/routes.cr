# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../config"
require "../database"
require "../http/helpers"
require "../http/list_request"
require "../rbac/auth_context"
require "../util/script_helpers"
require "./conversation"
require "./access"
require "./limits"
require "./language"
require "./usage"
require "../system_settings"
require "./stream/cancel_bus"
require "./stream/session"
require "./turn"
require "./domain_builder/context"
require "./domain_builder/tools"
require "./domain_builder/routes"
require "./app/context"
require "./app/gate"
require "./app/registrar"
require "./app/routes"

module Facet
  module Assistant
    # HTTP routes for the assistant conversation storage subsystem.
    #
    # All routes live under `/Api/assistant/...`. They are pure CRUD over the
    # persistence layer (`Conversation`, `Turn`) — they do **not** call live
    # LLMs. Higher-level orchestration that wraps `Agent#ask` and persists the
    # resulting turn is a separate concern and lives elsewhere.
    #
    # These routes are a virtual namespace (like `/Api/Audit`, `/Api/iam`)
    # — they are not domain-scoped and bypass `DomainGate` via the explicit
    # carve-out added in `HTTP::Server`.
    module Routes
      Log = ::Log.for("facet.assistant.routes")

      DEFAULT_ITEMS = 100

      # Conversation kinds that own a dedicated creation route and carry an
      # owner in `context.created_by`. The generic create route rejects them
      # (allowing a client to forge the context would let a crafted payload
      # slip past the gate the dedicated route enforces), and the read
      # surfaces (get / stream / list) scope them to the owner. The map
      # value is the creation route the error message points at. The
      # workspace entry is the route the workspace surface registers; the
      # app entry is the chat package's route.
      RESERVED_CONTEXT_KINDS = {
        DomainBuilder::Context::KIND => DomainBuilder::Routes::CREATE_ROUTE,
        "workspace"                  => "/Api/assistant/workspace/conversations",
        App::Context::KIND           => App::Routes::CREATE_ROUTE,
      }

      # Registers all assistant routes on the Kemal router.
      def self.register : Nil
        register_conversation_routes
        register_turn_routes
        register_stream_routes
        register_usage_route
      end

      # ── Usage route ────────────────────────────────────────────────

      private def self.register_usage_route : Nil
        get "/Api/assistant/usage" do |env|
          handle_usage(env)
        end
      end

      # Token-usage meter for the assistant window: the caller's
      # rolling-window total (`Limits::WINDOW_DAYS`), the estimated part of
      # it, and the effective budget (`Access.effective_budget`) from one
      # ledger query and one budget aggregation. `estimated_total` is the
      # part of `total` the provider never reported on (a character-count
      # guess), so the meter can mark the number as an estimate.
      # `budget: null` means unlimited — the frontend hides the meter.
      # Authenticated callers only: the system bypass and the anonymous
      # principal carry no billable account, so they answer 401 like any
      # authenticated-only surface.
      private def self.handle_usage(env) : Nil
        account_id = billable_account_id(Facet::HTTP::Helpers.auth_context(env))
        unless account_id
          Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
          return
        end

        window_start = Time.utc - Limits::WINDOW_DAYS.days
        result = Database.with_db(:read_only) do |db|
          {
            totals: Usage.total_for_account(db, account_id, since: window_start),
            budget: Access.effective_budget(db, account_id),
          }
        end

        Facet::HTTP::Helpers.write_json(env, 200, {
          total:           result[:totals].total,
          estimated_total: result[:totals].estimated_total,
          budget:          result[:budget],
          window_start:    window_start.to_rfc3339,
          window_days:     Limits::WINDOW_DAYS,
        })
      end

      # ── Conversation routes ───────────────────────────────────────────

      private def self.register_conversation_routes : Nil
        # Create a conversation: POST /Api/assistant/conversations
        post "/Api/assistant/conversations" do |env|
          handle_create_conversation(env)
        end

        get "/Api/assistant/conversations" do |env|
          handle_list_conversations(env)
        end

        query "/Api/assistant/conversations" do |env|
          handle_query_list_conversations(env)
        end

        # Fetch a conversation: GET /Api/assistant/conversations/:id
        get "/Api/assistant/conversations/:id" do |env|
          handle_get_conversation(env)
        end

        # Archive / unarchive a conversation: PATCH /Api/assistant/conversations/:id
        patch "/Api/assistant/conversations/:id" do |env|
          handle_update_conversation(env)
        end
      end

      # ── Conversation handlers ───────────────────────────────────────────

      private def self.handle_create_conversation(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        body = Facet::HTTP::Helpers.require_body(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_body(env, body) || return

        # The backend owns the model, endpoint, and system prompt — they come
        # from the effective runtime settings. The prompt is captured at
        # create and stays on the conversation row; the connection resolves
        # live at every turn start. The frontend is a pure consumer and can
        # only supply `context` and `enabled_tools`
        session_id = Util::ScriptHelpers.ulid
        cache_key = Util::ScriptHelpers.ulid

        context_json = field_as_json_string(parsed, "context") || "{}"
        enabled_tools_json = field_as_json_string(parsed, "enabled_tools") || "[]"

        # The user's current language tag, baked into the prompt as the
        # `## Language` directive after the setting text.
        language = parsed["language"]?.try(&.as_s?)

        # Reserved `kind` values (see `RESERVED_CONTEXT_KINDS`) correspond
        # to conversation surfaces with a dedicated creation route that
        # builds the surrounding state (e.g. `DomainBuilder::Routes`
        # creates a real draft `core.Domain` and enforces RBAC on
        # `write core.Domain` + `write core.DocType` before persisting the
        # conversation context). Allowing a client to forge a context with
        # these kinds via the generic route would let a
        # `(kind:"domain-builder", draft_domain:"hr")` payload slip past
        # CBAC, or a `(kind:"workspace", created_by:"someone-else")`
        # payload claim another account's identity. Reject the request up
        # front — the client must use the dedicated route.
        if kind = reserved_context_kind(context_json)
          Facet::HTTP::Helpers.error_response(env, 422,
            "Conversations with context.kind='#{kind}' must go through #{RESERVED_CONTEXT_KINDS[kind]}")
          return
        end

        result = Database.with_transaction do |db|
          system_prompt = Facet::SystemSettings.string_at(db, "assistant.system_prompt")
          if language_block = Language.block(language)
            system_prompt = system_prompt ? "#{system_prompt}\n\n#{language_block}" : language_block
          end
          Conversation.create(
            db,
            session_id: session_id,
            cache_key: cache_key,
            system_prompt: system_prompt,
            context: context_json,
            enabled_tools: enabled_tools_json,
          )
        end

        case result
        in Conversation::Result::Created
          Facet::HTTP::Helpers.write_json(env, 201, {data: Conversation.api_hash(result.record)})
        in Facet::ServiceError
          Facet::HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      private def self.handle_list_conversations(env) : Nil
        list_req = Facet::HTTP::Helpers.get_list_request(env) || return
        render_conversations(env, list_req)
      end

      private def self.handle_query_list_conversations(env) : Nil
        list_req = Facet::HTTP::Helpers.query_list_request(env) || return
        render_conversations(env, list_req)
      end

      private def self.render_conversations(env, list_req) : Nil
        Facet::HTTP::Helpers.accept_query(env)
        scope_list_to_owner(list_req.filters, Facet::HTTP::Helpers.auth_context(env))
        offset = (list_req.page - 1) * list_req.items

        rows = Database.with_db(:read_only) do |db|
          Conversation.list(db, filters: list_req.filters, sort: list_req.sort, items: list_req.items, offset: offset)
        end

        total_capped = Database.with_db(:read_only) { |db| Conversation.count(db, list_req.filters, offset) }

        # One batch read backs every row's `active` flag — the running-turn
        # set is tiny (at most one row per generating conversation).
        active_ids = Database.with_db(:read_only) { |db| Turn.running_conversation_ids(db) }

        # `count` is the real number from this page's offset, truncated at
        # the shared cap; `more` is true only when counting was truncated.
        count = total_capped > Facet::HTTP::Responders::COUNT_CAP ? offset + Facet::HTTP::Responders::COUNT_CAP : offset + total_capped
        more = total_capped > Facet::HTTP::Responders::COUNT_CAP

        Facet::HTTP::Helpers.write_json(env, 200, {
          data: rows.map { |record| Conversation.api_hash(record, active_ids.includes?(record.id)) },
          meta: {count: count, more: more},
        })
      end

      private def self.handle_get_conversation(env) : Nil
        result = Database.with_db(:read_only) do |db|
          Conversation.find(db, env.params.url["id"])
        end

        if record = result
          return unless ownership_check(env, record)

          active = Database.with_db(:read_only) { |db| Turn.running?(db, record.id) }
          Facet::HTTP::Helpers.write_json(env, 200, {data: Conversation.api_hash(record, active)})
        else
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
        end
      end

      # Archives or unarchives a conversation. The body is `{archived: true|false}`
      # — `true` stamps `archived_at`, `false` clears it. Archiving is a
      # list-organisation state only: the conversation stays readable and
      # streamable, and its next turn clears the flag (`Conversation.unarchive`
      # from the turn writers). Owner-gated like every other single-conversation
      # surface.
      private def self.handle_update_conversation(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        id = env.params.url["id"]
        body = Facet::HTTP::Helpers.require_body(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_body(env, body) || return

        archived = parsed["archived"]?.try(&.as_bool?)
        if archived.nil?
          Facet::HTTP::Helpers.error_response(env, 422, "Field 'archived' must be a boolean")
          return
        end

        record = Database.with_db(:read_only) do |db|
          Conversation.find(db, id)
        end
        unless record
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
          return
        end
        return unless ownership_check(env, record)

        updated = Database.with_db do |db|
          next nil unless Conversation.set_archived(db, id, archived)
          Conversation.find(db, id)
        end

        if updated
          active = Database.with_db(:read_only) { |db| Turn.running?(db, updated.id) }
          Facet::HTTP::Helpers.write_json(env, 200, {data: Conversation.api_hash(updated, active)})
        else
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
        end
      end

      # ── Stream routes ─────────────────────────────────────────────────────

      private def self.register_stream_routes : Nil
        # SSE streaming endpoint: POST /Api/assistant/conversations/:id/stream
        post "/Api/assistant/conversations/:id/stream" do |env|
          handle_stream(env)
        end

        # Cancel an in-flight streaming turn: POST /Api/assistant/cancel/:turn_token
        post "/Api/assistant/cancel/:turn_token" do |env|
          handle_cancel(env)
        end
      end

      # ── Stream handlers ─────────────────────────────────────────────────────

      # Runs a streaming turn against `Agent`, writing SSE events to the
      # response. The response is flushed per-event and closed at the end.
      # Conversation existence is validated BEFORE setting SSE headers so a
      # 404 is a clean JSON response (once SSE headers are flushed we can't
      # switch to JSON).
      private def self.handle_stream(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        conversation_id = env.params.url["id"]
        body = Facet::HTTP::Helpers.require_body(env)
        return if body.nil?

        parsed = Facet::HTTP::Helpers.parse_json_body(env, body)
        return if parsed.nil?

        payload = extract_stream_payload(env, parsed)
        return unless payload
        content, attachments = payload

        db_context = Database.with_db do |db|
          Conversation.find(db, conversation_id)
        end
        unless db_context
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
          return
        end

        # Ownership, context-kind, workspace-access, app-access, and
        # usage-limit gates. All run before the SSE headers so any denial
        # is a clean JSON response.
        gate = stream_context_gates(env, db_context)
        return unless gate

        # One running turn per conversation — enforced by the partial unique
        # index `idx_agent_turns_one_running`. The open runs before the SSE
        # headers so a conflicting request is a clean 409 JSON, not a stream
        # error. The inserted row also makes the turn observable for the
        # whole generation: the conversation `active` flag, the frontend
        # catch-up poll, and the stale-row sweep all read it. Returns nil
        # when the response was already written (conflict or database error).
        #
        # The cancel token is generated here — before the open — and shared
        # by the row and the session, so a client that reloads mid-turn can
        # read the token back from the turns API and still cancel.
        turn_token = Util::ScriptHelpers.ulid
        turn_id = open_stream_turn(env, conversation_id, content, turn_token)
        return unless turn_id

        write_sse_headers(env)

        redis_url = Facet::Config.instance.event.url
        cancel_ttl = Facet::Config.instance.assistant.cancel_ttl_seconds

        Database.with_db do |db|
          session = Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: content,
            attachments: attachments,
            account_id: gate[:caller_id],
            tool_registrar: build_tool_registrar(db, gate[:builder_context], gate[:workspace_context], gate[:app_context], gate[:auth_ctx]),
            argument_tools: ui_tool_names(gate[:builder_context], gate[:workspace_context]),
            turn_token: turn_token,
          )
          session.run(env.response, redis_url, cancel_ttl, turn_id)
        end

        # The socket can die after the last guarded write in the session.
        # The terminating chunk inside close then raises a raw `IO::Error`
        # — or, on a TLS-terminated listener, `OpenSSL::SSL::Error` from
        # `SSL_shutdown`/`SSL_write` (no `IO::Error` subclass, so the guard
        # names it too). A transport fact, not a turn failure (see
        # `guarded_write` in `Stream::Session`). The rescue logs at DEBUG
        # and sends no error response, so a normal tab close does not log
        # a 500.
        begin
          env.response.close
        rescue IO::Error | ::HTTP::Server::ClientError | OpenSSL::SSL::Error
          Log.debug { "Assistant SSE client disconnected during response close" }
        end
      end

      # Extracts the required `content` string and the optional
      # `attachments` array from a parsed stream body. Writes the 422
      # response and returns nil when `content` is missing or not a string.
      private def self.extract_stream_payload(env, parsed : JSON::Any) : {String, Array(String)?}?
        content_raw = required_field(env, parsed, "content")
        return if content_raw.nil?
        content = content_raw.as_s?
        unless content
          reject_missing_field(env, "content")
          return
        end

        attachments = parsed["attachments"]?.try do |arr|
          arr.as_a.map(&.as_s)
        end

        {content, attachments}
      end

      # Runs the pre-SSE gates for a stream request, in order: ownership,
      # domain-builder context verification, workspace access, app access,
      # and the usage-limit seam. Each gate writes its own JSON error before
      # the SSE headers are flushed, so a denial stays a clean JSON
      # response. Returns the gate outputs the session setup needs, or nil
      # when a gate rejected the request.
      private def self.stream_context_gates(env, db_context : Conversation::Record)
        return unless ownership_check(env, db_context)

        # Detect a domain-builder conversation via the `context` jsonb.
        # If it parses as a domain-builder `Context`, verify that its
        # `draft_domain` actually points at a draft `core.Domain` projection
        # before wiring the registrar. A forged context payload (e.g. one
        # persisted via the generic conversation-create route before that
        # route started rejecting `kind: "domain-builder"`) could name a
        # production domain as `draft_domain` and the system-tier assistant
        # tools would then mutate it. The verifier returns 403 from the
        # stream before SSE headers are written so the request fails as a
        # clean JSON error.
        builder_context = DomainBuilder::Context.from_conversation_context(db_context.context)
        return unless verify_builder_context(env, builder_context)

        # Second kind: workspace. The conversation's context names the
        # owner (`created_by`, checked above); the caller must additionally
        # hold a role with `assistant_access`. The gate re-runs on every
        # stream, so a role flip between turns applies on the next message.
        auth_ctx = Facet::HTTP::Helpers.auth_context(env)
        workspace_context = builder_context ? nil : Workspace::Context.from_conversation_context(db_context.context)
        return unless workspace_access_allowed?(env, workspace_context)

        # Third kind: app. The conversation's context names the owner and
        # the app; the gate re-reads the app projection on every message
        # (a disable applies on the next message) and requires the caller's
        # token to name the same app, so every tool call inherits the app's
        # grant ceiling.
        app_context = (builder_context || workspace_context) ? nil : App::Context.from_conversation_context(db_context.context)
        return unless app_gate_allowed?(env, app_context)

        # Usage-limit seam. The system bypass and the anonymous fail-closed
        # principal carry no billable account — the check skips them.
        caller_id = billable_account_id(auth_ctx)
        if caller_id
          allowed = Database.with_db(:read_only) { |db| Limits.allow?(db, caller_id) }
          unless allowed
            Facet::HTTP::Helpers.error_response(env, 429, "Assistant usage limit reached")
            return
          end
        end

        {
          builder_context:   builder_context,
          workspace_context: workspace_context,
          app_context:       app_context,
          auth_ctx:          auth_ctx,
          caller_id:         caller_id,
        }
      end

      # Builds the tool registrar for the conversation kind: the builder,
      # the workspace, and the app surface each register their own tool set.
      private def self.build_tool_registrar(db, builder_context, workspace_context, app_context, auth_ctx)
        if builder_ctx = builder_context
          ->(agent : Agent) { DomainBuilder::Registrar.register(agent, db, builder_ctx) }
        elsif workspace_ctx = workspace_context
          ->(agent : Agent) { Workspace::Registrar.register(agent, db, workspace_ctx, auth_ctx) }
        elsif app_context
          ->(agent : Agent) { App::Registrar.register(agent, auth_ctx) }
        else
          ->(_agent : Agent) { }
        end
      end

      # UI tools are registered per conversation kind, so their raw
      # arguments are only forwarded there: the builder surfaces
      # `preview_view` / `go_to_page`, the workspace surface
      # `navigate` / `show_documents`. The app kind mounts no UI tools —
      # its set stays empty.
      private def self.ui_tool_names(builder_context, workspace_context) : Set(String)
        if builder_context
          DomainBuilder::Registrar::UI_TOOL_NAMES.to_set
        elsif workspace_context
          Workspace::Registrar::UI_TOOL_NAMES.to_set
        else
          Set(String).new
        end
      end

      # One running turn per conversation — enforced by the partial unique
      # index `idx_agent_turns_one_running`. The open runs before the SSE
      # headers so a conflicting request is a clean 409 JSON, not a stream
      # error. The inserted row also makes the turn observable for the
      # whole generation: the conversation `active` flag, the frontend
      # catch-up poll, and the stale-row sweep all read it. Returns nil when
      # the response was already written (conflict or database error).
      private def self.open_stream_turn(env, conversation_id : String, content : String, turn_token : String) : String?
        open_result = Database.with_db do |db|
          Turn.open(db, conversation_id, Stream::Session.request_messages_json(content), turn_token)
        end

        case open_result
        when Turn::Result::Created
          open_result.record.id
        when Turn::Result::Conflict
          Facet::HTTP::Helpers.error_response(
            env, 409, "Another assistant turn is already running for this conversation")
          nil
        when Facet::ServiceError
          Facet::HTTP::Helpers.error_response(env, open_result.status, open_result.message)
          nil
        end
      end

      private def self.handle_cancel(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        turn_token = env.params.url["turn_token"]
        redis_url = Facet::Config.instance.event.url
        cancel_ttl = Facet::Config.instance.assistant.cancel_ttl_seconds

        Stream::CancelBus.publish(turn_token, redis_url, cancel_ttl)

        Facet::HTTP::Helpers.write_json(env, 200, {cancelled: true})
      end

      # Writes the SSE response headers. Must run before the first flush so
      # nginx (and the client) treat the connection as a streaming event
      # source. `X-Accel-Buffering: no` disables nginx proxy buffering.
      private def self.write_sse_headers(env) : Nil
        env.response.status_code = 200
        env.response.content_type = "text/event-stream"
        env.response.headers["Cache-Control"] = "no-cache"
        env.response.headers["Connection"] = "keep-alive"
        env.response.headers["X-Accel-Buffering"] = "no"
      end

      # ── Turn routes ──────────────────────────────────────────────────

      private def self.register_turn_routes : Nil
        # List turns of a conversation: GET /Api/assistant/conversations/:id/turns
        get "/Api/assistant/conversations/:id/turns" do |env|
          handle_list_turns(env)
        end

        # Latest turn summary for the catch-up poll:
        # GET /Api/assistant/conversations/:id/turns/latest
        get "/Api/assistant/conversations/:id/turns/latest" do |env|
          handle_latest_turn(env)
        end

        # Record a turn: POST /Api/assistant/conversations/:id/turns
        post "/Api/assistant/conversations/:id/turns" do |env|
          handle_create_turn(env)
        end
      end

      # ── Turn handlers ─────────────────────────────────────────────────

      private def self.handle_list_turns(env) : Nil
        conversation_id = env.params.url["id"]

        record = Database.with_db(:read_only) do |db|
          Conversation.find(db, conversation_id)
        end
        unless record
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
          return
        end

        # Turns carry the conversation's replay context — the same owner
        # gate as the get / stream / list surfaces applies.
        return unless ownership_check(env, record)

        rows = Database.with_db(:read_only) do |db|
          Turn.list(db, conversation_id)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {
          data: rows.map { |row| turn_hash(row) },
          meta: {count: rows.size, more: false},
        })
      end

      # Latest turn summary — the catch-up poll's endpoint. Returns the
      # last row (by idx) with its message payloads, so a client whose
      # stream broke can learn whether the in-flight turn reached its
      # terminal state cheaply — one row, never the whole thread — and
      # render the running turn's checkpointed partial exchange while it
      # keeps generating. Same owner gate as the list surface; `data` is
      # null for a conversation that has no turns yet.
      private def self.handle_latest_turn(env) : Nil
        conversation_id = env.params.url["id"]

        record = Database.with_db(:read_only) do |db|
          Conversation.find(db, conversation_id)
        end
        unless record
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
          return
        end

        return unless ownership_check(env, record)

        summary = Database.with_db(:read_only) do |db|
          Turn.latest(db, conversation_id)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {data: summary.nil? ? nil : {
          id:                summary.id,
          idx:               summary.idx,
          status:            summary.status,
          finish_reason:     summary.finish_reason,
          error:             summary.error,
          turn_token:        summary.turn_token,
          created_at:        summary.created_at,
          request_messages:  summary.request_messages,
          response_messages: summary.response_messages,
        }})
      end

      private def self.handle_create_turn(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        conversation_id = env.params.url["id"]
        body = Facet::HTTP::Helpers.require_body(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_body(env, body) || return

        # Gates before payload validation: an unknown id is a clean 404,
        # a non-owner of a reserved-kind conversation gets the same 403
        # as on every other read/write surface. Without the gate a caller
        # could inject turns into another account's replay context.
        record = Database.with_db do |db|
          Conversation.find(db, conversation_id)
        end
        unless record
          Facet::HTTP::Helpers.error_response(env, 404, "Conversation not found")
          return
        end
        return unless ownership_check(env, record)

        request_messages = required_json_field(env, parsed, "request_messages") || return
        response_messages = required_json_field(env, parsed, "response_messages") || return
        usage_json = required_json_field(env, parsed, "usage") || return

        finish_reason = parsed["finish_reason"]?.try(&.as_s?)
        error = parsed["error"]?.try(&.as_s?)

        result = Database.with_transaction do |db|
          Turn.create(
            db,
            conversation_id: conversation_id,
            request_messages_json: request_messages,
            response_messages_json: response_messages,
            usage_json: usage_json,
            finish_reason: finish_reason,
            error: error,
          )
        end

        case result
        in Turn::Result::Created
          Facet::HTTP::Helpers.write_json(env, 201, {data: turn_hash(result.record)})
        in Facet::ServiceError
          Facet::HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # ── Helpers ──────────────────────────────────────────

      # The billable account of the request's auth context, or `nil` when
      # the usage ledger cannot attribute the caller: the system bypass,
      # the fail-closed anonymous principal, or an empty identity.
      private def self.billable_account_id(ac : RBAC::AuthContext) : String?
        return nil if ac.system?

        id = ac.account_id
        return nil if id.empty? || id == "anonymous"
        id
      end

      # Extracts a required field, writing a 422 error when the key is
      # absent. Callers narrow the value (`.as_s?`, `.to_json`) to keep
      # their own type contract.
      private def self.required_field(env, parsed : JSON::Any, key : String) : JSON::Any?
        value = parsed[key]?
        reject_missing_field(env, key) if value.nil?
        value
      end

      # Writes the standard missing/invalid-field 422 response.
      private def self.reject_missing_field(env, key : String) : Nil
        Facet::HTTP::Helpers.error_response(env, 422, "Missing or invalid '#{key}' field")
      end

      # Serialises an optional JSON object/array field to a JSON string.
      # Returns nil if the field is absent (caller supplies a default).
      private def self.field_as_json_string(parsed : JSON::Any, key : String) : String?
        value = parsed[key]?
        return nil if value.nil?
        value.to_json
      end

      # Returns the reserved kind carried by the given context JSON string,
      # or `nil` when the context is absent, malformed, or names a
      # non-reserved kind. Used by the generic conversation-create route to
      # reject forgery attempts (see `RESERVED_CONTEXT_KINDS`). Malformed
      # JSON returns `nil` — the conversation layer will surface its own
      # 422 later.
      private def self.reserved_context_kind(context_json : String) : String?
        kind = conversation_kind(JSON.parse(context_json))
        return nil unless kind
        RESERVED_CONTEXT_KINDS.has_key?(kind) ? kind : nil
      rescue JSON::Error
        nil
      end

      # The top-level `kind` of a conversation context JSON value, or `nil`
      # when it is not an object with a string `kind`.
      private def self.conversation_kind(context : JSON::Any) : String?
        return nil unless hash = context.as_h?
        hash["kind"]?.try(&.as_s?)
      end

      # The caller identity an ownership check applies to, or `nil` for the
      # principals that bypass it: the system bypass and the fail-closed
      # anonymous principal (which carries no real account id).
      private def self.owning_caller_id(ac : RBAC::AuthContext) : String?
        return nil if ac.system?

        id = ac.account_id
        return nil if id.empty? || id == "anonymous"
        id
      end

      # Ownership gate for the read surfaces (get / stream). A conversation
      # whose context names a reserved kind (see `RESERVED_CONTEXT_KINDS`)
      # carries an owner in `context.created_by` — only that account (or
      # the system bypass) may read it. A missing or non-string owner fails
      # closed: the caller is treated as not the owner. Writes its own 403
      # JSON, so handlers do `return unless ownership_check(env, record)`.
      private def self.ownership_check(env, record : Conversation::Record) : Bool
        kind = conversation_kind(record.context)
        return true unless kind && RESERVED_CONTEXT_KINDS.has_key?(kind)

        caller_id = owning_caller_id(Facet::HTTP::Helpers.auth_context(env))
        return true if caller_id.nil?

        owner = record.context.as_h?.try { |h| h["created_by"]?.try(&.as_s?) }
        return true if owner && owner == caller_id

        Facet::HTTP::Helpers.error_response(env, 403, "You do not have access to this conversation")
        false
      end

      # Scopes list requests of a real principal to the caller. The system
      # bypass and the fail-closed anonymous principal list unrestricted.
      # Otherwise the caller reads only rows it owns:
      #
      # - a list that names a reserved kind (`context.kind__eq`) is forced
      #   onto `context.created_by__eq` — the client
      #   cannot read another account's conversations by omitting or forging
      #   the owner filter —
      # - a list that names no kind is scoped the same way; unscoped, it
      #   would return every account's rows,
      # - a non-reserved kind stays shared (no forcing): such conversations
      #   carry no ACL, the kind filter is the contract.
      #
      # The kind filter and the forced owner filter AND-combine:
      # `Conversation.list` merges both into one jsonb containment clause.
      private def self.scope_list_to_owner(filters : Hash(String, JSON::Any), ac : RBAC::AuthContext) : Nil
        caller_id = owning_caller_id(ac)
        return if caller_id.nil?

        kind = filters["context.kind__eq"]?.try(&.as_s?)
        return if kind && !RESERVED_CONTEXT_KINDS.has_key?(kind)

        filters["context.created_by__eq"] = JSON::Any.new(caller_id)
      end

      # Extracts a required JSON object/array field and serialises it to a
      # JSON string. Writes 422 if the field is missing.
      private def self.required_json_field(env, parsed : JSON::Any, key : String) : String?
        required_field(env, parsed, key).try(&.to_json)
      end

      # Serialises a turn record to a JSON-ready NamedTuple. `turn_token`
      # reaches the client so a reloaded surface can re-arm the cancel
      # button against a still-running turn.
      private def self.turn_hash(record : Turn::Record)
        {
          id:                record.id,
          conversation_id:   record.conversation_id,
          idx:               record.idx,
          request_messages:  record.request_messages,
          response_messages: record.response_messages,
          status:            record.status,
          usage:             record.usage,
          finish_reason:     record.finish_reason,
          error:             record.error,
          turn_token:        record.turn_token,
          created_at:        record.created_at,
        }
      end

      # Verifies that the given domain-builder `Context`'s `draft_domain`
      # actually points at a draft `core.Domain` projection. Spelled as a
      # module-level helper so the `if ctx = builder_context` narrowing in
      # `handle_stream` survives the closure capture inside
      # `Database.with_db`.
      private def self.verify_draft_domain_with_db(ctx : DomainBuilder::Context) : Bool
        Database.with_db { |db| ctx.verify_draft_domain?(db) }
      end

      # Draft-domain gate for a domain-builder stream. Returns `true` when
      # the stream may continue; on denial writes the 403 JSON and returns
      # `false`. Non-domain-builder conversations pass untouched.
      private def self.verify_builder_context(env, builder_context : DomainBuilder::Context?) : Bool
        ctx = builder_context || return true
        return true if verify_draft_domain_with_db(ctx)

        Facet::HTTP::Helpers.error_response(
          env, 403,
          "Conversation context references a draft domain that does not exist or is not a draft")
        false
      end

      # Availability gate for a workspace stream: the caller must hold at
      # least one role with `assistant_access` (`Assistant::Access`). The
      # conversation's owner check already ran (`ownership_check`); this
      # gate answers the separate question of whether the account may use
      # the workspace assistant at all. Returns `true` when the stream may
      # continue; on denial writes the 403 JSON and returns `false`.
      # Non-workspace conversations pass untouched.
      private def self.workspace_access_allowed?(env, workspace_context : Workspace::Context?) : Bool
        return true if workspace_context.nil?

        allowed = Database.with_db(:read_only) { |db| Access.allowed?(db, Facet::HTTP::Helpers.auth_context(env)) }
        return true if allowed

        Facet::HTTP::Helpers.error_response(
          env, 403, "You do not have access to the workspace assistant")
        false
      end

      # Availability gate for an app stream: the caller's token must name
      # the conversation's app, the app must be live with the assistant
      # enabled, and the active role must hold `assistant_access`
      # (`App::Gate`). The conversation's owner check already ran
      # (`ownership_check`); this gate re-reads the app projection on every
      # message, so a disable applies on the next stream. Returns `true`
      # when the stream may continue; on denial writes the 403 JSON and
      # returns `false`. Non-app conversations pass untouched.
      private def self.app_gate_allowed?(env, app_context : App::Context?) : Bool
        return true if app_context.nil?

        allowed = Database.with_db(:read_only) do |db|
          App::Gate.allowed?(db, Facet::HTTP::Helpers.auth_context(env), app_context.app_id)
        end
        return true if allowed

        Facet::HTTP::Helpers.error_response(
          env, 403, "You do not have access to the app assistant")
        false
      end
    end
  end
end
