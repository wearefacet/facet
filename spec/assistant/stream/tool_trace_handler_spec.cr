# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/stream/tool_trace_handler"

# Unit tests for `ToolTraceHandler`. Each example drives `handle` with a fake
# `next_proc` and asserts the event sequence the `on_event` callback gets:
# `running` before the tool result, then `ok` or `error` read from the
# tool-result message content.

# Event tuple the handler publishes; mirrors the write callback signature in
# `Session#make_tool_trace_handler`.
private alias TraceEvent = {name: String, status: String, detail: String?, result: String?, arguments: String?}

# agent-cr prefixes a failed tool-result message with one of these sentinels:
# a raised callback, schema validation, or JSON parsing of the arguments.
# Each must produce a running/error pair, never ok.
private ERROR_RESULTS = [
  {"callback failure", "Error executing tool 'lookup_weather': boom"},
  {"schema-validation failure", "Error validating arguments for tool 'lookup_weather': Missing required field 'city'"},
  {"argument-parse failure", "Error parsing arguments for tool 'lookup_weather': invalid JSON"},
]

# Builds a handler that appends every emitted event to `events`.
private def build_handler(events : Array(TraceEvent)) : Facet::Assistant::Stream::ToolTraceHandler
  callback = ->(event : TraceEvent) {
    events << event
    nil
  }
  Facet::Assistant::Stream::ToolTraceHandler.new(callback)
end

private def tool_context(name : String, arguments : String) : Agent::ToolCallContext
  tool_call = Agent::ToolCall.new(id: "call_1", name: name, arguments: arguments)
  Agent::ToolCallContext.new(tool_call, Agent::Response.new)
end

private def tool_result(content : String) : Agent::Message
  Agent::Message.new(role: Agent::Role::Tool, content: content, tool_call_id: "call_1", name: "lookup_weather")
end

describe Facet::Assistant::Stream::ToolTraceHandler do
  it "emits running then ok for a normal tool result" do
    events = [] of TraceEvent
    handler = build_handler(events)
    msg = tool_result("Sunny, 18 degrees in Paris")
    ctx = tool_context("lookup_weather", %({"city": "Paris"}))

    result = handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    result.should be(msg)
    events.map { |e| e[:status] }.should eq(["running", "ok"])
    events[0][:name].should eq("lookup_weather")
    events[0][:detail].should eq("city=Paris")
    events[1][:result].should eq("Sunny, 18 degrees in Paris")
  end

  # B-375: container argument values serialize as JSON, scalars stay
  # unwrapped — the chip must never show Crystal's inspect notation.
  it "renders nested argument values as JSON in the detail" do
    events = [] of TraceEvent
    handler = build_handler(events)
    msg = tool_result("ok")
    args = %({"name": "Expense", "count": 3, "rate": 1.5, "active": true,
              "tags": ["travel", "meals"], "nullable": null,
              "definition": {"domain": "axt", "label": "AXT"}})
    ctx = tool_context("create_doctype", args)

    handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    events[0][:detail].should eq(
      "name=Expense, count=3, rate=1.5, active=true, " \
      "tags=[\"travel\",\"meals\"], nullable=null, " \
      "definition={\"domain\":\"axt\",\"label\":\"AXT\"}"
    )
  end

  it "emits running with no detail when the arguments are not JSON" do
    events = [] of TraceEvent
    handler = build_handler(events)
    msg = tool_result("ok")
    ctx = tool_context("lookup_weather", "not-json")

    handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    events[0][:status].should eq("running")
    events[0][:detail].should be_nil
  end

  ERROR_RESULTS.each do |kind, content|
    it "emits running then error for a #{kind}" do
      events = [] of TraceEvent
      handler = build_handler(events)
      msg = tool_result(content)
      ctx = tool_context("lookup_weather", %({"city": "Paris"}))

      result = handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

      result.should be(msg)
      events.map { |e| e[:status] }.should eq(["running", "error"])
      events[1][:result].should eq(content)
    end
  end

  # B-368: the registrars render a refused or failed tool call as the
  # envelope {"ok":false,...}. It matches none of the agent-cr prefixes, so
  # the handler must classify it as an error on its own. Leading whitespace
  # is tolerated; the success envelope stays ok.
  it "emits running then error for a registrar error envelope" do
    events = [] of TraceEvent
    handler = build_handler(events)
    content = %({"ok":false,"error":"Tool 'delete_document' refused","details":{"reason":"rbac_denied"}})
    msg = tool_result(content)
    ctx = tool_context("delete_document", %({"id": "doc_1"}))

    result = handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    result.should be(msg)
    events.map { |e| e[:status] }.should eq(["running", "error"])
    events[1][:result].should eq(content)
  end

  it "emits error for a registrar error envelope with leading whitespace" do
    events = [] of TraceEvent
    handler = build_handler(events)
    msg = tool_result(" \n\t" + %({"ok":false,"error":"Tool 'delete_document' refused"}))
    ctx = tool_context("delete_document", %({"id": "doc_1"}))

    handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    events.map { |e| e[:status] }.should eq(["running", "error"])
  end

  it "emits ok for a success envelope" do
    events = [] of TraceEvent
    handler = build_handler(events)
    msg = tool_result(%({"ok":true,"data":{"status":"deleted"}}))
    ctx = tool_context("delete_document", %({"id": "doc_1"}))

    handler.handle(ctx, ->(_c : Agent::ToolCallContext) { msg })

    events.map { |e| e[:status] }.should eq(["running", "ok"])
  end
end
