# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── App-assistant test helpers ────────────────────────────────────────────
#
# Shared setup for `spec/assistant/app/*_spec.cr`: role/account fixtures,
# app documents through the real pipeline, app-scoped auth contexts, and
# a scripted LLM server for the stream route. Unique names (`appas_`
# prefix): every spec file in the suite compiles into one binary, so
# top-level defs must not collide with the workspace or registration
# helpers.

require "json"
require "http"
require "agent-cr"

require "../../src/iam"
require "../../src/document"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/assistant/app/context"
require "../../src/assistant/app/gate"
require "../../src/assistant/app/registrar"
require "../../src/assistant/app/system_prompt"
require "../../src/rbac"

# Creates an `iam.Roles` projection with a connectivity list and an
# `iam.Account` holding it. Returns the account id.
def appas_create_role_and_account(
  db,
  role_id : String,
  assistant_access : Bool,
  permissions : String = %([{"action": "read", "on": "*.*"}]),
  budget : Int64? = nil,
) : String
  channels = assistant_access ? %w[assistant] : [] of String
  content : Hash(String, JSON::Any) = {
    "name"         => JSON::Any.new(role_id),
    "description"  => JSON::Any.new("App assistant test role"),
    "visible_tags" => JSON.parse(%(["default"])),
    "permissions"  => JSON.parse(permissions),
    "connectivity" => JSON::Any.new(channels.map { |c| JSON::Any.new(c) }),
  }
  content["assistant_token_budget"] = JSON::Any.new(budget) if budget

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
    "name"  => JSON::Any.new("App assistant tester"),
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

# Creates an `app.App` document through the real pipeline (the create Lua
# hook runs — a confidential app cannot carry `assistant_enabled`).
# Returns the projection.
def appas_create_app(
  db,
  slug : String,
  assistant_enabled : Bool,
  client_type : String = "public",
  assistant_prompt : String? = nil,
) : Facet::Mutation::Client::Projection
  prompt_field = assistant_prompt ? %("assistant_prompt": #{assistant_prompt.to_json},) : ""
  body = %({
    "slug": #{slug.to_json},
    "name": "Appas Portal",
    "client_type": #{client_type.to_json},
    #{prompt_field}
    "assistant_enabled": #{assistant_enabled}
  })
  result = Facet::Document::Create.call(db, "app", "App", body, Facet::RBAC::AuthContext.system)
  case result
  in Facet::Document::Create::Result
    result.projection
  in Facet::ServiceError
    raise "appas_create_app setup failed: #{result.message}"
  end
end

# Builds an app-scoped `AuthContext` the way the production auth layer
# does: role content from the projection, the grant resolved from the
# app's `grants` field, and the app id riding on the context.
def appas_app_scoped_context(
  db,
  account_id : String,
  role_id : String,
  app_id : String,
  grants_json : String = %([]),
) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.#{role_id}").not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  app_scope = Facet::RBAC::AppScope.from_content(app_id, JSON.parse(%({"grants": #{grants_json}})))
  effective = Facet::RBAC::GrantResolver.resolve(app_scope, active_role)
  Facet::RBAC::AuthContext.app_scoped(account_id, active_role, effective, app_id)
end

# A plain session `AuthContext` for the account — no app token.
def appas_session_context(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.#{role_id}").not_nil!
  Facet::RBAC::AuthContext.authenticated(
    account_id,
    Facet::RBAC::ActiveRole.from_projection_content(role_content),
  )
end

# Inserts an app conversation row directly. Returns the conversation id.
def appas_insert_conversation(db, created_by : String, app_id : String) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO agent_conversations (id, session_id, cache_key, system_prompt, context, enabled_tools) " \
    "VALUES ($1, $1, $1, 'test prompt', $2, '[]')",
    id, %({"kind":"app","created_by":"#{created_by}","app_id":"#{app_id}"}),
  )
  id
end

# Pins the assistant endpoint and model on the settings singleton — the
# hot-change path the turn start resolves. Same pin the workspace spec
# makes; unique name for the one-binary suite.
def appas_pin_connection(db, api_endpoint : String) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    %({"assistant": {"api_endpoint": "#{api_endpoint}/v1", "model": "gpt-4o"}}),
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

# ── Mock LLM server ───────────────────────────────────────────────────────
#
# Answers the first request with one assistant message carrying the scripted
# tool calls, and every later request with plain text (so the tool loop
# finishes). Same shape as the workspace spec's mock; unique class name for
# the one-binary suite.
class AppasStreamMock
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

def appas_tool_call(name : String, args_json : String) : AppasStreamMock::Call
  AppasStreamMock::Call.new(name, args_json)
end

# Collects the SSE `chunk` events of a raw SSE body.
def appas_sse_chunks(body : String) : Array(JSON::Any)
  body.scan(/event: chunk\ndata: (.+)/).map do |match|
    JSON.parse(match[1])
  end
end
