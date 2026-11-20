# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Workspace assistant spec helpers ────────────────────────────────────────
#
# Shared setup for `spec/assistant/workspace/*_spec.cr`: opens the Agent to
# expose registered tool callbacks, builds a workspace agent, and seeds
# doctypes/documents for the delegated-tool cases.

require "agent-cr"

require "../../src/assistant/workspace/registrar"
require "../../src/assistant/workspace/context"
require "../../src/iam"
require "../../src/document"
require "./doctype_helper"
require "./iam_helper"
require "./agent_tools_helper"
require "json"

# Test-only Agent access. The Agent stores tool callbacks in a private
# `@registered_tools` hash, so the spec reopens the class to expose the
# callback by name and invoke it directly — no OpenAI HTTP loop involved.
# `registered_workspace_tool` exposes the tool definition itself for
# schema assertions. Same glue as `spec/assistant/domain_builder/tools_spec.cr`.
class Agent
  def registered_workspace_tool_callback(name : String)
    entry = @registered_tools.lock { |t| t[name]? }
    return nil unless entry && (cb = entry[:callback])
    cb
  end

  def registered_workspace_tool(name : String) : Tool?
    entry = @registered_tools.lock { |t| t[name]? }
    entry.try &.[:tool]
  end
end

# Builds a real `Agent`, registers the full workspace tool set onto it, and
# returns it. The `db` is captured by the UI-tool callbacks.
def build_workspace_agent(db : DB::Connection, auth_context : Facet::RBAC::AuthContext) : Agent
  config = Agent::Config.new(
    api_key: "test",
    api_endpoint: "http://localhost:0",
    model: "test-model",
  )
  agent = Agent.new(config)
  Facet::Assistant::Workspace::Registrar.register(
    agent, db,
    Facet::Assistant::Workspace::Context.new(created_by: "spec"),
    auth_context,
  )
  agent
end

# Invokes a registered tool callback by name and returns the parsed JSON.
def call_workspace_tool(agent : Agent, name : String, args : Hash(String, JSON::Any)) : JSON::Any
  cb = agent.registered_workspace_tool_callback(name)
  if cb.nil?
    fail "Tool '#{name}' was not registered"
  end
  JSON.parse(cb.not_nil!.call(args))
end

# Invokes a registered tool callback and returns its `data` payload, failing
# when the envelope is an error.
def workspace_tool_data(agent : Agent, name : String, args : Hash(String, JSON::Any)) : JSON::Any
  result = call_workspace_tool(agent, name, args)
  result["ok"].as_bool.should be_true, "Tool '#{name}' failed: #{result["error"]?}"
  result["data"]
end

# Creates one document of the given doctype under `system`, carrying the
# given `name` and an optional qualified `owner_id` reference value. Returns
# the projection id.
def create_ws_doc(db, domain : String, doctype : String, name : String, owner_id : String?) : String
  content = if owner_id
              %({"name": "#{name}", "owner_id": "#{owner_id}"})
            else
              %({"name": "#{name}"})
            end
  create_doc_via_service(db, domain, doctype, content)
end

# A Real principal whose read grant on `domain.doctype` carries the `mine`
# named scope — the same shape a scoped role projection produces.
def scoped_role_context(caller_id : String, domain : String, doctype : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "iam.Roles.ws_scope",
    visible_tags: Set.new(["default"]),
    permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype], scope: "$mine")],
  )
  Facet::RBAC::AuthContext.authenticated(caller_id, role)
end
