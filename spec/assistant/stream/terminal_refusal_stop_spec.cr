# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../../src/assistant/stream/terminal_refusal_stop"

# Unit tests for `TerminalRefusalStop`. Each example drives `handle` with a
# fake `next_proc` returning a canned tool-result message and asserts on a
# real `Agent::Response` — constructible with no provider, so no HTTP and no
# database. The handler must return every message unchanged; its only effect
# is `Agent::Response#cancel` when the same call produces a second terminal
# refusal envelope in the same turn.

private def handler : Facet::Assistant::Stream::TerminalRefusalStop
  Facet::Assistant::Stream::TerminalRefusalStop.new
end

private def terminal_envelope(tool : String) : String
  Facet::Assistant::RefusalGuard.terminal_envelope(tool)
end

private def tool_message(content : String) : Agent::Message
  Agent::Message.new(role: Agent::Role::Tool, content: content, tool_call_id: "call_1", name: "create_document")
end

private def tool_context(name : String, arguments : String, response : Agent::Response) : Agent::ToolCallContext
  Agent::ToolCallContext.new(Agent::ToolCall.new(id: "call_1", name: name, arguments: arguments), response)
end

describe Facet::Assistant::Stream::TerminalRefusalStop do
  it "does not cancel on a first terminal envelope and returns it unchanged" do
    response = Agent::Response.new
    msg = tool_message(terminal_envelope("create_document"))
    ctx = tool_context("create_document", %({"id": "doc_1"}), response)

    result = handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    result.should be(msg)
    response.cancelled?.should be_false
  end

  it "cancels the response when the same call repeats a terminal envelope" do
    response = Agent::Response.new
    msg = tool_message(terminal_envelope("create_document"))
    ctx = tool_context("create_document", %({"id": "doc_1"}), response)
    stop = handler

    stop.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })
    response.cancelled?.should be_false

    stop.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    response.cancelled?.should be_true
  end

  it "treats reordered JSON arguments as the same key" do
    response = Agent::Response.new
    msg = tool_message(terminal_envelope("create_document"))
    stop = handler

    stop.handle(
      tool_context("create_document", %({"meta": {}, "id": "doc_1"}), response),
      ->(_c : Agent::ToolCallContext) { msg },
    )
    stop.handle(
      tool_context("create_document", %({"id": "doc_1", "meta": {}}), response),
      ->(_c : Agent::ToolCallContext) { msg },
    )

    response.cancelled?.should be_true
  end

  it "does not cancel on the first terminal envelope of a different key" do
    response = Agent::Response.new
    stop = handler

    stop.handle(
      tool_context("create_document", %({"id": "doc_1"}), response),
      ->(_c : Agent::ToolCallContext) { tool_message(terminal_envelope("create_document")) },
    )
    response.cancelled?.should be_false

    stop.handle(
      tool_context("delete_document", %({"id": "doc_1"}), response),
      ->(_c : Agent::ToolCallContext) { tool_message(terminal_envelope("delete_document")) },
    )

    response.cancelled?.should be_false
  end

  [
    {"normal error envelope", %({"ok":false,"error":"Tool 'create_document' refused","details":{"reason":"rbac_denied"}})},
    {"success envelope", %({"ok":true,"data":{"status":"created"}})},
    {"agent-cr callback failure", "Error executing tool 'create_document': boom"},
    {"plain text", "Sunny, 18 degrees in Paris"},
  ].each do |kind, content|
    it "never cancels on a #{kind}" do
      response = Agent::Response.new
      msg = tool_message(content)
      ctx = tool_context("create_document", %({"id": "doc_1"}), response)
      stop = handler

      result = stop.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })
      result.should be(msg)

      # A repeat of the same non-terminal result must not trip the guard.
      stop.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

      response.cancelled?.should be_false
    end
  end

  it "cancels only the repeated key and passes messages through" do
    response = Agent::Response.new
    stop = handler
    refused = tool_message(terminal_envelope("create_document"))
    other = tool_message(terminal_envelope("delete_document"))
    refused_ctx = tool_context("create_document", %({"id": "doc_1"}), response)
    other_ctx = tool_context("delete_document", %({"id": "doc_1"}), response)

    stop.handle(refused_ctx, ->(_c : Agent::ToolCallContext) { refused })
    stop.handle(other_ctx, ->(_c : Agent::ToolCallContext) { other })
    response.cancelled?.should be_false

    result = stop.handle(refused_ctx, ->(_c : Agent::ToolCallContext) { refused })

    result.should be(refused)
    response.cancelled?.should be_true
  end
end
