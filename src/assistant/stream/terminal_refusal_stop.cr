# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "set"
require "agent-cr"

require "../refusal_guard"

module Facet
  module Assistant
    module Stream
      # `Agent::Handler` that ends the turn when the model ignores a final
      # refusal. The `RefusalGuard`'s terminal envelope is model-facing text
      # only — agent-cr wraps it verbatim into the tool result and loops on.
      # This handler hooks the `ToolCallContext` stage (around each tool
      # callback, like `ToolTraceHandler`) and inspects the tool-result
      # message: the first terminal envelope for a call is recorded and
      # passed through untouched, so the model gets exactly one provider
      # call to comply. When the same call — same tool, same canonical
      # arguments — produces a second terminal envelope in the same turn,
      # the handler calls `Agent::Response#cancel` (idempotent, safe from
      # any fiber); the loop's next preflight then ends the turn through the
      # same cancelled path a user-initiated cancel takes. The message is
      # never changed, so the tool trace and the persisted history stay
      # complete.
      #
      # One instance lives for one streaming turn: `Session#build_agent`
      # constructs it next to the refusal guard, whose registrar also runs
      # once per turn, so both sides' state resets together. The handler
      # chain runs inline on the agent run-loop fiber — no lock needed.
      class TerminalRefusalStop < Agent::Handler
        @terminal_keys = Set(String).new

        def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
          result_msg = next_proc.call(ctx)

          if RefusalGuard.terminal_result?(result_msg.content)
            key = call_key(ctx.tool_call)
            if @terminal_keys.includes?(key)
              # The model re-emitted a call the guard already called final:
              # cancel instead of paying for another provider round trip.
              ctx.response.cancel
            else
              @terminal_keys << key
            end
          end

          result_msg
        end

        # Same key shape as `RefusalGuard` — object keys sorted at every
        # depth — so the calls of one repeat loop share a key even when the
        # model reorders the JSON.
        private def call_key(tool_call : Agent::ToolCall) : String
          RefusalGuard.call_key(tool_call.name, JSON.parse(tool_call.arguments))
        rescue JSON::Error
          # Unreachable for a terminal envelope — the guard callback only
          # runs after agent-cr parsed the arguments — but the key must stay
          # total: fall back to the raw arguments string.
          "#{tool_call.name}\0#{tool_call.arguments}"
        end
      end
    end
  end
end
