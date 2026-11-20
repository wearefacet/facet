# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "agent-cr"
require "./assistant/config"
require "./assistant/conversation"
require "./assistant/turn"
require "./assistant/resume"
require "./assistant/tools"
require "./assistant/access"
require "./assistant/custom_prompt"
require "./assistant/language"
require "./assistant/usage"
require "./assistant/limits"
require "./assistant/stream/cancel_bus"
require "./assistant/stream/session"
require "./assistant/stream/tool_trace_handler"
require "./assistant/app/context"
require "./assistant/app/gate"
require "./assistant/app/registrar"
require "./assistant/app/system_prompt"
require "./assistant/app/routes"
require "./assistant/routes"

module Facet
  # Namespace for the AI Assistant system.
  #
  # The Assistant module wraps the `agent-cr` shard to provide an
  # LLM-powered conversational agent that can answer questions about
  # the organization's data, execute registered tools (e.g. query a
  # doctype, search documents), and maintain conversation history.
  #
  # ## Files
  #
  # - `assistant/config.cr` — Assistant configuration and setup.
  # - `assistant/conversation.cr` — `Conversation` storage service.
  # - `assistant/turn.cr` — `Turn` storage service.
  # - `assistant/resume.cr` — `Resume` service (reconstruct an `Agent` from stored rows).
  # - `assistant/tools.cr` — shared tool envelope (`ok` / `error` / `tool_mutation`).
  # - `assistant/access.cr` — availability gate (`Assistant::Access`).
  # - `assistant/custom_prompt.cr` — the operator's custom-instructions block.
  # - `assistant/language.cr` — the user-language directive block.
  # - `assistant/usage.cr` — per-account token usage ledger.
  # - `assistant/limits.cr` — token-budget enforcement seam.
  # - `assistant/stream/cancel_bus.cr` — Redis Pub/Sub cancel fan-out.
  # - `assistant/stream/session.cr` — one-turn SSE streaming orchestrator.
  # - `assistant/stream/tool_trace_handler.cr` — sends `tool_call` SSE events when a tool runs.
  # - `assistant/app/context.cr` — typed context for app-assistant conversations.
  # - `assistant/app/gate.cr` — per-app availability gate (`Assistant::App::Gate`).
  # - `assistant/app/registrar.cr` — app-surface tool registrar.
  # - `assistant/app/system_prompt.cr` + `system_prompt.md` — app-surface prompt builder.
  # - `assistant/app/routes.cr` — the app conversation-creation route.
  # - `assistant/routes.cr` — HTTP routes for assistant conversation storage and streaming.
  module Assistant
  end
end
