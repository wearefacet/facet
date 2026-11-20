# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "opentelemetry"
require "../lua"
require "../database"
require "../document/lua_document_helpers"
require "../document/script_context"
require "../rbac"
require "../telemetry"
require "./definition"

module Facet
  module Hooks
    # Runs one hook's Lua script under a fresh sandbox for a single trigger.
    #
    # Mirrors the structure of `Document::ScriptContext::Action`: boots a
    # `Lua::Sandbox`, registers the `error` global, registers the shared
    # `util.*` / `date.*` / `math.clamp` globals with the JSON helpers and
    # the db-backed gates (full parity with the lifecycle script contexts),
    # registers the `document.*` helpers pinned to the **owning** domain
    # (writes are domain-scoped by construction; reads may cross domains via
    # a qualified `domain.Doctype` first argument — see
    # `Document::LuaDocumentHelpers#split_qualified`), wraps the script in
    # the module pattern, builds the `ctx` table, and calls the hook's
    # exported function.
    #
    # ## ctx table
    #
    # | Field | Type | Present in |
    # |---|---|---|
    # | `ctx.event` | table | `event` hooks — the source mutation payload |
    # | `ctx.scheduled_at` | string | `schedule` hooks — ISO 8601 instant the fire was due |
    # | `ctx.error(msg)` | function | Both — validation error collector |
    # | `ctx.actor_id` | string | Both — always `"system:hooks"` |
    # | `ctx.now` | string | Both — ISO 8601 timestamp |
    #
    # `ctx.event` carries `{domain, doc_type, event, doc_id, mutation_id,
    # actioner_id, content}` — the full source mutation payload, so the
    # common case (read the source document that triggered the hook) does
    # not need a cross-domain `document.get` call.
    #
    # ## Error model
    #
    # Two failure modes, mirroring `ScriptContext`:
    #
    # - `ctx.error(msg)` calls collect into `#errors` (expected validation
    #   path — the hook rejects its own work).
    # - Lua syntax / runtime errors raise `Hooks::Executor::Error`
    #   (unexpected — caller logs and skips, mirroring `Replication::Handler`'s
    #   "transient error is permanent until next source mutation" stance).
    class Executor
      Log = ::Log.for("facet.hooks.executor")

      # Raised when the Lua script has a syntax error or raises an
      # unhandled runtime error. Distinct from `ctx.error(msg)` calls,
      # which are the expected validation path.
      class Error < ::RuntimeError
        getter engine_error : Lua::Engine::Error

        # `wrap_script` adds one line ahead of the hook script; rebase one
        # more line onto the author's numbering (B-318).
        def initialize(@engine_error : Lua::Engine::Error)
          super(Lua::Engine::Error.rebase_position(@engine_error.message, 1))
        end
      end

      getter db : DB::Connection
      getter owning_domain : String
      getter hook : Definition::Hook
      getter actor_id : String
      # Cause template for the writes the hook's Lua performs. `parent` and
      # `trace` are bound by the caller (the source mutation for event
      # hooks; the fire trace for schedule hooks).
      getter cause : Mutation::Cause?

      @engine : Lua::Engine?
      @errors : Array(Facet::ValidationError)

      # Yields the executor to a block and closes the Lua engine when done.
      def initialize(
        @db : DB::Connection,
        @owning_domain : String,
        @hook : Definition::Hook,
        @actor_id : String = "system:hooks",
        @cause : Mutation::Cause? = nil,
        & : self ->
      )
        @errors = [] of Facet::ValidationError
        @engine = nil

        sandbox = Lua::Sandbox.new
        engine = sandbox.engine
        @engine = engine

        begin
          sandbox.register_error_global(@errors)
          # B-203: full parity with the lifecycle script contexts — the util
          # (including the JSON helpers and the db-backed gates), date, and
          # math globals ride along. `document.get` / `document.list` return
          # `content` and `meta` as JSON strings, so a hook that reads them
          # needs `util.json_decode`; the db-backed bindings carry the same
          # authoring gates lifecycle scripts get (see `Lua::Sandbox
          # #register_util_globals!`).
          sandbox.register_util_globals!(json_helpers: true, db: db)
          # `document.*` helpers are pinned to the owning domain. Writes
          # (`document.create`/`update`/`delete`) accept a bare doctype and
          # route through the owning domain — the hook cannot write outside
          # its domain. Reads (`document.get`/`list`) accept a qualified
          # `domain.Doctype` to cross domains (plan decision 3). Hook writes
          # set `reentrant: true` to prevent hook → event → hook cycles
          # (decision 5).
          sandbox.register_document_helpers!(db, owning_domain, cause, nil, actor_id, reentrant: true)

          wrapped = Document::ScriptContext.wrap_script(hook.script)
          engine.run(wrapped)

          yield self
        rescue ex : Lua::Engine::Error
          raise Error.new(ex)
        ensure
          @engine.try(&.close)
        end
      end

      # Builds the `ctx` table and sets it as a global. For an `event`
      # hook, `ctx.event` carries the source mutation payload.
      def setup_event_ctx(event_payload : JSON::Any, now : Time = Time.utc) : Nil
        engine = engine!
        ctx = Hash(String, Lua::Engine::Value).new
        ctx["event"] = Document::ScriptContext.json_to_lua_value(event_payload)
        ctx["actor_id"] = @actor_id
        ctx["now"] = now.to_rfc3339
        engine.set_global("ctx", ctx)

        # Wire `ctx.error` to the registered `error` global.
        engine.run(<<-LUA)
          ctx.error = error
        LUA
      end

      # Runs `_MODULE.on_event(ctx)` for an `event` hook. Returns the
      # list of `ctx.error(msg)` validation messages (empty if none).
      #
      # Opened under a `hooks.event.run` span carrying `hooks.domain`,
      # `hooks.id`, `hooks.kind`, `hooks.actor_id` per the
      # plan's telemetry dimension (open question 4). `ctx.error(msg)`
      # calls are the expected validation path and do not flip the span
      # status to error — only Lua syntax/runtime errors do, via
      # `Telemetry.record_error`.
      def run_event(event_payload : JSON::Any, now : Time = Time.utc) : Array(Facet::ValidationError)
        raise ArgumentError.new("Hook is not an event hook") unless hook.kind == :event
        Facet::Telemetry.trace "hooks.event.run" do |span|
          tag_span(span)
          begin
            setup_event_ctx(event_payload, now)
            engine!.run(<<-LUA)
              if _MODULE ~= nil and _MODULE.on_event ~= nil then
                _MODULE.on_event(ctx)
              end
            LUA
            tag_validation_errors(span, @errors)
            @errors.dup
          rescue ex : Lua::Engine::Error
            Telemetry.record_error(span, ex.message || "lua error")
            raise Error.new(ex)
          end
        end
      end

      # Builds the `ctx` table for a `schedule` hook. `scheduled_at` is the
      # cron-computed fire bucket (the instant the fire was due, not `now` at
      # dispatch time) so the script can distinguish "when this was supposed
      # to run" from clock-drift-aware logic.
      def setup_schedule_ctx(scheduled_at : Time, now : Time = Time.utc) : Nil
        engine = engine!
        ctx = Hash(String, Lua::Engine::Value).new
        ctx["scheduled_at"] = scheduled_at.to_rfc3339
        ctx["actor_id"] = @actor_id
        ctx["now"] = now.to_rfc3339
        engine.set_global("ctx", ctx)

        # Wire `ctx.error` to the registered `error` global.
        engine.run(<<-LUA)
          ctx.error = error
        LUA
      end

      # Runs `_MODULE.on_schedule(ctx)` for a `schedule` hook. Returns the
      # list of `ctx.error(msg)` validation messages (empty if none).
      #
      # Opened under a `hooks.schedule.run` span with the same attribute
      # surface as `run_event` plus `hooks.scheduled_at`.
      def run_schedule(scheduled_at : Time, now : Time = Time.utc) : Array(Facet::ValidationError)
        raise ArgumentError.new("Hook is not a schedule hook") unless hook.kind == :schedule
        Facet::Telemetry.trace "hooks.schedule.run" do |span|
          tag_span(span)
          span["hooks.scheduled_at"] = scheduled_at.to_rfc3339
          begin
            setup_schedule_ctx(scheduled_at, now)
            engine!.run(<<-LUA)
              if _MODULE ~= nil and _MODULE.on_schedule ~= nil then
                _MODULE.on_schedule(ctx)
              end
            LUA
            tag_validation_errors(span, @errors)
            @errors.dup
          rescue ex : Lua::Engine::Error
            Telemetry.record_error(span, ex.message || "lua error")
            raise Error.new(ex)
          end
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      private def engine! : Lua::Engine
        @engine.as(Lua::Engine)
      end

      # Stamps the common `hooks.*` attributes on the span — domain, id,
      # kind, actor — the telemetry dimension agreed in the plan
      # (open question 4). The causal chain lives on the mutations the
      # hook writes (`mutations.meta.cause`), not on the span.
      private def tag_span(span) : Nil
        span["hooks.domain"] = owning_domain
        span["hooks.id"] = hook.id
        span["hooks.kind"] = hook.kind.to_s
        span["hooks.actor_id"] = actor_id
      end

      # Records `ctx.error(msg)` outcomes as a non-error attribute — the
      # count plus the first message. These are the expected validation
      # path (the hook rejects its own work); the span status is left OK
      # so a search for `status=error` finds only genuine Lua failures.
      private def tag_validation_errors(span, errors : Array(Facet::ValidationError)) : Nil
        return if errors.empty?
        span["hooks.validation_errors"] = errors.size.to_s
        span["hooks.validation_error"] = errors.first.message
      end
    end
  end
end
