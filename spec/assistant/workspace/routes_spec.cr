# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../support/workspace_test_helpers"
require "../../../src/http/server"
require "../../../src/assistant"
require "../../../src/iam"
require "../../../src/document"
require "../../../src/system_settings"
require "../../../src/doctype/seed"
require "../../support/http_helper"
require "../../support/iam_helper"
require "../../support/doctype_helper"
require "json"

HTTPTest.init

# ── Fixtures ────────────────────────────────────────────────────────────────

# Creates an `iam.Roles` projection with a connectivity list and the given
# budget, then an `iam.Account` holding it. Returns the account id.
def create_ws_role_and_account(
  db,
  role_id : String,
  assistant_access : Bool,
  assistant_token_budget : Int64? = nil,
) : String
  channels = assistant_access ? %w[mcp assistant] : [] of String
  content : Hash(String, JSON::Any) = {
    "name"         => JSON::Any.new(role_id),
    "description"  => JSON::Any.new("Workspace test role"),
    "visible_tags" => JSON.parse(%(["default"])),
    "permissions"  => JSON.parse(%([{ "action": "read", "on": "*.*" }])),
    "connectivity" => JSON::Any.new(channels.map { |c| JSON::Any.new(c) }),
  }
  content["assistant_token_budget"] = JSON::Any.new(assistant_token_budget) if assistant_token_budget

  existing = db.query_one?("SELECT 1 FROM projections WHERE id = $1 AND deleted_at IS NULL", "iam.Roles.#{role_id}", as: Int32)
  unless existing
    Facet::Mutation::Client.create(
      db, "iam", "Roles",
      doc_id: "iam.Roles.#{role_id}",
      content: content.to_json,
      actioner_id: "system",
    )
  end

  account_id = Facet::Util::ScriptHelpers.ulid
  account_content = {
    "email" => JSON::Any.new("#{role_id}@facet.test"),
    "name"  => JSON::Any.new("Workspace tester"),
    "roles" => JSON.parse(%(["iam.Roles.#{role_id}"])),
  }
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: account_id,
    content: account_content.to_json,
    actioner_id: "system",
  )
  account_id
end

# Rebuilds an `AuthContext` for the account from its current role content,
# exactly as the production auth layer does.
def ws_auth_context(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.#{role_id}").not_nil!
  Facet::RBAC::AuthContext.authenticated(
    account_id,
    Facet::RBAC::ActiveRole.from_projection_content(role_content),
  )
end

# Inserts a workspace conversation row directly. The connection resolves
# from the effective settings at turn start, so the spec pins the endpoint
# (and the model the assertions expect) on the settings singleton. Returns
# the conversation id.
def insert_ws_conversation(db, api_endpoint : String, created_by : String) : String
  id = Facet::Util::ScriptHelpers.ulid
  pin_assistant_connection(db, api_endpoint)
  db.exec(
    "INSERT INTO agent_conversations (id, session_id, cache_key, system_prompt, context, enabled_tools) " \
    "VALUES ($1, $1, $1, 'test prompt', $2, '[]')",
    id, %({"kind":"workspace","created_by":"#{created_by}"}),
  )
  id
end

# Pins the assistant endpoint and model on the settings singleton — the
# hot-change path the turn start resolves. Idempotent per example.
def pin_assistant_connection(db, api_endpoint : String) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    %({"assistant": {"api_endpoint": "#{api_endpoint}/v1", "model": "gpt-4o"}}),
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

# Inserts a domain-builder conversation row whose draft_domain is a real
# draft owned by `created_by`. Returns the conversation id.
def insert_builder_conversation(db, api_endpoint : String, created_by : String) : String
  draft = Facet::Domain::Draft.create(db, "{}", created_by)
  draft.should be_a(Facet::Domain::Draft::Result)
  draft_name = draft.as(Facet::Domain::Draft::Result).projection.id

  id = Facet::Util::ScriptHelpers.ulid
  pin_assistant_connection(db, api_endpoint)
  db.exec(
    "INSERT INTO agent_conversations (id, session_id, cache_key, system_prompt, context, enabled_tools) " \
    "VALUES ($1, $1, $1, 'test prompt', $2, '[]')",
    id, %({"kind":"domain-builder","draft_domain":"#{draft_name}","created_by":"#{created_by}"}),
  )
  id
end

private def ws_post(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  call_api(HTTP::Request.new("POST", path, headers: headers, body: body))
end

private def ws_post_no_csrf(path, body) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  call_api_raw(HTTP::Request.new("POST", path, headers: headers, body: body))
end

private def ws_get(path) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", path))
end

# ── Mock LLM server ─────────────────────────────────────────────────────────
#
# Answers the first request with one assistant message carrying the scripted
# tool calls, and every later request with plain text (so the tool loop
# finishes). Modeling after lib/agent-cr/spec/agent_spec.cr.
#
# Unique name: every spec file in the suite compiles into one binary.
class WorkspaceStreamMock
  record Call, name : String, args : String

  @calls : Array(Call)
  @server : HTTP::Server
  getter port : Int32

  def initialize(@calls : Array(Call))
    @server = HTTP::Server.new { |ctx| handle(ctx) }
    address = @server.bind_tcp(0)
    @port = address.port
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    ctx.request.body.try(&.gets_to_end)
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    if @calls.empty?
      text_final(ctx, "done")
    else
      tool_calls_final(ctx)
    end
    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end

  # Emits the scripted tool calls (up to two per message) plus the final
  # usage block. Agent-cr then executes the tools and asks again — the next
  # request plain-texts and the loop ends.
  private def tool_calls_final(ctx) : Nil
    ctx.response.puts "data: #{tool_call_delta.to_json}"
    ctx.response.flush

    final = {
      choices: [{
        delta:         {} of String => JSON::Any,
        index:         0,
        finish_reason: "tool_calls",
      }],
      usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
    }
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.flush
    @calls.clear
  end

  private def tool_call_delta
    tools = @calls.map_with_index do |call, idx|
      {
        "index"    => idx.to_i64,
        "id"       => "call_#{idx}",
        "type"     => "function",
        "function" => {"name" => call.name, "arguments" => call.args},
      }
    end
    {"choices" => [{"delta" => {"tool_calls" => tools}, "index" => 0}]}
  end

  private def text_final(ctx, text : String) : Nil
    data = {"choices" => [{"delta" => {"content" => text}, "index" => 0}]}.to_json
    ctx.response.puts "data: #{data}"
    ctx.response.flush

    final = {
      choices: [{
        delta:         {} of String => JSON::Any,
        index:         0,
        finish_reason: "stop",
      }],
      usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
    }
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.flush
  end
end

def ws_tool_call(name : String, args_json : String) : WorkspaceStreamMock::Call
  WorkspaceStreamMock::Call.new(name, args_json)
end

# Collects the SSE `chunk` events of a raw SSE body.
def ws_sse_chunks(body : String) : Array(JSON::Any)
  body.scan(/event: chunk\ndata: (.+)/).map do |match|
    JSON.parse(match[1])
  end
end

# ── Specs ───────────────────────────────────────────────────────────────────

describe "Workspace Assistant Routes" do
  before_each do
    with_db { |db| seed_iam_doctypes(db) }
  end

  describe "POST /Api/assistant/workspace/conversations" do
    it "creates a workspace conversation for an enabled account" do
      with_db do |db|
        role_id = "ws_on_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 201)
        data = JSON.parse(response.body)["data"].as_h
        conv_id = data["id"].as_s

        # Stored context names the kind and the caller — the owner never
        # comes from the request.
        data["context"]["kind"].as_s.should eq("workspace")
        data["context"]["created_by"].as_s.should eq(account_id)

        # System prompt: static body plus the Session context suffix.
        data["system_prompt"].as_s.should contain("workspace assistant")
        data["system_prompt"].as_s.should contain("## Session context")

        # enabled_tools: every registry entry minus ping, plus the UI tools.
        tools = data["enabled_tools"].as_a.map(&.as_s)
        tools.should_not contain("ping")
        tools.should contain("list_documents")
        tools.should contain("navigate")
        tools.should contain("show_documents")
        tools.should eq(Facet::Assistant::Workspace::Registrar.tool_names)

        # The connection is server-owned and resolves live per turn — the
        # response carries no model or config, so no secret can ride it.
        data.has_key?("model").should be_false
        data.has_key?("config").should be_false

        conv_id.should_not be_empty
      end
    end

    it "bakes the custom-instructions block into the stored prompt when the setting is pinned" do
      with_db do |db|
        role_id = "ws_cp_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)

        Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
        pin = Facet::Document::Update.call(
          db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
          %({"assistant": {"system_prompt": "Always answer in French."}}),
          Facet::RBAC::AuthContext.system,
        )
        pin.should be_a(Facet::Document::Update::Result)
        # No Redis fanout runs in the unit suite — invalidate like the subscriber.
        Facet::SystemSettings.mark_stale

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 201)
        prompt = JSON.parse(response.body)["data"]["system_prompt"].as_s
        prompt.should contain("## Custom instructions")
        prompt.should contain("Always answer in French.")

        session_idx = prompt.index("## Session context")
        custom_idx = prompt.index("## Custom instructions")
        session_idx.should be_a(Int32)
        custom_idx.should be_a(Int32)
        custom_idx.not_nil!.should be > session_idx.not_nil!
      ensure
        Facet::SystemSettings.reset_cache!
      end
    end

    it "bakes the language directive into the stored prompt when the body carries a language" do
      with_db do |db|
        role_id = "ws_lang_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"language": "fr"})),
          ctx,
        )

        assert_http_status(response, 201)
        prompt = JSON.parse(response.body)["data"]["system_prompt"].as_s
        prompt.should contain("## Language")
        prompt.should contain("`fr`")

        session_idx = prompt.index("## Session context")
        language_idx = prompt.index("## Language")
        session_idx.should be_a(Int32)
        language_idx.should be_a(Int32)
        language_idx.not_nil!.should be > session_idx.not_nil!
      end
    end

    it "stores no language directive when the body omits language" do
      with_db do |db|
        role_id = "ws_nolang_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 201)
        JSON.parse(response.body)["data"]["system_prompt"].as_s
          .should_not contain("## Language")
      end
    end

    it "rejects a non-holder with 403 and writes no row" do
      with_db do |db|
        role_id = "ws_off_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, false)
        ctx = ws_auth_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].as_s.should contain("workspace assistant")

        rows = db.query_one("SELECT COUNT(*) FROM agent_conversations", as: Int64)
        rows.should eq(0)
      end
    end

    it "rejects the unauthenticated (denied) principal with 401" do
      response = call_api_as(
        HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
          headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
          body: "{}"),
        Facet::RBAC::AuthContext.denied,
      )

      assert_http_status(response, 401)
      JSON.parse(response.body)["error"].as_s.should contain("Authentication")
    end

    it "rejects write without the CSRF header" do
      response = ws_post_no_csrf("/Api/assistant/workspace/conversations", "{}")

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects a malformed JSON body" do
      with_db do |db|
        role_id = "ws_bad_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/workspace/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "not json"),
          ctx,
        )

        assert_http_status(response, 422)
        JSON.parse(response.body)["error"].as_s.should contain("Invalid JSON")
      end
    end
  end

  describe "GET /Api/assistant/workspace/conversations/:id" do
    it "answers the opaque 404 instead of the doctype-resolution error" do
      response = ws_get("/Api/assistant/workspace/conversations/01JGHABCDEFJKLMNPQRSTVWXYZ")

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].as_s.should eq("Not found")
      response.body.should_not contain("Unknown doctype")
      response.headers["Content-Type"]?.to_s.should contain("json")
    end
  end

  describe "workspace conversation read surfaces" do
    it "lets the owner get, list, and stream-free-gate their conversation" do
      with_db do |db|
        role_id = "ws_own_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)
        conv_id = insert_ws_conversation(db, "http://localhost:59999", account_id)

        get_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"), ctx)
        assert_http_status(get_response, 200)
        JSON.parse(get_response.body)["data"]["context"]["created_by"].as_s.should eq(account_id)

        list_path = "/Api/assistant/conversations?filters[context.kind__eq]=workspace"
        list_response = call_api_as(HTTP::Request.new("GET", list_path), ctx)
        assert_http_status(list_response, 200)
        rows = JSON.parse(list_response.body)["data"].as_a
        rows.size.should eq(1)
        rows.first["context"]["created_by"].as_s.should eq(account_id)
      end
    end

    it "denies another caller's get, stream, and list of a workspace conversation" do
      with_db do |db|
        owner_role = "ws_ghost_#{unique_suffix}"
        other_role = "ws_intr_#{unique_suffix}"
        owner_id = create_ws_role_and_account(db, owner_role, true)
        other_id = create_ws_role_and_account(db, other_role, true)
        other_ctx = ws_auth_context(db, other_id, other_role)

        conv_id = insert_ws_conversation(db, "http://localhost:59999", owner_id)

        get_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"), other_ctx)
        assert_http_status(get_response, 403)
        JSON.parse(get_response.body)["error"].as_s.should contain("access")

        stream_body = JSON.build { |j| j.object { j.field "content", "hello" } }
        stream_response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: stream_body),
          other_ctx,
        )
        assert_http_status(stream_response, 403)
        stream_response.headers["Content-Type"]?.to_s.should contain("json")
        JSON.parse(stream_response.body)["error"].as_s.should contain("access")

        list_path = "/Api/assistant/conversations?filters[context.kind__eq]=workspace"
        list_response = call_api_as(HTTP::Request.new("GET", list_path), other_ctx)
        assert_http_status(list_response, 200)
        JSON.parse(list_response.body)["data"].as_a.size.should eq(0)
      end
    end
  end

  describe "workspace stream gate" do
    it "denies a non-holder owner with 403 before SSE headers, and a role flip applies on the next stream" do
      with_db do |db|
        role_id = "ws_flip_#{unique_suffix}"
        account_id = create_ws_role_and_account(db, role_id, true)
        ctx = ws_auth_context(db, account_id, role_id)
        conv_id = insert_ws_conversation(db, "http://localhost:59999", account_id)

        # Enabled: the gates pass (the fake LLM port never answers — this
        # stream errors on connect inside the SSE, but the gates ran).
        body = JSON.build { |j| j.object { j.field "content", "hello" } }
        headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
          ctx,
        )
        response.status_code.should eq(200)
        response.headers["Content-Type"]?.to_s.should contain("event-stream")

        # Flip the role off.
        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]') " \
          "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = $1 AND deleted_at IS NULL",
          "iam.Roles.#{role_id}",
        )

        denied = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
          ctx,
        )
        assert_http_status(denied, 403)
        denied.headers["Content-Type"]?.to_s.should contain("json")
        JSON.parse(denied.body)["error"].as_s.should contain("workspace assistant")
      end
    end
  end

  describe "scripted workspace stream" do
    it "runs list_documents through the workspace registrar and forwards navigate arguments" do
      server = nil
      begin
        with_db do |db|
          domain, doctype = build_agg_doctype(db, "wsstream", %({"name": {"type": "string", "required": true}}))
          create_ws_doc(db, domain, doctype, "Streamable", nil)
          create_ws_doc(db, domain, doctype, "Unwanted", nil)

          role_id = "ws_stream_#{unique_suffix}"
          account_id = create_ws_role_and_account(db, role_id, true)
          ctx = ws_auth_context(db, account_id, role_id)

          server = WorkspaceStreamMock.new([
            ws_tool_call("navigate", %({"target":"domain","domain":"#{domain}"})),
            ws_tool_call("list_documents", %({"domain":"#{domain}","doctype":"#{doctype}"})),
          ])
          conv_id = insert_ws_conversation(db, "http://localhost:#{server.not_nil!.port}", account_id)

          body = JSON.build { |j| j.object { j.field "content", "show me the documents" } }
          headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
          response = call_api_as(
            HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
            ctx,
          )

          response.status_code.should eq(200)
          response.headers["Content-Type"]?.to_s.should contain("event-stream")

          chunks = ws_sse_chunks(response.body)
          tool_calls = chunks.select { |c| c["kind"].as_s == "tool_call" }

          # The document tool ran through the registry: ok, with the
          # caller-scoped rows in the result payload.
          list_chunk = tool_calls.find { |c| c["name"].as_s == "list_documents" && c["status"].as_s == "ok" }
          list_chunk.should_not be_nil
          result = JSON.parse(list_chunk.not_nil!["result"].as_s)
          result["ok"].as_bool.should be_true
          names = result["data"]["data"].as_a.map(&.as_h.["data"].as_h.["name"].as_s)
          names.sort.should eq(["Streamable", "Unwanted"])

          # A document tool carries no forwarded arguments.
          list_chunk.not_nil!.as_h.has_key?("arguments").should be_false

          # The UI tool acked and its raw arguments are forwarded.
          nav_chunk = tool_calls.find { |c| c["name"].as_s == "navigate" && c["status"].as_s == "ok" }
          nav_chunk.should_not be_nil
          JSON.parse(nav_chunk.not_nil!["result"].as_s)["ok"].as_bool.should be_true
          forwarded = JSON.parse(nav_chunk.not_nil!["arguments"].as_s)
          forwarded["target"].as_s.should eq("domain")
          forwarded["domain"].as_s.should eq(domain)

          # The turn finished normally.
          response.body.should contain("event: done")
        end
      ensure
        server.try(&.close)
      end
    end

    it "keeps the builder argument_tools wiring: preview_view arguments stay forwarded" do
      server = WorkspaceStreamMock.new([
        ws_tool_call("preview_view", %({"kind":"document","template":{"type":"text","value":"hi"}})),
      ])
      begin
        with_db do |db|
          restore_seeded_baseline(db)

          role_id = "ws_builder_#{unique_suffix}"
          account_id = create_ws_role_and_account(db, role_id, true)
          ctx = ws_auth_context(db, account_id, role_id)

          conv_id = insert_builder_conversation(db, "http://localhost:#{server.port}", account_id)

          body = JSON.build { |j| j.object { j.field "content", "preview something" } }
          headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
          response = call_api_as(
            HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
            ctx,
          )

          response.status_code.should eq(200)
          chunks = ws_sse_chunks(response.body)
          tool_calls = chunks.select { |c| c["kind"].as_s == "tool_call" }

          preview_chunk = tool_calls.find { |c| c["name"].as_s == "preview_view" && c["status"].as_s == "ok" }
          preview_chunk.should_not be_nil

          forwarded = JSON.parse(preview_chunk.not_nil!["arguments"].as_s)
          forwarded["kind"].as_s.should eq("document")
        end
      ensure
        server.close
      end
    end
  end
end
