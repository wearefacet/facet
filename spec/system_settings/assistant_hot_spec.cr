# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Stage-1 hot-change specs for the assistant connection: the model, key,
# and sampling knobs resolve from the effective settings at every turn
# start, so a settings save reaches EXISTING conversations on their next
# turn (same-provider switches are the verified path; cross-provider replay
# stays a documented limit). The stored prompt stays conversation data.
require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../../src/assistant/stream/session"
require "../../src/assistant/stream/cancel_bus"
require "../../src/assistant/conversation"
require "../../src/assistant/turn"
require "../../src/assistant/resume"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "http"
require "json"

# A minimal OpenAI-compatible mock that reports which model it served, so
# the spec can observe the turn-time model resolution end to end.
class HotChangeMockLLM
  getter port : Int32
  getter models : Array(String)
  @server : HTTP::Server

  def initialize
    @models = [] of String
    @server = HTTP::Server.new do |ctx|
      handle(ctx)
    end
    @port = @server.bind_tcp(0).port
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    body = begin
      ctx.request.body.try(&.gets_to_end) || "{}"
    rescue
      "{}"
    end
    model = JSON.parse(body)["model"].as_s
    @models << model
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    chunk = {
      choices: [{
        delta: {content: "ok"},
        index: 0,
      }],
    }
    ctx.response.puts "data: #{chunk.to_json}"

    final = {
      choices: [{
        delta:         {} of String => JSON::Any,
        index:         0,
        finish_reason: "stop",
      }],
      usage: {
        prompt_tokens:     10,
        completion_tokens: 5,
        total_tokens:      15,
      },
    }
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end
end

# Pins one assistant settings path on the singleton (the same save an
# admin makes through the document route).
private def pin_setting(db, patch : String) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

private def new_conversation(db, session_suffix : String) : String
  result = Facet::Assistant::Conversation.create(
    db,
    session_id: "sess-hot-#{session_suffix}",
    cache_key: "cache-hot-#{session_suffix}",
    system_prompt: "stored prompt",
  )
  result.as(Facet::Assistant::Conversation::Result::Created).record.id
end

private def open_turn(db, conversation_id : String, content : String) : String
  result = Facet::Assistant::Turn.open(
    db, conversation_id,
    Facet::Assistant::Stream::Session.request_messages_json(content),
  )
  result.as(Facet::Assistant::Turn::Result::Created).record.id
end

describe "Assistant hot settings" do
  redis_url = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

  before_each do
    Facet::SystemSettings.reset_cache!
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "switches an existing conversation to the changed model at its next turn" do
    server = HotChangeMockLLM.new
    begin
      with_db do |db|
        pin_setting(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1", "model": "model-a"}}))

        conversation_id = new_conversation(db, "model")
        turn_id = open_turn(db, conversation_id, "hello")

        capture = SSERamCapture.new
        session = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "hello")
        session.run(capture, redis_url, 5, turn_id)

        server.models.should eq(["model-a"])

        # The admin changes the model; no restart, no new conversation.
        pin_setting(db, %({"assistant": {"model": "model-b"}}))

        turn_id2 = open_turn(db, conversation_id, "again")
        capture2 = SSERamCapture.new
        session2 = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "again")
        session2.run(capture2, redis_url, 5, turn_id2)

        # The SAME conversation now runs on model B.
        server.models.should eq(["model-a", "model-b"])
      end
    ensure
      server.close
    end
  end

  it "records the per-turn model on the usage ledger" do
    server = HotChangeMockLLM.new
    begin
      with_db do |db|
        pin_setting(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1", "model": "model-a"}}))
        conversation_id = new_conversation(db, "ledger")

        turn_id = open_turn(db, conversation_id, "hello")
        session = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "hello", account_id: "acct-hot")
        session.run(SSERamCapture.new, redis_url, 5, turn_id)

        pin_setting(db, %({"assistant": {"model": "model-b"}}))
        turn_id2 = open_turn(db, conversation_id, "again")
        session2 = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "again", account_id: "acct-hot")
        session2.run(SSERamCapture.new, redis_url, 5, turn_id2)

        models = db.query_all(
          "SELECT model FROM assistant_usage WHERE conversation_id = $1 ORDER BY recorded_at",
          conversation_id,
          as: String?,
        )
        models.should eq(["model-a", "model-b"])
      end
    ensure
      server.close
    end
  end

  it "reaches the next turn after a key rotation" do
    server = HotChangeMockLLM.new
    begin
      with_db do |db|
        handle = "sh_" + Facet::Util::ScriptHelpers.ulid
        payload = Facet::Secrets::Codec.seal("sk-first", Facet::Secrets::Staging.doc_ref(handle), "assistant.api_key")
        Facet::Secrets::Staging.insert(db, "sealed", payload, "core", "SystemSettings", "assistant.api_key", "system", handle: handle)
        pin_setting(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1", "api_key": "#{handle}"}}))

        conversation_id = new_conversation(db, "key")
        turn_id = open_turn(db, conversation_id, "hello")
        session = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "hello")
        session.run(SSERamCapture.new, redis_url, 5, turn_id)
        server.models.size.should eq(1) # the first turn went through with key v1

        # Rotate: stage + adopt a new key — a normal settings save.
        handle2 = "sh_" + Facet::Util::ScriptHelpers.ulid
        payload2 = Facet::Secrets::Codec.seal("sk-second", Facet::Secrets::Staging.doc_ref(handle2), "assistant.api_key")
        Facet::Secrets::Staging.insert(db, "sealed", payload2, "core", "SystemSettings", "assistant.api_key", "system", handle: handle2)
        pin_setting(db, %({"assistant": {"api_key": "#{handle2}"}}))

        turn_id2 = open_turn(db, conversation_id, "again")
        session2 = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "again")
        session2.run(SSERamCapture.new, redis_url, 5, turn_id2)

        # Both turns reached the provider — the rotation took effect.
        server.models.size.should eq(2)
        Facet::SystemSettings.reveal_secret(db, "assistant.api_key").should eq("sk-second")
      end
    ensure
      server.close
    end
  end

  it "keeps the stored prompt on the conversation row across a prompt change" do
    server = HotChangeMockLLM.new
    begin
      with_db do |db|
        pin_setting(db, %({"assistant": {"api_endpoint": "http://localhost:#{server.port}/v1", "model": "m"}}))
        conversation_id = new_conversation(db, "prompt")

        turn_id = open_turn(db, conversation_id, "hello")
        session = Facet::Assistant::Stream::Session.new(db, conversation_id: conversation_id, content: "hello")
        result = session.run(SSERamCapture.new, redis_url, 5, turn_id)
        result.error.should be_nil

        # The turn succeeded against the mock — the stored prompt rode the
        # request (agent-cr sends the system prompt on every call; a prompt
        # mismatch would not fail here, so assert the resolution directly).
        conv = Facet::Assistant::Conversation.find(db, conversation_id).not_nil!
        view = Facet::SystemSettings::AssistantView.build(db, conv.system_prompt)
        view.system_prompt.should eq("stored prompt")

        # A settings prompt change does not retroactively rewrite the row.
        pin_setting(db, %({"assistant": {"system_prompt": "new persona"}}))
        view2 = Facet::SystemSettings::AssistantView.build(db, conv.system_prompt)
        view2.system_prompt.should eq("stored prompt")

        # A conversation with NO stored prompt follows the setting.
        view3 = Facet::SystemSettings::AssistantView.build(db, nil)
        view3.system_prompt.should eq("new persona")
      end
    ensure
      server.close
    end
  end
end

# A no-op SSE sink for the hot-change specs — the assertions read the mock
# server and the DB, not the wire.
class SSERamCapture < IO
  getter chunks : Array(String) = [] of String

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @chunks << String.new(slice)
  end

  def flush : Nil
  end

  def to_s : String
    @chunks.join
  end
end
