# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../notifications"
require "./uri"

module Facet
  module Document
    # Crystal-backed Lua functions for producing notifications from doctype
    # lifecycle hooks and named actions.
    #
    # Provides the `notification.*` global table, registered alongside
    # `document.*` on every `ScriptContext` that has a database connection
    # (create, update, delete, action). The helper does not insert — it
    # validates its arguments and enqueues a `Notification::Pending` on the
    # context's queue. The owning flow drains the queue after its mutation
    # persists, so a notification is never applied for an operation that
    # failed, and a create hook can point at the document it is creating
    # with `doc_ref = nil` (the id is filled in at drain time).
    #
    # | Lua function | Crystal backend | Returns |
    # |---|---|---|
    # | `notification.send(account_id, doc_ref, kind, title, [options])` | `Notification::Queue.enqueue` | `true` |
    #
    # ## Failure contract
    #
    # Malformed input — blank or oversized fields, reserved `__`-prefixed
    # action keys, a malformed `doc_ref`, a non-existent `account_id` —
    # raises a Lua error at send time, catchable with `pcall`. Uncaught, it
    # fails the script and can prevent the rows from being created; the
    # driver surfaces the unwind as a 422 refusal carrying the validation
    # message with `code: "script"` — the same envelope a `ctx.error(msg)`
    # call produces — never an opaque 500. Send-time work is validation and
    # enqueue only: there is no insert and no transaction of any kind here,
    # so a successful send can never outlive a failed parent mutation.
    module LuaNotificationHelpers
      # Registers the `notification` Lua global table on the engine.
      #
      # Uses the parent transaction's `DB::Connection` for the enqueue-time
      # account existence check.
      #
      # `queue` is the context's pending array — the same array the owning
      # flow drains after its mutation persists. One queue per
      # `ScriptContext`: a nested `document.create` inside a hook drains
      # its own queue when the child operation persists; the parent's
      # queue stays pending until the parent's own operation persists.
      def self.register(
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        queue : Array(Notification::Pending),
        service_errors : Array(Facet::ServiceError)? = nil,
      ) : Nil
        state = engine.raw_state

        # Create the `notification` table on the Lua stack
        LibLua.createtable(state, 0, 1)

        register_notification_send_on(state, engine, db, queue, service_errors)

        # Assign the completed table to the global `notification`
        LibLua.setglobal(state, "notification")
      end

      # ── Private: raw function registrations ────────────────────────────

      private def self.register_notification_send_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        queue : Array(Notification::Pending),
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "send") do |s|
          account_id = read_string_arg(s, 1)
          doc_ref = read_optional_string_arg(s, 2)
          kind = read_string_arg(s, 3)
          title = read_string_arg(s, 4)
          options = read_options_arg(s, 5)

          # `account_id` accepts the bare id or the qualified
          # `iam.Account.<id>` form; strip the prefix defensively (the
          # `ReferenceCheck.strip_qualified_id` precedent).
          qualified_prefix = "iam.Account."
          account_id = account_id[qualified_prefix.size..] if account_id.starts_with?(qualified_prefix)

          actions = parse_actions(options["actions"]?)
          data = read_data_arg(options)
          icon = string_option(options, "icon")
          body = string_option(options, "body") || ""

          # Validate and enqueue. `doc_ref = nil` stays nil — the owning
          # flow fills in its own document coordinates at drain time. All
          # argument conversion happens here: the Lua stack is gone by
          # drain time.
          Notification::Queue.enqueue(
            queue, db, account_id, kind, title,
            icon: icon, body: body, data: data, actions: actions, doc_ref: doc_ref,
          )

          # The notification id is not exposed — notifications are not
          # referenced from the document system.
          LibLua.pushboolean(s, 1)
          1
        rescue ex : Exception
          message = ex.message || "notification.send failed"
          # Record the refusal before raising so an uncaught unwind surfaces
          # the failure as a 422 script refusal instead of an opaque 500 (the
          # B-30 driver contract, `ScriptContext::Base#service_errors`). A
          # script that recovers through pcall never unwinds, so the recorded
          # refusal is ignored there — catchability is unchanged.
          service_errors.try(&.push(Facet::ServiceError.new(
            422, message, details: [Facet::ValidationError.new(message, code: "script")])))
          LibLua.pushstring(s, message)
          LibLua.error(s)
          0
        end
      end

      # ── Private: argument resolution ───────────────────────────────────

      # Converts the optional options table to JSON. Absent or nil yields
      # an empty object; a non-table value is a producer error.
      private def self.read_options_arg(state : LibLua::State, index : Int32) : JSON::Any
        idx = LibLua.absindex(state, index)
        if LibLua.gettop(state) >= idx && LibLua.type(state, idx) == 5
          options = ScriptContext.lua_stack_to_json_any(state, index)
          raise ArgumentError.new("notification.send: options must be a table") if options.as_h?.nil?
          options
        else
          JSON::Any.new({} of String => JSON::Any)
        end
      end

      # Reads an optional string field from the options table.
      private def self.string_option(options : JSON::Any, key : String) : String?
        value = options[key]?
        return nil if value.nil?
        value.as_s? || raise ArgumentError.new("notification.send: #{key} must be a string")
      end

      # Reads the optional `data` field. Defaults to an empty object;
      # the documented contract is a table.
      private def self.read_data_arg(options : JSON::Any) : JSON::Any
        value = options["data"]?
        return JSON::Any.new({} of String => JSON::Any) if value.nil?
        raise ArgumentError.new("notification.send: data must be a table") if value.as_h?.nil?
        value
      end

      # Converts the optional `actions` array of descriptor tables into
      # `Notification::Action` records. `key` and `label` are required;
      # `variant` and `confirm` are optional. Reserved `__`-prefixed keys
      # are rejected by `Notification::Queue.enqueue`.
      private def self.parse_actions(value : JSON::Any?) : Array(Notification::Action)
        return [] of Notification::Action if value.nil?
        raw = value.as_a?
        raise ArgumentError.new("notification.send: actions must be an array") if raw.nil?

        raw.map do |entry|
          table = entry.as_h?
          raise ArgumentError.new("notification.send: each action must be a table") if table.nil?
          key = table["key"]?.try(&.as_s?)
          raise ArgumentError.new("notification.send: every action needs a key") if key.nil? || key.empty?
          label = table["label"]?.try(&.as_s?)
          raise ArgumentError.new("notification.send: action '#{key}' needs a label") if label.nil? || label.empty?
          Notification::Action.new(
            key: key,
            label: label,
            variant: table["variant"]?.try(&.as_s?),
            confirm: table["confirm"]?.try(&.as_s?),
          )
        end
      end

      # ── Private: Lua stack helpers ─────────────────────────────────────

      # Reads a string argument from the Lua stack at the given index.
      # Raises if the argument is not a string. Type-checked first —
      # `tolstring` would silently stringify numbers.
      private def self.read_string_arg(state : LibLua::State, index : Int32) : String
        idx = LibLua.absindex(state, index)
        raise ArgumentError.new("notification.send: expected string argument at position #{index}") if LibLua.type(state, idx) != 4
        ptr = LibLua.tolstring(state, idx, nil)
        raise ArgumentError.new("notification.send: expected string argument at position #{index}") if ptr.null?
        String.new(ptr)
      end

      # Reads an optional string argument. Absent, nil, and string values
      # are accepted; any other type is a producer error.
      private def self.read_optional_string_arg(state : LibLua::State, index : Int32) : String?
        idx = LibLua.absindex(state, index)
        return nil if LibLua.gettop(state) < idx || LibLua.type(state, idx) == 0
        raise ArgumentError.new("notification.send: argument at position #{index} must be a string or nil") if LibLua.type(state, idx) != 4
        ptr = LibLua.tolstring(state, idx, nil)
        raise ArgumentError.new("notification.send: argument at position #{index} must be a string or nil") if ptr.null?
        String.new(ptr)
      end
    end
  end
end
