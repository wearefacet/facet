# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "agent-cr"
require "../spec_helper"
require "../../src/assistant"

# Builds a `Agent::Message` → JSON string suitable for the `agent_turns`
# jsonb columns, mirroring how the service layer would serialise real
# `Agent#ask` output at the persisted boundary.
def messages_json(messages : Array(Agent::Message)) : String
  JSON.build { |json| json.array { messages.each(&.to_json(json)) } }
end

def usage_json(prompt : Int32, completion : Int32) : String
  Agent::Usage.new(
    prompt_tokens: prompt,
    completion_tokens: completion,
    total_tokens: prompt + completion,
  ).to_json
end

# Spawns a conversation row for the status-lifecycle specs.
def spawn_test_conversation(db, session_id : String)
  Facet::Assistant::Conversation.create(
    db, session_id, "cache-#{session_id}", nil,
  ).as(Facet::Assistant::Conversation::Result::Created).record
end

describe Facet::Assistant::Conversation do
  describe ".create" do
    it "persists a conversation with the conversation-stored prompt" do
      with_db do |db|
        result = Facet::Assistant::Conversation.create(
          db,
          session_id: "sess-001",
          cache_key: "cache-001",
          system_prompt: "You are a test assistant.",
          context: %({"kind": "doctype-design", "domain": "hr"}),
          enabled_tools: %(["list_documents", "search"]),
        )

        result.should be_a(Facet::Assistant::Conversation::Result::Created)
        rec = result.as(Facet::Assistant::Conversation::Result::Created).record

        rec.id.should_not be_empty
        rec.session_id.should eq("sess-001")
        rec.cache_key.should eq("cache-001")
        rec.system_prompt.should eq("You are a test assistant.")
        rec.context["kind"].as_s.should eq("doctype-design")
        rec.enabled_tools.as_a.map(&.as_s).should eq(["list_documents", "search"])

        # Round-trip: the persisted row is retrievable by .find.
        found = Facet::Assistant::Conversation.find(db, rec.id)
        found.should_not be_nil
        found.not_nil!.session_id.should eq("sess-001")
      end
    end

    it "defaults context and enabled_tools to empty jsonb" do
      with_db do |db|
        result = Facet::Assistant::Conversation.create(
          db,
          session_id: "sess-empty",
          cache_key: "cache-empty",
          system_prompt: nil,
        )

        rec = result.as(Facet::Assistant::Conversation::Result::Created).record
        rec.context.raw.should eq({} of String => JSON::Any)
        rec.enabled_tools.raw.should eq([] of JSON::Any)
        rec.archived_at.should be_nil
      end
    end
  end

  describe ".set_archived" do
    it "stamps archived_at, then clears it" do
      with_db do |db|
        conv = spawn_test_conversation(db, "sess-archive")
        conv.archived_at.should be_nil

        set = Facet::Assistant::Conversation.set_archived(db, conv.id, true)
        set.should be_true
        archived = Facet::Assistant::Conversation.find(db, conv.id).not_nil!
        archived.archived_at.should_not be_nil

        cleared = Facet::Assistant::Conversation.set_archived(db, conv.id, false)
        cleared.should be_true
        live = Facet::Assistant::Conversation.find(db, conv.id).not_nil!
        live.archived_at.should be_nil
      end
    end

    it "answers false for an unknown id" do
      with_db do |db|
        Facet::Assistant::Conversation.set_archived(db, "01NONEXISTENT0000000000000000", true).should be_false
      end
    end
  end

  describe ".list archive visibility" do
    it "hides archived rows by default and shows them under archived__eq=true" do
      with_db do |db|
        live = spawn_test_conversation(db, "sess-vis-live")
        gone = spawn_test_conversation(db, "sess-vis-gone")
        Facet::Assistant::Conversation.set_archived(db, gone.id, true).should be_true

        default_list = Facet::Assistant::Conversation.list(db)
        default_list.map(&.id).should eq([live.id])

        archived_list = Facet::Assistant::Conversation.list(
          db,
          filters: {"archived__eq" => JSON::Any.new(true)},
        )
        archived_list.map(&.id).should eq([gone.id])

        # A string value arrives over the query-string form; a malformed one
        # keeps the live-only default.
        string_list = Facet::Assistant::Conversation.list(
          db,
          filters: {"archived__eq" => JSON::Any.new("true")},
        )
        string_list.map(&.id).should eq([gone.id])

        garbage_list = Facet::Assistant::Conversation.list(
          db,
          filters: {"archived__eq" => JSON::Any.new("banana")},
        )
        garbage_list.map(&.id).should eq([live.id])

        explicit_live = Facet::Assistant::Conversation.list(
          db,
          filters: {"archived__eq" => JSON::Any.new(false)},
        )
        explicit_live.map(&.id).should eq([live.id])
      end
    end

    it "applies the archive visibility to the capped count" do
      with_db do |db|
        live = spawn_test_conversation(db, "sess-count-live")
        gone = spawn_test_conversation(db, "sess-count-gone")
        Facet::Assistant::Conversation.set_archived(db, gone.id, true).should be_true

        Facet::Assistant::Conversation.count(db, {} of String => JSON::Any, 0).should eq(1)
        Facet::Assistant::Conversation.count(
          db, {"archived__eq" => JSON::Any.new(true)}, 0,
        ).should eq(1)
        live.id.should_not be_empty
      end
    end
  end
end

describe Facet::Assistant::Turn do
  it "assigns sequential idx within a conversation and lists turns in order" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-turns", "cache-turns", nil,
      ).as(Facet::Assistant::Conversation::Result::Created).record

      req1 = messages_json([Agent::Message.user("hello")])
      resp1 = messages_json([Agent::Message.assistant("hi")])
      t1 = Facet::Assistant::Turn.create(
        db, conv.id, req1, resp1, usage_json(10, 5),
        finish_reason: "stop",
      ).as(Facet::Assistant::Turn::Result::Created).record
      t1.idx.should eq(1)

      req2 = messages_json([Agent::Message.user("and then?")])
      resp2 = messages_json([Agent::Message.assistant("more")])
      t2 = Facet::Assistant::Turn.create(
        db, conv.id, req2, resp2, usage_json(20, 8),
        finish_reason: "stop",
      ).as(Facet::Assistant::Turn::Result::Created).record
      t2.idx.should eq(2)

      turns = Facet::Assistant::Turn.list(db, conv.id)
      turns.map(&.idx).should eq([1, 2])
      turns.first.request_messages.as_a.first["content"].as_s.should eq("hello")
      turns.last.response_messages.as_a.first["content"].as_s.should eq("more")
      turns.last.usage["prompt_tokens"].as_i.should eq(20)
    end
  end

  it "computes idx per-conversation, not globally" do
    with_db do |db|
      a = Facet::Assistant::Conversation.create(
        db, "sess-a", "cache-a", nil,
      ).as(Facet::Assistant::Conversation::Result::Created).record

      b = Facet::Assistant::Conversation.create(
        db, "sess-b", "cache-b", nil,
      ).as(Facet::Assistant::Conversation::Result::Created).record

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("yo")])

      ta = Facet::Assistant::Turn.create(db, a.id, req, resp, usage_json(1, 1)).as(Facet::Assistant::Turn::Result::Created).record
      tb = Facet::Assistant::Turn.create(db, b.id, req, resp, usage_json(1, 1)).as(Facet::Assistant::Turn::Result::Created).record

      ta.idx.should eq(1)
      tb.idx.should eq(1)
    end
  end

  it "persists an error turn with finish_reason nil" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-touch", "cache-touch", nil,
      ).as(Facet::Assistant::Conversation::Result::Created).record

      req = messages_json([Agent::Message.user("boom")])
      resp = messages_json([Agent::Message.assistant("Agent error: boom")])
      t = Facet::Assistant::Turn.create(
        db, conv.id, req, resp, usage_json(0, 0),
        error: "boom",
      ).as(Facet::Assistant::Turn::Result::Created).record

      t.finish_reason.should be_nil
      t.error.should eq("boom")
      # Status derives from the error: a non-cancel error is `error`.
      t.status.should eq("error")
    end
  end
end

describe "Facet::Assistant::Turn — status lifecycle" do
  it "opens a running row and completes it to done" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-lifecycle")

      opened = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("hi")]),
      )
      opened.should be_a(Facet::Assistant::Turn::Result::Created)
      row = opened.as(Facet::Assistant::Turn::Result::Created).record
      row.status.should eq("running")
      row.response_messages.as_a.should be_empty

      # Exactly one row, still running, visible to both lookup surfaces.
      Facet::Assistant::Turn.list(db, conv.id).size.should eq(1)
      Facet::Assistant::Turn.running_turn(db, conv.id).not_nil!.id.should eq(row.id)
      Facet::Assistant::Turn.latest(db, conv.id).not_nil!.status.should eq("running")

      completed = Facet::Assistant::Turn.complete(
        db,
        turn_id: row.id,
        response_messages_json: messages_json([Agent::Message.assistant("yo")]),
        usage_json: usage_json(3, 2),
        status: "done",
        finish_reason: "stop",
      )
      completed.should be_true

      after = Facet::Assistant::Turn.list(db, conv.id).first
      after.status.should eq("done")
      after.finish_reason.should eq("stop")
      after.error.should be_nil
      after.usage["prompt_tokens"].as_i.should eq(3)
      Facet::Assistant::Turn.running_turn(db, conv.id).should be_nil
    end
  end

  it "rejects a second open while one turn is running" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-conflict")

      Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("first")]),
      ).as(Facet::Assistant::Turn::Result::Created)

      second = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("second")]),
      )
      second.should be_a(Facet::Assistant::Turn::Result::Conflict)

      # A completed turn frees the conversation for the next one.
      running_id = Facet::Assistant::Turn.running_turn(db, conv.id).not_nil!.id
      Facet::Assistant::Turn.complete(
        db, turn_id: running_id, response_messages_json: "[]",
        usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
      )

      third = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("third")]),
      )
      third.should be_a(Facet::Assistant::Turn::Result::Created)
    end
  end

  it "sweeps stale running rows to error interrupted, and only those" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-sweep")

      stale = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("old")]),
      ).as(Facet::Assistant::Turn::Result::Created).record

      # Backdate the stale row beyond the timeout window.
      db.exec(
        "UPDATE agent_turns SET created_at = now() - interval '20 minutes' WHERE id = $1",
        stale.id,
      )

      # A fresh running row in a DIFFERENT conversation must survive.
      other = spawn_test_conversation(db, "sess-sweep-other")
      Facet::Assistant::Turn.open(
        db, other.id, messages_json([Agent::Message.user("new")]),
      ).as(Facet::Assistant::Turn::Result::Created)

      swept = Facet::Assistant::Turn.sweep_stale_running(db, 900)
      swept.should eq(1)

      stale_row = Facet::Assistant::Turn.list(db, conv.id).first
      stale_row.status.should eq("error")
      stale_row.error.should eq("interrupted")

      fresh_row = Facet::Assistant::Turn.list(db, other.id).first
      fresh_row.status.should eq("running")
    end
  end

  it "touches the conversation updated_at on turn create" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-touch", "cache-touch", nil,
      ).as(Facet::Assistant::Conversation::Result::Created).record

      # Backdate the row so the turn bump writes a fresh now() against a
      # row one hour old; the assertion then holds by construction.
      db.exec(
        "UPDATE agent_conversations SET updated_at = now() - interval '1 hour' WHERE id = $1",
        conv.id,
      )

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("yo")])
      Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1))

      after = Facet::Assistant::Conversation.find(db, conv.id).not_nil!
      after.updated_at.should be > conv.updated_at
    end
  end

  it "unarchives an archived conversation on turn create" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-unarchive-create")
      Facet::Assistant::Conversation.set_archived(db, conv.id, true).should be_true

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("yo")])
      Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1))

      Facet::Assistant::Conversation.find(db, conv.id).not_nil!.archived_at.should be_nil
    end
  end

  it "unarchives an archived conversation on turn open" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-unarchive-open")
      Facet::Assistant::Conversation.set_archived(db, conv.id, true).should be_true

      Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("hi")]),
      ).as(Facet::Assistant::Turn::Result::Created)

      Facet::Assistant::Conversation.find(db, conv.id).not_nil!.archived_at.should be_nil
    end
  end

  it "keeps a live conversation live on turn create (no archive churn)" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-stay-live")

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("yo")])
      Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1))

      Facet::Assistant::Conversation.find(db, conv.id).not_nil!.archived_at.should be_nil
    end
  end

  it "persists the turn token on open and surfaces it on every reader" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-token")

      opened = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("hi")]), "token-123",
      ).as(Facet::Assistant::Turn::Result::Created).record
      opened.turn_token.should eq("token-123")

      Facet::Assistant::Turn.running_turn(db, conv.id).not_nil!.turn_token.should eq("token-123")
      Facet::Assistant::Turn.list(db, conv.id).first.turn_token.should eq("token-123")
      Facet::Assistant::Turn.latest(db, conv.id).not_nil!.turn_token.should eq("token-123")

      # The terminal row keeps its token — a client polling the catch-up
      # endpoint after completion still reads the same value.
      Facet::Assistant::Turn.complete(
        db, turn_id: opened.id, response_messages_json: "[]",
        usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
      )
      Facet::Assistant::Turn.latest(db, conv.id).not_nil!.turn_token.should eq("token-123")
    end
  end

  it "leaves the turn token nil for manual and terminal inserts" do
    with_db do |db|
      conv = spawn_test_conversation(db, "sess-token-nil")

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("yo")])
      row = Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1))
        .as(Facet::Assistant::Turn::Result::Created).record
      row.turn_token.should be_nil
    end
  end

  describe ".running?" do
    it "tracks the running-turn lifecycle" do
      with_db do |db|
        conv = spawn_test_conversation(db, "sess-running-q")
        Facet::Assistant::Turn.running?(db, conv.id).should be_false

        opened = Facet::Assistant::Turn.open(
          db, conv.id, messages_json([Agent::Message.user("hi")]), "token-1",
        ).as(Facet::Assistant::Turn::Result::Created).record
        Facet::Assistant::Turn.running?(db, conv.id).should be_true

        Facet::Assistant::Turn.complete(
          db, turn_id: opened.id, response_messages_json: "[]",
          usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
        )
        Facet::Assistant::Turn.running?(db, conv.id).should be_false
      end
    end

    it "answers false for an unknown conversation" do
      with_db do |db|
        Facet::Assistant::Turn.running?(db, "01NONEXISTENT0000000000000000").should be_false
      end
    end
  end

  describe ".running_conversation_ids" do
    it "returns exactly the conversations with a running turn" do
      with_db do |db|
        busy = spawn_test_conversation(db, "sess-rcids-busy")
        idle = spawn_test_conversation(db, "sess-rcids-idle")
        settled = spawn_test_conversation(db, "sess-rcids-settled")

        opened = Facet::Assistant::Turn.open(
          db, busy.id, messages_json([Agent::Message.user("hi")]), "token-1",
        ).as(Facet::Assistant::Turn::Result::Created).record
        done_row = Facet::Assistant::Turn.open(
          db, settled.id, messages_json([Agent::Message.user("yo")]), "token-2",
        ).as(Facet::Assistant::Turn::Result::Created).record
        Facet::Assistant::Turn.complete(
          db, turn_id: done_row.id, response_messages_json: "[]",
          usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
        )

        ids = Facet::Assistant::Turn.running_conversation_ids(db)
        ids.should contain(busy.id)
        ids.should_not contain(idle.id)
        ids.should_not contain(settled.id)

        Facet::Assistant::Turn.complete(
          db, turn_id: opened.id, response_messages_json: "[]",
          usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
        )
        Facet::Assistant::Turn.running_conversation_ids(db).should_not contain(busy.id)
      end
    end
  end

  describe ".checkpoint" do
    it "persists the partial exchange into the running row" do
      with_db do |db|
        conv = spawn_test_conversation(db, "sess-checkpoint")
        turn_id = Facet::Assistant::Turn.open(
          db, conv.id, messages_json([Agent::Message.user("hi")]), "token-1",
        ).as(Facet::Assistant::Turn::Result::Created).record.id

        partial = messages_json([
          Agent::Message.assistant(tool_calls: [Agent::ToolCall.new(id: "tc1", name: "lookup", arguments: "{}")]),
          Agent::Message.tool_result(Agent::ToolCall.new(id: "tc1", name: "lookup", arguments: "{}"), "ok"),
        ])
        Facet::Assistant::Turn.checkpoint(db, turn_id, partial).should be_true

        row = Facet::Assistant::Turn.list(db, conv.id).first
        row.status.should eq("running")
        row.response_messages.as_a.size.should eq(2)
        row.response_messages.as_a.last["role"].as_s.should eq("tool")
      end
    end

    it "is a no-op once the row reached a terminal state" do
      with_db do |db|
        conv = spawn_test_conversation(db, "sess-checkpoint-done")
        turn_id = Facet::Assistant::Turn.open(
          db, conv.id, messages_json([Agent::Message.user("hi")]), "token-1",
        ).as(Facet::Assistant::Turn::Result::Created).record.id
        Facet::Assistant::Turn.complete(
          db, turn_id: turn_id, response_messages_json: "[]",
          usage_json: usage_json(0, 0), status: "done", finish_reason: "stop",
        )

        partial = messages_json([Agent::Message.assistant("late")])
        Facet::Assistant::Turn.checkpoint(db, turn_id, partial).should be_false

        row = Facet::Assistant::Turn.list(db, conv.id).first
        row.status.should eq("done")
        row.response_messages.as_a.should be_empty
      end
    end
  end

  describe ".latest" do
    it "carries the row's messages to the catch-up poll" do
      with_db do |db|
        conv = spawn_test_conversation(db, "sess-latest-msgs")
        req = messages_json([Agent::Message.user("hi")])
        resp = messages_json([Agent::Message.assistant("hello")])
        Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1), finish_reason: "stop")

        latest = Facet::Assistant::Turn.latest(db, conv.id).not_nil!
        latest.status.should eq("done")
        latest.request_messages.as_a.size.should eq(1)
        latest.request_messages.as_a.first["content"].as_s.should eq("hi")
        latest.response_messages.as_a.first["content"].as_s.should eq("hello")
      end
    end
  end
end

describe Facet::Assistant::Resume do
  it "reconstructs history by concatenating turns in idx order" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-resume", "cache-resume", "You are a test assistant.",
        context: %({"kind": "general-assistance"}),
        enabled_tools: %(["search"]),
      ).as(Facet::Assistant::Conversation::Result::Created).record

      req1 = messages_json([Agent::Message.user("first")])
      resp1 = messages_json([Agent::Message.assistant("reply1")])
      Facet::Assistant::Turn.create(db, conv.id, req1, resp1, usage_json(10, 5), finish_reason: "stop")

      req2 = messages_json([Agent::Message.user("second")])
      resp2 = messages_json([Agent::Message.assistant("reply2")])
      Facet::Assistant::Turn.create(db, conv.id, req2, resp2, usage_json(20, 8), finish_reason: "stop")

      result = Facet::Assistant::Resume.call(db, conv.id)
      result.should be_a(Facet::Assistant::Resume::Result::Restored)
      session = result.as(Facet::Assistant::Resume::Result::Restored).session

      session.history.size.should eq(4)
      roles = session.history.map(&.role.to_s)
      roles.should eq(["user", "assistant", "user", "assistant"])
      session.history[0].content.should eq("first")
      session.history[3].content.should eq("reply2")

      # The conversation-stored prompt rides the record — the turn start
      # overlays it on the effective settings view.
      session.conversation.system_prompt.should eq("You are a test assistant.")

      # The session_json has the shape Agent#load consumes.
      parsed = JSON.parse(session.session_json)
      parsed["version"].as_i.should eq(1)
      parsed["session_id"].as_s.should eq("sess-resume")
      parsed["cache_key"].as_s.should eq("cache-resume")
      parsed["history"].as_a.size.should eq(4)
      parsed["enabled_tools"].as_a.map(&.as_s).should eq(["search"])
    end
  end

  it "returns a 404 error for an unknown conversation" do
    with_db do |db|
      result = Facet::Assistant::Resume.call(db, "01NONEXISTENT0000000000000000")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
    end
  end

  it "replays done and cancelled turns, and skips running and error turns" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-replay-filter", "cache-replay-filter", "sys",
      ).as(Facet::Assistant::Conversation::Result::Created).record

      # Turn 1 — done. Both sides replay.
      Facet::Assistant::Turn.create(
        db, conv.id,
        messages_json([Agent::Message.user("first")]),
        messages_json([Agent::Message.assistant("reply1")]),
        usage_json(1, 1), finish_reason: "stop")

      # Turn 2 — cancelled with a partial response. The partial context
      # MUST replay (the next ask resumes where the cancel left off).
      Facet::Assistant::Turn.create(
        db, conv.id,
        messages_json([Agent::Message.user("second")]),
        messages_json([Agent::Message.assistant("partial")]),
        usage_json(0, 0), error: "cancelled")

      # Turn 3 — terminal error, empty response. MUST be skipped: its
      # request was never consumed by the provider.
      Facet::Assistant::Turn.create(
        db, conv.id,
        messages_json([Agent::Message.user("failed")]),
        "[]", usage_json(0, 0), error: "provider down")

      # Turn 4 — capped at the tool-loop limit. The partial exchange (a
      # complete assistant tool_calls + tool-result pair) MUST replay: the
      # next ask continues from the committed work. Built with open +
      # complete — the same path the session uses — because Turn.create
      # derives its status from the error string (this error would become
      # status "error", and Resume would skip the row).
      capped = Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("build it")]),
      ).as(Facet::Assistant::Turn::Result::Created).record
      Facet::Assistant::Turn.complete(
        db, turn_id: capped.id,
        response_messages_json: messages_json([
          Agent::Message.assistant(tool_calls: [Agent::ToolCall.new(id: "tc1", name: "create_doctype", arguments: "{}")]),
          Agent::Message.tool_result(Agent::ToolCall.new(id: "tc1", name: "create_doctype", arguments: "{}"), "{\"ok\":true}"),
        ]),
        usage_json: usage_json(0, 0),
        status: "capped",
        error: "Agent error: tool call iteration limit (100) exceeded",
      )

      # Turn 5 — still running. MUST be skipped: no response yet.
      Facet::Assistant::Turn.open(
        db, conv.id, messages_json([Agent::Message.user("in flight")]),
      ).as(Facet::Assistant::Turn::Result::Created)

      result = Facet::Assistant::Resume.call(db, conv.id)
      session = result.as(Facet::Assistant::Resume::Result::Restored).session

      roles = session.history.map(&.role.to_s)
      roles.should eq(["user", "assistant", "user", "assistant", "user", "assistant", "tool"])
      session.history[0].content.should eq("first")
      session.history[2].content.should eq("second")
      session.history[3].content.should eq("partial")
      session.history[4].content.should eq("build it")
      session.history[6].tool_call_id.should eq("tc1")
    end
  end

  it "restores an Agent via Agent#load from the reconstructed session_json" do
    with_db do |db|
      conv = Facet::Assistant::Conversation.create(
        db, "sess-agentload", "cache-agentload", "sys",
      ).as(Facet::Assistant::Conversation::Result::Created).record

      req = messages_json([Agent::Message.user("hi")])
      resp = messages_json([Agent::Message.assistant("hello")])
      Facet::Assistant::Turn.create(db, conv.id, req, resp, usage_json(1, 1), finish_reason: "stop")

      session = Facet::Assistant::Resume.call(db, conv.id)
        .as(Facet::Assistant::Resume::Result::Restored).session

      # The turn start builds the config from the effective settings view;
      # the replay needs only the session_json.
      config = Facet::SystemSettings::AssistantView.build(db, session.conversation.system_prompt)
      agent = Agent.new(config.to_agent_config)
      agent.load(session.session_json)

      agent.session_id.should eq("sess-agentload")
      agent.cache_key.should eq("cache-agentload")
      agent.history.size.should eq(2)
      agent.history[0].content.should eq("hi")
      agent.history[1].content.should eq("hello")

      agent.close
    end
  end
end
