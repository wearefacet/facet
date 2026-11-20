# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../error"
require "../util/script_helpers"
require "../webhook/target_check"
require "../document/lua_document_helpers"
require "../document/lua_notification_helpers"
require "../document/script_context"

module Facet
  module Lua
    # Shared Lua runtime setup for script execution surfaces.
    #
    # Owns engine boot and the registration helpers: the `util.*` /
    # `date.*` / `math.clamp` globals (the `util.json_*` helpers and the
    # db-backed gates ride behind the `json_helpers` / `db` flags), the
    # `error(msg)` collector global, and the `document.*` /
    # `notification.*` helpers. Consumers, each picking its registrations:
    # `Document::ScriptContext::Base` (all of them, db-backed),
    # `Document::Compute` (util + JSON helpers, read-only document helpers,
    # no db-backed gates), and `Hooks::Executor` (util + JSON + db-backed
    # gates, domain-scoped `reentrant` document helpers).
    #
    # Boot happens at construction. Each registration is a separate call, so
    # every consumer keeps its exact setup order.
    class Sandbox
      # The engine booted at construction.
      getter engine : Engine

      # Boots one sandboxed engine.
      def initialize
        @engine = Engine.new
      end

      # Registers the `util.*`, `date.*`, and `math.clamp` globals shared
      # by the lifecycle script contexts and the compute engine. When
      # `json_helpers` is true, `util.json_encode` / `util.json_decode`
      # are registered too. Compute runs with them: `document.get` /
      # `document.list` return content as a JSON string, and a compute
      # function that reads through them needs `util.json_decode`.
      #
      # `db` gates the one query-backed binding (`util.oidc_name_tombstoned`):
      # the compute engine runs without a connection, so the binding only
      # exists in lifecycle-hook contexts.
      def register_util_globals!(json_helpers : Bool, db : DB::Connection? = nil) : Nil
        engine.function("__util_ulid", -> { ::Facet::Util::ScriptHelpers.ulid })
        engine.function("__util_sha256", ->(s : String) { ::Facet::Util::ScriptHelpers.sha256(s) })
        engine.function("__util_clamp", ->(x : Float64, min : Float64, max : Float64) {
          ::Facet::Util::ScriptHelpers.clamp(x, min, max)
        })
        engine.function("__util_facet_hosts", -> { ::Facet::Util::ScriptHelpers.facet_hosts })
        engine.function("__util_valid_hostname", ->(s : String) { ::Facet::Util::ScriptHelpers.valid_hostname?(s) })
        engine.function("__util_valid_redirect_uri", ->(s : String) { ::Facet::Util::ScriptHelpers.valid_redirect_uri?(s) })
        engine.function("__util_valid_https_url", ->(s : String) { ::Facet::Util::ScriptHelpers.valid_https_url?(s) })
        engine.function("__util_valid_issuer_url", ->(s : String) { ::Facet::Util::ScriptHelpers.valid_issuer_url?(s) })
        engine.function("__util_insecure_urls_allowed", -> { ::Facet::Config.instance.webhook.allow_insecure_urls })
        # B-76 host gate — the authoring-time half of the webhook target
        # rule. The binding judges only where the host points; the scheme
        # rule stays with `valid_https_url` / `insecure_urls_allowed`, whose
        # rejection wording needs the config flag.
        engine.function("__util_safe_webhook_url", ->(s : String) { ::Facet::Webhook::TargetCheck.host_safe?(s) })
        # B-152 authoring gate — the closed event-name vocabulary for the
        # `core.Webhook` `events` field. The webhook hooks reject any name
        # outside this list, so a typo'd binding cannot silently never fire.
        engine.function("__util_webhook_event_names", -> { ::Facet::Util::ScriptHelpers.webhook_event_names })
        if captured_db = db
          engine.function("__util_oidc_name_tombstoned", ->(s : String) { ::Facet::Util::ScriptHelpers.oidc_name_tombstoned?(captured_db, s) })
          # Connectivity gate — the authoring-time half of the role-channel
          # rule (`core.Webhook` create/update; see
          # `Util::ScriptHelpers.role_has_channel?` for the read semantics).
          engine.function("__util_role_has_channel", ->(role_id : String, channel : String) {
            ::Facet::Util::ScriptHelpers.role_has_channel?(captured_db, role_id, channel)
          })
        end
        engine.function("__date_now", -> { ::Facet::Util::ScriptHelpers.date_now })
        engine.function("__date_today", -> { ::Facet::Util::ScriptHelpers.date_today })
        bind_date_function!("__date_diff", 3) { |a| ::Facet::Util::ScriptHelpers.date_diff(a[0], a[1], a[2]) }
        bind_date_function!("__date_add", 3) { |a| ::Facet::Util::ScriptHelpers.date_add(a[0], a[1].to_f64, a[2]) }
        bind_date_function!("__date_start_of", 2) { |a| ::Facet::Util::ScriptHelpers.date_start_of(a[0], a[1]) }
        bind_date_function!("__date_end_of", 2) { |a| ::Facet::Util::ScriptHelpers.date_end_of(a[0], a[1]) }
        bind_date_function!("__date_period_overlaps", 4) { |a| ::Facet::Util::ScriptHelpers.period_overlaps?(a[0], a[1], a[2], a[3]) }
        bind_date_function!("__date_period_contains", 3) { |a| ::Facet::Util::ScriptHelpers.period_contains?(a[0], a[1], a[2]) }
        bind_date_function!("__date_dateperiod_overlaps", 4) { |a| ::Facet::Util::ScriptHelpers.dateperiod_overlaps?(a[0], a[1], a[2], a[3]) }
        bind_date_function!("__date_dateperiod_contains", 3) { |a| ::Facet::Util::ScriptHelpers.dateperiod_contains?(a[0], a[1], a[2]) }
        register_date_parts!
        engine.function("__math_clamp", ->(x : Float64, min : Float64, max : Float64) {
          ::Facet::Util::ScriptHelpers.clamp(x, min, max)
        })

        if json_helpers
          engine.raw_function("__util_json_encode") do |s|
            if LibLua.gettop(s) < 1
              LibLua.pushstring(s, "util.json_encode requires 1 argument")
              LibLua.error(s)
              0
            else
              json_str = ::Facet::Document::ScriptContext.lua_stack_to_json_string(s, 1)
              LibLua.pushstring(s, json_str)
              1
            end
          end

          engine.raw_function("__util_json_decode") do |s|
            if LibLua.gettop(s) < 1
              LibLua.pushstring(s, "util.json_decode requires 1 argument")
              LibLua.error(s)
              0
            else
              ptr = LibLua.tolstring(s, 1, nil)
              if ptr.null?
                LibLua.pushnil(s)
                1
              else
                json_str = String.new(ptr)
                begin
                  parsed = JSON.parse(json_str)
                  ::Facet::Document::ScriptContext.push_json_to_lua_stack(s, parsed)
                  1
                rescue ex : JSON::ParseException
                  LibLua.pushstring(s, "Invalid JSON: #{ex.message}")
                  LibLua.error(s)
                  0
                end
              end
            end
          end
        end

        engine.run(<<-LUA)
          util = {
            ulid      = __util_ulid,
            sha256    = __util_sha256,
            clamp     = __util_clamp,
            facet_hosts    = __util_facet_hosts,
            valid_hostname = __util_valid_hostname,
            valid_redirect_uri = __util_valid_redirect_uri,
            valid_https_url = __util_valid_https_url,
            valid_issuer_url = __util_valid_issuer_url,
            insecure_urls_allowed = __util_insecure_urls_allowed,
            safe_webhook_url = __util_safe_webhook_url,
            webhook_event_names = __util_webhook_event_names,
            is_empty = function(v)
              if v == nil then return true end
              if type(v) == "string" and v == "" then return true end
              if type(v) == "table" and next(v) == nil then return true end
              return false
            end,
            coalesce = function(...)
              local args = { ... }
              for _, v in ipairs(args) do
                if not util.is_empty(v) then
                  return v
                end
              end
              return nil
            end,
          }
          -- The period wrappers capture the raw functions as locals at boot
          -- time: the cleanup below nils the `__date_*` temp globals, and a
          -- wrapper body that read the global at call time would find nil.
          local __ovl, __cnt = __date_period_overlaps, __date_period_contains
          local __dovl, __dcnt = __date_dateperiod_overlaps, __date_dateperiod_contains
          date = {
            diff      = __date_diff,
            now       = __date_now,
            today     = __date_today,
            add       = __date_add,
            start_of  = __date_start_of,
            end_of    = __date_end_of,
            parts     = __date_parts,
            -- `end` is a Lua keyword, so period bounds read through p["end"].
            period_overlaps = function(a, b)
              return __ovl(a.start, a["end"], b.start, b["end"])
            end,
            period_contains = function(p, x)
              return __cnt(p.start, p["end"], x)
            end,
            dateperiod_overlaps = function(a, b)
              return __dovl(a.start, a["end"], b.start, b["end"])
            end,
            dateperiod_contains = function(p, x)
              return __dcnt(p.start, p["end"], x)
            end,
          }
          math.clamp = __math_clamp
        LUA

        # Query-backed bindings — lifecycle contexts only (the compute
        # engine runs without a connection).
        if db
          engine.run(<<-LUA)
            util.oidc_name_tombstoned = __util_oidc_name_tombstoned
            util.role_has_channel = __util_role_has_channel
          LUA
        end

        if json_helpers
          engine.run(<<-LUA)
            util.json_encode = __util_json_encode
            util.json_decode = __util_json_decode
          LUA
        end

        # ── Clean up temp globals ──
        cleanup_globals = [
          "__util_ulid", "__util_sha256", "__util_clamp",
          "__util_facet_hosts", "__util_valid_hostname", "__util_valid_redirect_uri",
          "__util_valid_https_url", "__util_valid_issuer_url", "__util_insecure_urls_allowed", "__util_safe_webhook_url",
          "__util_webhook_event_names",
          "__util_oidc_name_tombstoned", "__util_role_has_channel",
          "__date_diff", "__date_now", "__date_today", "__date_add",
          "__date_start_of", "__date_end_of", "__date_parts",
          "__date_period_overlaps", "__date_period_contains",
          "__date_dateperiod_overlaps", "__date_dateperiod_contains",
          "__math_clamp",
        ]
        cleanup_globals += ["__util_json_encode", "__util_json_decode"] if json_helpers
        engine.run(build_cleanup_lua(cleanup_globals))
      end

      # Registers the `error(msg)` global. Each call appends one
      # `ValidationError` with `code` to `errors`.
      def register_error_global(errors : Array(ValidationError), code : String = "script") : Nil
        engine.function("error", ->(msg : String) {
          errors << ValidationError.new(
            field: nil,
            message: msg,
            code: code,
          )
          nil
        })
      end

      # Registers the `document.*` helpers for inter-document operations.
      # Writes are pinned to `domain`. Reads may cross domains through a
      # qualified `domain.Doctype` first argument. `reentrant` marks the
      # writes of a hook, to prevent hook → event → hook cycles.
      def register_document_helpers!(
        db : DB::Connection,
        domain : String,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        actor_id : String? = nil,
        reentrant : Bool = false,
        service_errors : Array(Facet::ServiceError)? = nil,
      ) : Nil
        Document::LuaDocumentHelpers.register(engine, db, domain, cause, provenance, actor_id, reentrant: reentrant, service_errors: service_errors)
      end

      # Registers the `notification.send` helper. The caller owns `queue`
      # and drains it after its own operation persists. `service_errors`
      # records the send-time refusal so an uncaught unwind surfaces as 422
      # (the B-30 driver contract) instead of an opaque 500.
      def register_notification_helpers!(
        db : DB::Connection,
        queue : Array(Notification::Pending),
        service_errors : Array(Facet::ServiceError)? = nil,
      ) : Nil
        Document::LuaNotificationHelpers.register(engine, db, queue, service_errors)
      end

      # Closes the engine. Repeat calls do nothing.
      def close : Nil
        engine.close
      end

      # Helper to build Lua code that nil-clears a list of temp globals.
      private def build_cleanup_lua(globals : Array(String)) : String
        String.build do |io|
          globals.each do |g|
            io << g << " = nil\n"
          end
        end
      end

      # Registers one `date.*` binding: `arg_count` string arguments in,
      # one scalar out. All failures — wrong argument kinds, unparseable
      # dates, unknown units — surface as catchable Lua errors, the same
      # pattern the `util.json_*` helpers use. A plain `engine.function`
      # binding that raises unwinds as a Crystal exception through the
      # Lua C frames: no `pcall` inside the script could catch it, and
      # the Lua state is left dirty.
      private def bind_date_function!(name : String, arg_count : Int32, &fn : Array(String) -> String | Float64 | Bool) : Nil
        engine.raw_function(name) do |s|
          if LibLua.gettop(s) < arg_count
            LibLua.pushstring(s, "#{name} expects #{arg_count} argument(s)")
            LibLua.error(s)
            0
          else
            args = (1..arg_count).map { |i| date_string_arg(s, i, name) }
            begin
              push_date_result(s, fn.call(args))
              1
            rescue ex
              LibLua.pushstring(s, ex.message || name)
              LibLua.error(s)
              0
            end
          end
        end
      end

      # `date.parts(iso)` — returns a table, so a dedicated binding that
      # builds the Lua table directly.
      private def register_date_parts! : Nil
        engine.raw_function("__date_parts") do |s|
          if LibLua.gettop(s) < 1
            LibLua.pushstring(s, "__date_parts expects 1 argument")
            LibLua.error(s)
            0
          else
            begin
              parts = ::Facet::Util::ScriptHelpers.date_parts(date_string_arg(s, 1, "date.parts"))
              LibLua.createtable(s, 0, 7)
              LibLua.pushinteger(s, parts[:year].to_i64); LibLua.setfield(s, -2, "year")
              LibLua.pushinteger(s, parts[:month].to_i64); LibLua.setfield(s, -2, "month")
              LibLua.pushinteger(s, parts[:day].to_i64); LibLua.setfield(s, -2, "day")
              LibLua.pushinteger(s, parts[:hour].to_i64); LibLua.setfield(s, -2, "hour")
              LibLua.pushinteger(s, parts[:minute].to_i64); LibLua.setfield(s, -2, "minute")
              LibLua.pushinteger(s, parts[:second].to_i64); LibLua.setfield(s, -2, "second")
              LibLua.pushinteger(s, parts[:weekday].to_i64); LibLua.setfield(s, -2, "weekday")
              1
            rescue ex
              LibLua.pushstring(s, ex.message || "date.parts")
              LibLua.error(s)
              0
            end
          end
        end
      end

      # Reads argument `index` as a string. Lua numbers convert through
      # `lua_tolstring`; `nil`, booleans, and tables give `null`.
      private def date_string_arg(s : LibLua::State, index : Int32, name : String) : String
        ptr = LibLua.tolstring(s, index, nil)
        raise ArgumentError.new("#{name}: argument #{index} must be a string") if ptr.null?
        String.new(ptr)
      end

      # Pushes a `date.*` binding result onto the Lua stack.
      private def push_date_result(s : LibLua::State, value : String | Float64 | Bool) : Nil
        case value
        when String  then LibLua.pushstring(s, value)
        when Float64 then LibLua.pushnumber(s, value)
        when Bool    then LibLua.pushboolean(s, value ? 1 : 0)
        end
      end
    end
  end
end
