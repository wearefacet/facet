# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Lua script context for executing doctype lifecycle hooks and actions.
#
# Each context sets up a prepared `ctx` Lua table, loads the doctype's
# script (which returns an export table), and calls the corresponding
# lifecycle or action function.
#
# ## Module pattern
#
# Scripts must return a Lua table containing the exported functions:
#
# ```lua
# local export = {}
#
# function export.create(ctx)
#   if ctx.root.title == "" then
#     ctx.error("title is required")
#   end
# end
#
# function export.promote(ctx, args)
#   if ctx.root.status ~= "active" then
#     ctx.error("Employee is not active")
#   end
# end
#
# return export
# ```
#
# ## ctx table
#
# | Field | Type | Present in |
# |---|---|---|
# | `ctx.root` | table | All — the document content |
# | `ctx.error(msg)` | function | All — collects validation errors |
# | `ctx.actor_id` | string | All — the actioner |
# | `ctx.now` | string | All — ISO 8601 timestamp |
# | `ctx.actor` | table | Create (when `auth_context` is supplied) — RBAC surface |
#
# See `doc/backend/lua-engine.md` for the full `ctx.actor` field reference.
#
# ## Usage
#
# ```
# ScriptContext::Create.new(script_source, document_json, "account-1") do |ctx|
#   errors = ctx.run
#   errors.empty?     # => true if validation passed
#   ctx.root_document # => mutated JSON::Any (with slug, etc.)
# end
# ```
#
# This file is a require root. The concern lives in `script_context/`:
# `json_bridge` (JSON ↔ Lua converters), `base` (runtime base),
# `actor_table` (the `ctx.actor` surface), and one file per lifecycle
# context (create, update, delete, action, migrate).

require "./script_context/json_bridge"
require "./script_context/base"
require "./script_context/actor_table"
require "./script_context/create"
require "./script_context/update"
require "./script_context/delete"
require "./script_context/action"
require "./script_context/migrate"
