# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "set"
require "agent-cr"

module Facet
  module Assistant
    module Stream
      # `Agent::Handler` that emits `tool_call` SSE events alongside the
      # chunk stream so the frontend can render live `ToolCallBar` traces.
      #
      # It hooks into the `ToolCallContext` stage of agent-cr's handler chain,
      # which fires right before a tool callback runs. We don't short-circuit;
      # we emit a `chunk` event with `status:"running"` before invoking
      # `next_proc`, then emit `status:"ok"` or `status:"error"` based on the
      # returned tool-result message. agent-cr marks failed tool-result
      # messages with stable error prefixes (see `ERROR_PREFIXES`), and the
      # registrars render a refused call as the error envelope (see
      # `REGISTRAR_ERROR_ENVELOPE`, B-368); we use both as error sentinels.
      #
      # `ToolCallName` / `ToolCallArgs` streamed chunks (the model drafting the
      # call name and argument deltas) are filtered out by `drain_stream` —
      # they're not execution events. The UI sees a single running→ok/error
      # cycle per tool from this handler, which is what `ToolCallBar` expects.
      #
      # Tool calls whose arguments fail to parse as JSON or fail schema
      # validation flow through the handler chain too: agent-cr returns the
      # pre-built error message from the chain leaf, so this handler emits a
      # `tool_call` chunk with status `error` for them, like it does for a
      # callback failure. The plain fallback bar in the chat UI then shows
      # the raw trace, as `doc/packages/chat.md` promises.
      #
      # The handler is constructed with a write callback because it shares an
      # `IO` with `Session#drain_stream`. Both `Session#run` and this handler
      # run on the same main fiber (agent-cr executes the handler chain
      # inline within the request loop), so no locking is needed.
      class ToolTraceHandler < Agent::Handler
        # Prefixes agent-cr writes at the start of a failed tool-result
        # message: a callback that raised, schema validation, or JSON parsing
        # of the arguments — see `agent.cr`'s tool execution path. Stable
        # across versions; treated as sentinels, not parsed.
        private ERROR_PREFIXES = [
          "Error executing tool",
          "Error validating arguments for tool",
          "Error parsing arguments for tool",
        ]

        # B-368: a refused tool call returns the registrar error envelope {"ok":false,...} — the model-facing contract; sentinel, not parsed.
        private REGISTRAR_ERROR_ENVELOPE = %({"ok":false)

        # The result of `next_proc.call` is the tool-result `Message`; its
        # `content` is the callback's return value (or agent-cr's error
        # string when the callback raised).
        def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
          name = ctx.tool_call.name
          args = ctx.tool_call.arguments
          forward_args = @argument_tools.includes?(name) ? args : nil

          emit_running(name, args, forward_args)

          result_msg = next_proc.call(ctx)

          content = result_msg.content || ""
          if ERROR_PREFIXES.any? { |prefix| content.starts_with?(prefix) } ||
             content.lstrip.starts_with?(REGISTRAR_ERROR_ENVELOPE)
            emit(name, status: "error", result: content, arguments: forward_args)
          else
            emit(name, status: "ok", result: content, arguments: forward_args)
          end

          result_msg
        end

        # ── Helpers ────────────────────────────────────────────────────────

        private def emit_running(name : String, args_json : String?, forward_args : String?) : Nil
          detail = parse_args_detail(args_json)
          emit(name, status: "running", detail: detail, arguments: forward_args)
        end

        # Renders tool-call arguments as a short “key=value, key=value” string
        # for the `detail` field. Returns nil when args are empty or invalid
        # JSON so the UI shows the tool name alone.
        private def parse_args_detail(args_json : String?) : String?
          return nil if args_json.nil? || args_json.empty?
          begin
            parsed = JSON.parse(args_json).as_h?
            return nil if parsed.nil? || parsed.empty?
            parsed.map { |k, v| "#{k}=#{render_arg_value(v)}" }.join(", ")
          rescue JSON::Error
            nil
          end
        end

        # B-375: renders one argument value for the `detail` line. Containers
        # serialize as compact JSON; scalars render unwrapped. Interpolating
        # a `JSON::Any` directly leaks Crystal's inspect notation
        # (`definition={"domain" => JSON::Any("axt"), ...}`) into the chip.
        private def render_arg_value(value : JSON::Any) : String
          return value.to_json if value.as_h? || value.as_a?
          case raw = value.raw
          when Nil    then "null"
          when String then raw
          else             raw.to_s
          end
        end

        # Set of tool names whose raw `arguments` JSON is forwarded to the
        # frontend in the `tool_call` chunk payload. UI tools (see
        # `DomainBuilder::Registrar::UI_TOOL_NAMES`) are rendered by the chat
        # UI itself — the frontend needs the full arguments, not just the
        # short `detail` summary. Keeping the set explicit avoids bloating
        # the stream with the (potentially large) arguments of every other
        # tool call.
        @argument_tools : Set(String)

        @on_event : Proc({name: String, status: String, detail: String?, result: String?, arguments: String?}, Nil)

        def initialize(@on_event, @argument_tools = Set(String).new)
        end

        def emit(name : String, status : String, detail : String? = nil, result : String? = nil, arguments : String? = nil) : Nil
          @on_event.call({name: name, status: status, detail: detail, result: result, arguments: arguments})
        end
      end
    end
  end
end
