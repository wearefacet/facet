# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/assistant"
require "../support/http_helper"
require "json"

HTTPTest.init

# Builds a JSON body for creating a conversation.
# The backend owns the connection (model/endpoint/key), the system prompt,
# session_id, and cache_key — the frontend can only supply context,
# enabled_tools, and language (all optional).
private def conversation_body
  %({
    "context": {"kind":"general-assistance"},
    "enabled_tools": ["search", "list_documents"]
  })
end

private def post_json(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  call_api(HTTP::Request.new("POST", path, headers: headers, body: body))
end

# POSTs without the CSRF header — used by the CSRF rejection cases.
private def post_json_no_csrf(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  call_api_raw(HTTP::Request.new("POST", path, headers: headers, body: body))
end

private def get_json(path) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", path))
end

private def patch_json(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  call_api(HTTP::Request.new("PATCH", path, headers: headers, body: body))
end

# PATCHes without the CSRF header — used by the CSRF rejection case.
private def patch_json_no_csrf(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  call_api_raw(HTTP::Request.new("PATCH", path, headers: headers, body: body))
end

describe "Assistant Conversation Routes" do
  describe "POST /Api/assistant/conversations" do
    it "creates a conversation and returns 201 with persisted fields" do
      response = post_json("/Api/assistant/conversations", conversation_body)

      assert_http_status(response, 201)
      data = JSON.parse(response.body)["data"].as_h
      id = data["id"].as_s
      id.should_not be_empty

      # session_id / cache_key are server-generated ULIDs; the response no
      # longer carries model/config — the connection resolves live per turn.
      data["session_id"].as_s.should_not be_empty
      data["cache_key"].as_s.should_not be_empty
      data.has_key?("model").should be_false
      data.has_key?("config").should be_false

      # The response can never carry a secret — with the snapshot gone there
      # is no surface for one; the api_key key must not exist at all.
      data["context"]["kind"].as_s.should eq("general-assistance")
      data["enabled_tools"].as_a.map(&.as_s).should eq(["search", "list_documents"])
    end

    it "ignores a request-side config field (the snapshot contract is gone)" do
      body = %({
        "config": {"api_key": "leaked", "model": "m"}
      })
      # The backend ignores any request-side `config` field entirely (it is
      # server-owned), so the request succeeds.
      response = post_json("/Api/assistant/conversations", body)

      assert_http_status(response, 201)
      data = JSON.parse(response.body)["data"].as_h
      data.has_key?("config").should be_false
    end

    it "bakes the language directive into the prompt when the body carries a language" do
      body = %({"language": "fr", "context": {"kind":"general-assistance"}, "enabled_tools": ["search"]})
      response = post_json("/Api/assistant/conversations", body)

      assert_http_status(response, 201)
      prompt = JSON.parse(response.body)["data"]["system_prompt"].as_s
      prompt.should contain("## Language")
      prompt.should contain("`fr`")
    end

    it "stores no language directive when the body omits language" do
      response = post_json("/Api/assistant/conversations", conversation_body)

      assert_http_status(response, 201)
      data = JSON.parse(response.body)["data"].as_h
      # The setting text may be unset here — the stored prompt is then nil.
      (data["system_prompt"].as_s? || "").should_not contain("## Language")
    end

    it "defaults context and enabled_tools when omitted" do
      body = %({})
      response = post_json("/Api/assistant/conversations", body)

      assert_http_status(response, 201)
      data = JSON.parse(response.body)["data"].as_h
      data["context"].as_h.should be_empty
      data["enabled_tools"].as_a.should be_empty
    end

    it "rejects context.kind='domain-builder' (must use the dedicated route)" do
      body = %({
        "context": {"kind":"domain-builder", "draft_domain":"hr"},
        "enabled_tools": ["create_doctype"]
      })
      response = post_json("/Api/assistant/conversations", body)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("domain-builder")
      JSON.parse(response.body)["error"].as_s.should contain("/Api/assistant/domain-builder/conversations")
    end

    it "rejects context.kind='workspace' (must use the dedicated route)" do
      body = %({
        "context": {"kind":"workspace", "created_by":"01FORGEDOWNER0"}
      })
      response = post_json("/Api/assistant/conversations", body)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("workspace")
      JSON.parse(response.body)["error"].as_s.should contain("/Api/assistant/workspace/conversations")
    end

    it "requires a non-empty body" do
      response = post_json("/Api/assistant/conversations", "")

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("body")
    end

    it "rejects malformed JSON body" do
      response = post_json("/Api/assistant/conversations", "not json")

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("Invalid JSON")
    end
  end

  describe "GET /Api/assistant/conversations" do
    it "lists conversations paginated, updated_at DESC by default" do
      # Seed 3 conversations.
      post_json("/Api/assistant/conversations", conversation_body)
      post_json("/Api/assistant/conversations", conversation_body)
      post_json("/Api/assistant/conversations", conversation_body)

      response = get_json("/Api/assistant/conversations?page=1&items=2")

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      data = json["data"].as_a
      data.size.should eq(2)
      # Default ordering is updated_at DESC (which equals created_at at rest).
      updated = data.map { |d| Time.parse_iso8601(d["updated_at"].as_s).to_utc }
      # Millisecond-precision timestamps mean rows created in the same ms tie,
      # so we only assert non-increasing order (DESC with ties allowed).
      updated[0].should be >= updated[1]
      meta = json["meta"].as_h
      # `count` is the real number from this page's offset; three rows fit
      # under the cap, so `more` stays false.
      meta["count"].as_i.should eq(3)
      meta["more"].as_bool.should be_false
    end

    it "surfaces the conversation whose updated_at was bumped by a turn first" do
      # Two conversations, A created before B. Backdate B with SQL so the
      # assertion does not depend on clock resolution between requests.
      # The turn bump on A must lift A above B by construction.
      a_resp = post_json("/Api/assistant/conversations", conversation_body)
      a_id = JSON.parse(a_resp.body)["data"]["id"].as_s
      b_resp = post_json("/Api/assistant/conversations", conversation_body)
      b_id = JSON.parse(b_resp.body)["data"]["id"].as_s

      with_db do |db|
        db.exec(
          "UPDATE agent_conversations SET updated_at = now() - interval '1 hour' WHERE id = $1",
          b_id,
        )
      end

      turn_body = %({
        "request_messages": [{"role": "user", "content": "hi"}],
        "response_messages": [{"role": "assistant", "content": "yo"}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        "finish_reason": "stop"
      })
      post_json("/Api/assistant/conversations/#{a_id}/turns", turn_body)

      response = get_json("/Api/assistant/conversations?page=1&items=10")
      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_a
      data.size.should eq(2)
      data.first["id"].as_s.should eq(a_id)
    end

    it "filters by context.kind__eq" do
      demo_body = %({"context": {"kind":"demo"}})
      general_body = %({"context": {"kind":"general-assistance"}})

      post_json("/Api/assistant/conversations", general_body)
      post_json("/Api/assistant/conversations", demo_body)
      post_json("/Api/assistant/conversations", general_body)

      response = get_json("/Api/assistant/conversations?filters[context.kind__eq]=demo")
      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_a
      data.size.should eq(1)
      data.first["context"]["kind"].as_s.should eq("demo")
    end

    it "filters by multiple context keys (AND)" do
      # `kind: "domain-builder"` is reserved (rejected by the generic
      # conversation-create route); use an arbitrary kind so this filter
      # test stays focused on the AND semantics.
      post_json("/Api/assistant/conversations", %({
        "context": {"kind":"demo", "draft_domain":"_logistics"}
      }))
      post_json("/Api/assistant/conversations", %({
        "context": {"kind":"demo", "draft_domain":"_hr"}
      }))
      post_json("/Api/assistant/conversations", %({
        "context": {"kind":"demo"}
      }))

      response = get_json(
        "/Api/assistant/conversations?filters[context.kind__eq]=demo&filters[context.draft_domain__eq]=_logistics"
      )
      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_a
      data.size.should eq(1)
      data.first["context"]["draft_domain"].as_s.should eq("_logistics")
    end

    it "honours an explicit sort=-created_at" do
      first = post_json("/Api/assistant/conversations", conversation_body)
      first_id = JSON.parse(first.body)["data"]["id"].as_s
      # Backdate the first row so it sorts last under -created_at by
      # construction, not by clock resolution between requests.
      with_db do |db|
        db.exec(
          "UPDATE agent_conversations SET created_at = now() - interval '1 hour' WHERE id = $1",
          first_id,
        )
      end
      post_json("/Api/assistant/conversations", conversation_body)

      response = get_json("/Api/assistant/conversations?sort=-created_at")
      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_a
      data.last["id"].as_s.should eq(first_id)
    end

    it "flags only the conversation with a running turn as active" do
      busy_resp = post_json("/Api/assistant/conversations", conversation_body)
      busy_id = JSON.parse(busy_resp.body)["data"]["id"].as_s
      idle_resp = post_json("/Api/assistant/conversations", conversation_body)
      idle_id = JSON.parse(idle_resp.body)["data"]["id"].as_s

      with_db do |db|
        Facet::Assistant::Turn.open(
          db, busy_id, %([{"role":"user","content":"hi"}]), "turn-token-1",
        ).as(Facet::Assistant::Turn::Result::Created)
      end

      response = get_json("/Api/assistant/conversations?items=100")
      assert_http_status(response, 200)
      rows = JSON.parse(response.body)["data"].as_a
      busy = rows.find! { |r| r["id"].as_s == busy_id }
      idle = rows.find! { |r| r["id"].as_s == idle_id }
      busy["active"].as_bool.should be_true
      idle["active"].as_bool.should be_false
    end
  end

  describe "GET /Api/assistant/conversations/:id" do
    it "returns a single conversation by id" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s

      response = get_json("/Api/assistant/conversations/#{id}")

      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_h
      data["id"].as_s.should eq(id)
    end

    it "reports active false on a fresh conversation" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s

      response = get_json("/Api/assistant/conversations/#{id}")

      assert_http_status(response, 200)
      JSON.parse(response.body)["data"]["active"].as_bool.should be_false
    end

    it "reports active true while a turn is running, false once it settles" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s

      with_db do |db|
        Facet::Assistant::Turn.open(
          db, id, %([{"role":"user","content":"hi"}]), "turn-token-1",
        ).as(Facet::Assistant::Turn::Result::Created)
      end

      running = get_json("/Api/assistant/conversations/#{id}")
      assert_http_status(running, 200)
      JSON.parse(running.body)["data"]["active"].as_bool.should be_true

      with_db do |db|
        row = Facet::Assistant::Turn.running_turn(db, id).not_nil!
        Facet::Assistant::Turn.complete(
          db, turn_id: row.id, response_messages_json: "[]",
          usage_json: %({"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}),
          status: "done", finish_reason: "stop",
        )
      end

      settled = get_json("/Api/assistant/conversations/#{id}")
      assert_http_status(settled, 200)
      JSON.parse(settled.body)["data"]["active"].as_bool.should be_false
    end

    it "returns 404 for unknown conversation id" do
      response = get_json("/Api/assistant/conversations/01NONEXISTENT0")

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should contain("not found")
    end
  end

  describe "PATCH /Api/assistant/conversations/:id" do
    it "archives a conversation, then unarchives it" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s

      archive = patch_json("/Api/assistant/conversations/#{id}", %({"archived": true}))
      assert_http_status(archive, 200)
      data = JSON.parse(archive.body)["data"].as_h
      data["id"].as_s.should eq(id)
      data["archived_at"].as_s.should_not be_empty

      # The archived row leaves the default list.
      listed = get_json("/Api/assistant/conversations")
      assert_http_status(listed, 200)
      JSON.parse(listed.body)["data"].as_a.map(&.as_h["id"].as_s).should_not contain(id)

      unarchive = patch_json("/Api/assistant/conversations/#{id}", %({"archived": false}))
      assert_http_status(unarchive, 200)
      JSON.parse(unarchive.body)["data"]["archived_at"].as_s?.should be_nil

      relisted = get_json("/Api/assistant/conversations")
      assert_http_status(relisted, 200)
      JSON.parse(relisted.body)["data"].as_a.map(&.as_h["id"].as_s).should contain(id)
    end

    it "serves the archived list under filters[archived__eq]=true" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s
      patch_json("/Api/assistant/conversations/#{id}", %({"archived": true}))

      response = get_json("/Api/assistant/conversations?filters[archived__eq]=true")
      assert_http_status(response, 200)
      data = JSON.parse(response.body)["data"].as_a
      data.size.should eq(1)
      data.first["id"].as_s.should eq(id)
      data.first["archived_at"].as_s.should_not be_empty
    end

    it "answers 422 when the body carries no boolean archived field" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      id = JSON.parse(create_response.body)["data"]["id"].as_s

      response = patch_json("/Api/assistant/conversations/#{id}", %({"archived": "yes"}))
      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("archived")
    end

    it "answers 404 for an unknown conversation id" do
      response = patch_json("/Api/assistant/conversations/01NONEXISTENT0", %({"archived": true}))

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should contain("not found")
    end
  end

  describe "Turn Routes" do
    it "POST records a turn and GET lists turns for a conversation" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      turn_body = %({
        "request_messages": [{"role": "user", "content": "hello"}],
        "response_messages": [{"role": "assistant", "content": "hi there"}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        "finish_reason": "stop"
      })

      turn_response = post_json("/Api/assistant/conversations/#{conversation_id}/turns", turn_body)
      assert_http_status(turn_response, 201)
      turn_data = JSON.parse(turn_response.body)["data"].as_h
      turn_data["idx"].as_i.should eq(1)
      turn_data["conversation_id"].as_s.should eq(conversation_id)
      turn_data["request_messages"].as_a.first["content"].as_s.should eq("hello")
      turn_data["response_messages"].as_a.first["content"].as_s.should eq("hi there")
      turn_data["usage"]["prompt_tokens"].as_i.should eq(10)
      turn_data["finish_reason"].as_s.should eq("stop")
      turn_data["error"]?.try(&.raw).should be_nil

      # Add a second turn, idx should increment.
      second_turn_body = %({
        "request_messages": [{"role": "user", "content": "again"}],
        "response_messages": [{"role": "assistant", "content": "ok"}],
        "usage": {"prompt_tokens": 20, "completion_tokens": 8, "total_tokens": 28},
        "finish_reason": "stop"
      })
      post_json("/Api/assistant/conversations/#{conversation_id}/turns", second_turn_body)

      list_response = get_json("/Api/assistant/conversations/#{conversation_id}/turns")
      assert_http_status(list_response, 200)
      list_data = JSON.parse(list_response.body)["data"].as_a
      list_data.size.should eq(2)
      list_data.map(&.["idx"].as_i).should eq([1, 2])
      list_data.last["response_messages"].as_a.first["content"].as_s.should eq("ok")
    end

    it "surfaces the turn token of a running turn on the turns list" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      with_db do |db|
        Facet::Assistant::Turn.open(
          db, conversation_id, %([{"role":"user","content":"hi"}]), "turn-token-42",
        ).as(Facet::Assistant::Turn::Result::Created)
      end

      list_response = get_json("/Api/assistant/conversations/#{conversation_id}/turns")
      assert_http_status(list_response, 200)
      row = JSON.parse(list_response.body)["data"].as_a.first
      row["status"].as_s.should eq("running")
      row["turn_token"].as_s.should eq("turn-token-42")
    end

    it "surfaces the turn token on the latest-turn summary" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      with_db do |db|
        Facet::Assistant::Turn.open(
          db, conversation_id, %([{"role":"user","content":"hi"}]), "turn-token-7",
        ).as(Facet::Assistant::Turn::Result::Created)
      end

      response = get_json("/Api/assistant/conversations/#{conversation_id}/turns/latest")
      assert_http_status(response, 200)
      summary = JSON.parse(response.body)["data"].as_h
      summary["status"].as_s.should eq("running")
      summary["turn_token"].as_s.should eq("turn-token-7")
    end

    it "persists an error turn" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      turn_body = %({
        "request_messages": [{"role": "user", "content": "boom"}],
        "response_messages": [{"role": "assistant", "content": "Agent error: boom"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "error": "boom"
      })

      turn_response = post_json("/Api/assistant/conversations/#{conversation_id}/turns", turn_body)
      assert_http_status(turn_response, 201)
      turn_data = JSON.parse(turn_response.body)["data"].as_h
      turn_data["error"].as_s.should eq("boom")
      turn_data["finish_reason"]?.try(&.raw).should be_nil
    end

    it "requires request_messages in turn body" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      body = %({"response_messages": [], "usage": {}})
      turn_response = post_json("/Api/assistant/conversations/#{conversation_id}/turns", body)

      assert_http_status(turn_response, 422)
      JSON.parse(turn_response.body)["error"].as_s.should contain("request_messages")
    end

    it "POST turns returns 404 for unknown conversation" do
      turn_body = %({
        "request_messages": [{"role": "user", "content": "hi"}],
        "response_messages": [],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
      })
      response = post_json("/Api/assistant/conversations/01NONEXISTENT0/turns", turn_body)

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should contain("not found")
    end

    it "GET turns returns 404 for unknown conversation" do
      response = get_json("/Api/assistant/conversations/01NONEXISTENT0/turns")

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should contain("not found")
    end
  end

  describe "Stream Routes" do
    it "POST /stream returns 404 for unknown conversation" do
      body = JSON.build { |j| j.object { j.field "content", "hello" } }
      response = post_json("/Api/assistant/conversations/01NONEXISTENT0/stream", body)

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should contain("not found")
    end

    it "POST /stream validates required content field" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      body = JSON.build { |j| j.object { j.field "wrong_field", "oops" } }
      response = post_json("/Api/assistant/conversations/#{conversation_id}/stream", body)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("content")
    end

    it "POST /stream requires a body" do
      create_response = post_json("/Api/assistant/conversations", conversation_body)
      conversation_id = JSON.parse(create_response.body)["data"]["id"].as_s

      response = post_json("/Api/assistant/conversations/#{conversation_id}/stream", "")

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].as_s.should contain("body")
    end
  end

  describe "CSRF protection" do
    # The csrf_check runs before any state change, so unknown ids never
    # reach the handlers — every rejection below needs no seed data.
    it "rejects POST /conversations without X-Requested-With" do
      response = post_json_no_csrf("/Api/assistant/conversations", conversation_body)

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects POST /conversations/:id/turns without X-Requested-With" do
      response = post_json_no_csrf("/Api/assistant/conversations/01ANY/turns", "{}")

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects POST /conversations/:id/stream without X-Requested-With" do
      response = post_json_no_csrf(
        "/Api/assistant/conversations/01ANY/stream",
        JSON.build { |j| j.object { j.field "content", "hello" } },
      )

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects POST /cancel/:turn_token without X-Requested-With" do
      response = post_json_no_csrf("/Api/assistant/cancel/01ANYTOK", "{}")

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects PATCH /conversations/:id without X-Requested-With" do
      response = patch_json_no_csrf("/Api/assistant/conversations/01ANYID", %({"archived": true}))

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "keeps write routes open with the header" do
      response = post_json("/Api/assistant/conversations", conversation_body)
      assert_http_status(response, 201)
    end
  end

  describe "Cancel Route" do
    it "POST /cancel/:turn_token returns 200 with cancelled: true" do
      response = post_json("/Api/assistant/cancel/01ANYTOK", "{}")

      assert_http_status(response, 200)
      JSON.parse(response.body)["cancelled"].as_bool.should be_true
    end

    it "POST /cancel/:turn_token returns 200 even with empty body" do
      headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
      response = call_api(HTTP::Request.new("POST", "/Api/assistant/cancel/01ANYTOK", headers: headers, body: ""))

      assert_http_status(response, 200)
      JSON.parse(response.body)["cancelled"].as_bool.should be_true
    end
  end
end

# Inserts a conversation row directly. The generic create route rejects
# reserved kinds, so domain-builder fixtures are written by hand.
# Returns the conversation id.
private def insert_conversation(db, context_json : String) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO agent_conversations (id, session_id, cache_key, context) VALUES ($1, $1, $1, $2)",
    id, context_json,
  )
  id
end

# A real (non-system) principal carrying no permissions — the ownership
# gate consults only the account id, never the active role.
private def auth_as(account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "iam.Roles.test",
    visible_tags: Set{"default"},
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "Assistant Conversation Ownership" do
  # The ownership tests pin a non-system principal on the fiber. Clean up
  # so later examples start from the test-mode system default again.
  after_each { Fiber.current.auth_context = nil }

  it "allows the owner to get their domain-builder conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"),
      auth_as(owner),
    )

    assert_http_status(response, 200)
    JSON.parse(response.body)["data"]["id"].as_s.should eq(conv_id)
  end

  it "rejects another caller's get of a domain-builder conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"),
      auth_as(other),
    )

    assert_http_status(response, 403)
    JSON.parse(response.body)["error"].as_s.should contain("access")
  end

  it "rejects another caller's stream of a domain-builder conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
    end

    body = JSON.build { |j| j.object { j.field "content", "hello" } }
    headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
    response = call_api_as(
      HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
      auth_as(other),
    )

    # The denial must be JSON — not an SSE stream — because it fires
    # before the SSE headers are written.
    assert_http_status(response, 403)
    response.headers["Content-Type"]?.to_s.should contain("json")
    JSON.parse(response.body)["error"].as_s.should contain("access")
  end

  it "fails closed when the stored context carries no created_by" do
    caller = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own"}))
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"),
      auth_as(caller),
    )

    assert_http_status(response, 403)
  end

  it "rejects another caller's archive write into a workspace conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
    end

    headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
    response = call_api_as(
      HTTP::Request.new("PATCH", "/Api/assistant/conversations/#{conv_id}",
        headers: headers, body: %({"archived": true})),
      auth_as(other),
    )

    assert_http_status(response, 403)
    JSON.parse(response.body)["error"].as_s.should contain("access")

    # The denied write must not have landed.
    with_db do |db|
      archived_at = db.query_one?("SELECT archived_at FROM agent_conversations WHERE id = $1", conv_id, as: Time?)
      archived_at.should be_nil
    end
  end

  it "scopes a reserved-kind list to the caller's own conversations" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
      # A second conversation owned by the other account.
      insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_other","created_by":"#{other}"}))
      # A non-reserved conversation — not subject to the scope.
      insert_conversation(db, %({"kind":"general-assistance"}))
    end

    path = "/Api/assistant/conversations?filters[context.kind__eq]=domain-builder"

    as_owner = call_api_as(HTTP::Request.new("GET", path), auth_as(owner))
    assert_http_status(as_owner, 200)
    owned_rows = JSON.parse(as_owner.body)["data"].as_a
    owned_rows.size.should eq(1)
    owned_rows.first["context"]["created_by"].as_s.should eq(owner)

    as_other = call_api_as(HTTP::Request.new("GET", path), auth_as(other))
    assert_http_status(as_other, 200)
    other_rows = JSON.parse(as_other.body)["data"].as_a
    other_rows.size.should eq(1)
    other_rows.first["context"]["created_by"].as_s.should eq(other)
  end

  it "ignores a forged created_by filter on a reserved-kind list" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
    end

    # The caller forges `created_by` = their own id while asking for the
    # owner's kind — the forced scope must still apply (here it narrows to
    # the caller, and the owner's row does not surface).
    path = "/Api/assistant/conversations?filters[context.kind__eq]=domain-builder&filters[context.created_by__eq]=#{owner}"
    response = call_api_as(HTTP::Request.new("GET", path), auth_as(other))
    assert_http_status(response, 200)
    JSON.parse(response.body)["data"].as_a.size.should eq(0)
  end

  it "scopes a workspace-kind list to the caller's own conversations" do
    # Second reserved kind; same forced-scope contract, exercised on the
    # workspace kind's own fixtures.
    owner = Facet::Util::ScriptHelpers.ulid
    intruder = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
      insert_conversation(db, %({"kind":"workspace","created_by":"#{intruder}"}))
    end

    path = "/Api/assistant/conversations?filters[context.kind__eq]=workspace"
    as_owner = call_api_as(HTTP::Request.new("GET", path), auth_as(owner))
    assert_http_status(as_owner, 200)
    owned_rows = JSON.parse(as_owner.body)["data"].as_a
    owned_rows.size.should eq(1)
    owned_rows.first["context"]["created_by"].as_s.should eq(owner)
  end

  it "leaves non-reserved kinds unscoped on the list" do
    caller = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"general-assistance"}))
    end

    path = "/Api/assistant/conversations?filters[context.kind__eq]=general-assistance"
    response = call_api_as(HTTP::Request.new("GET", path), auth_as(caller))
    assert_http_status(response, 200)
    JSON.parse(response.body)["data"].as_a.size.should eq(1)
  end

  it "scopes an unfiltered list to the caller's own conversations" do
    # A list that names no kind must not expose other accounts' rows:
    # the caller's account id is forced onto `context.created_by__eq`,
    # so only conversations carrying the caller as owner surface (reserved
    # kinds always carry it; generic rows do not and stay hidden).
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
      insert_conversation(db, %({"kind":"workspace","created_by":"#{other}"}))
      insert_conversation(db, %({"kind":"general-assistance"}))
    end

    as_owner = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations"), auth_as(owner))
    assert_http_status(as_owner, 200)
    rows = JSON.parse(as_owner.body)["data"].as_a
    rows.size.should eq(1)
    rows.first["context"]["created_by"].as_s.should eq(owner)

    as_other = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations"), auth_as(other))
    assert_http_status(as_other, 200)
    other_rows = JSON.parse(as_other.body)["data"].as_a
    other_rows.size.should eq(1)
    other_rows.first["context"]["created_by"].as_s.should eq(other)
  end

  it "applies the owner scope to a list that filters other context keys without a kind" do
    # A `context.*` filter that is not the kind (e.g. draft_domain) does
    # not exempt the list from the owner scope.
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{owner}"}))
      insert_conversation(db, %({"kind":"domain-builder","draft_domain":"_own","created_by":"#{other}"}))
    end

    path = "/Api/assistant/conversations?filters[context.draft_domain__eq]=_own"
    as_owner = call_api_as(HTTP::Request.new("GET", path), auth_as(owner))
    assert_http_status(as_owner, 200)
    rows = JSON.parse(as_owner.body)["data"].as_a
    rows.size.should eq(1)
    rows.first["context"]["created_by"].as_s.should eq(owner)
  end

  it "rejects another caller's turns list of a workspace conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}/turns"),
      auth_as(other),
    )

    assert_http_status(response, 403)
    JSON.parse(response.body)["error"].as_s.should contain("access")
  end

  it "allows the owner to list turns of their workspace conversation" do
    owner = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
      db.exec(
        "INSERT INTO agent_turns (id, conversation_id, idx, request_messages, response_messages, usage) " \
        "VALUES ($1, $2, 1, '[{\"role\":\"user\",\"content\":\"hi\"}]'::jsonb, '[]'::jsonb, '{}')",
        Facet::Util::ScriptHelpers.ulid, conv_id,
      )
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}/turns"),
      auth_as(owner),
    )

    assert_http_status(response, 200)
    rows = JSON.parse(response.body)["data"].as_a
    rows.size.should eq(1)
    rows.first["idx"].as_i.should eq(1)
  end

  it "rejects a turn write into another account's workspace conversation" do
    # Without the gate a caller could inject turns into another account's
    # replay context — the next stream resumes from the stored messages.
    owner = Facet::Util::ScriptHelpers.ulid
    other = Facet::Util::ScriptHelpers.ulid
    conv_id = nil
    with_db do |db|
      conv_id = insert_conversation(db, %({"kind":"workspace","created_by":"#{owner}"}))
    end

    body = %({
      "request_messages": [{"role": "user", "content": "injected"}],
      "response_messages": [{"role": "assistant", "content": "forged"}],
      "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    })
    headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
    response = call_api_as(
      HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/turns", headers: headers, body: body),
      auth_as(other),
    )

    assert_http_status(response, 403)
    JSON.parse(response.body)["error"].as_s.should contain("access")

    # Nothing was written.
    count = nil
    with_db do |db|
      count = db.query_one("SELECT COUNT(*) FROM agent_turns WHERE conversation_id = $1", conv_id, as: Int64)
    end
    count.should eq(0)
  end

  it "returns 404 for turns of an unknown conversation (owner-gate order)" do
    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/conversations/01NONEXISTENT0/turns"),
      auth_as(Facet::Util::ScriptHelpers.ulid),
    )

    assert_http_status(response, 404)
  end
end

# ── Usage-limit gate + meter endpoint ──────────────────────────────────

# Inserts an `iam.Roles` projection enabling the assistant with a budget.
private def create_budget_role(db, id : String, budget : Int64) : Nil
  content : Hash(String, JSON::Any) = {
    "name"        => JSON::Any.new(id),
    "description" => JSON::Any.new("Test role #{id}"),
    "permissions" => JSON::Any.new([
      JSON::Any.new({"action" => JSON::Any.new("read"), "on" => JSON::Any.new("*.*")}),
    ]),
    "connectivity"           => JSON.parse(%(["assistant"])),
    "assistant_token_budget" => JSON::Any.new(budget),
  }
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.#{id}",
    content: content.to_json,
    actioner_id: "system",
  )
end

# Creates a bare `iam.Account` projection holding the given role ids.
private def create_budget_account(db, role_ids : Array(String)) : String
  content : Hash(String, JSON::Any) = {
    "roles" => JSON::Any.new(role_ids.map { |r| JSON::Any.new(r) }),
  }
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: doc_id,
    content: content.to_json,
    actioner_id: "system",
  )
  doc_id
end

# `auth_as` with an explicit role name — `ActiveRole.role_id` carries the
# bare name (the production `from_projection_content` shape); the access
# gate qualifies it to the `iam.Roles.<name>` projection id.
private def auth_as_role(account_id : String, role_name : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: role_name,
    visible_tags: Set{"default"},
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "Assistant usage limit gate" do
  after_each { Fiber.current.auth_context = nil }

  it "denies the stream with a JSON 429 when the budget is spent" do
    account = nil
    conv_id = nil
    with_db do |db|
      create_budget_role(db, "spent", 100_i64)
      account = create_budget_account(db, ["iam.Roles.spent"])
      # 150 total tokens inside the rolling window — past the budget.
      Facet::Assistant::Usage.insert(
        db, account.not_nil!, "conv_#{account}", "turn_#{Facet::Util::ScriptHelpers.ulid}",
        "test-model", 100_i64, 50_i64,
      )
      conv_id = insert_conversation(db, %({"kind":"workspace","created_by":"#{account}"}))
    end

    body = JSON.build { |j| j.object { j.field "content", "hello" } }
    headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
    response = call_api_as(
      HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
      auth_as_role(account.not_nil!, "spent"),
    )

    # The denial must be JSON — not an SSE stream — because it fires
    # before the SSE headers are written.
    assert_http_status(response, 429)
    response.headers["Content-Type"]?.to_s.should contain("json")
    JSON.parse(response.body)["error"].as_s.should_not be_empty
  end
end

describe "GET /Api/assistant/usage" do
  after_each { Fiber.current.auth_context = nil }

  it "returns the rolling-window total and the effective budget" do
    account = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      Facet::Assistant::Usage.insert(
        db, account, "conv_1", "turn_1", "test-model", 100_i64, 20_i64
      )
      Facet::Assistant::Usage.insert(
        db, account, "conv_1", "turn_2", "test-model", 7_i64, 3_i64
      )
      # Another account's row never leaks into the caller's total.
      Facet::Assistant::Usage.insert(
        db, "acct_other", "conv_2", "turn_3", "test-model", 500_i64, 500_i64
      )
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/usage"),
      auth_as(account),
    )

    assert_http_status(response, 200)
    body = JSON.parse(response.body)
    body["total"].as_i64.should eq(130)
    # Both rows are reported turns — nothing estimated.
    body["estimated_total"].as_i64.should eq(0)
    # The account holds no role projections — unlimited.
    body["budget"].raw.should be_nil
    body["window_days"].as_i.should eq(30)
    window_start = Time.parse_rfc3339(body["window_start"].as_s)
    (Time.utc - window_start - 30.days).abs.should be < 1.minute
  end

  it "splits the estimated part out of the total (F08-01)" do
    account = Facet::Util::ScriptHelpers.ulid
    with_db do |db|
      Facet::Assistant::Usage.insert(
        db, account, "conv_1", "turn_1", "test-model", 100_i64, 20_i64
      )
      Facet::Assistant::Usage.insert(
        db, account, "conv_1", "turn_2", "test-model", 30_i64, 8_i64, estimated: true
      )
    end

    response = call_api_as(
      HTTP::Request.new("GET", "/Api/assistant/usage"),
      auth_as(account),
    )

    assert_http_status(response, 200)
    body = JSON.parse(response.body)
    body["total"].as_i64.should eq(158)
    body["estimated_total"].as_i64.should eq(38)
  end

  it "answers 401 for a caller with no billable account" do
    # Test mode runs the request as the system bypass — no JWT, no
    # billable account, and the meter is an authenticated-only surface.
    response = call_api(HTTP::Request.new("GET", "/Api/assistant/usage"))

    assert_http_status(response, 401)
  end
end
