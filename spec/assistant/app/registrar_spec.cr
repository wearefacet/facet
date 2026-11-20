# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "agent-cr"
require "../../support/app_assistant_helper"

require "../../../src/assistant/app/registrar"
require "../../../src/assistant/app/context"

# Reopens Agent to expose the enabled tool names and a registered
# callback — same glue as the workspace registrar spec.
class Agent
  def registered_app_tool_names : Array(String)
    @registered_tools.lock(&.keys)
  end

  def registered_app_tool_callback(name : String)
    entry = @registered_tools.lock { |t| t[name]? }
    return nil unless entry && (cb = entry[:callback])
    cb
  end
end

# Invokes a registered app tool callback by name and returns the parsed JSON.
private def appas_call_tool(agent : Agent, name : String, args : Hash(String, JSON::Any)) : JSON::Any
  cb = agent.registered_app_tool_callback(name)
  fail "Tool '#{name}' was not registered" unless cb
  JSON.parse(cb.call(args))
end

describe Facet::Assistant::App::Registrar do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "mounts exactly the registry entries minus ping" do
    expected = Facet::AgentTools::Registry.entries
      .reject { |e| e.name == "ping" }
      .map(&.name)
      .sort!
    Facet::Assistant::App::Registrar.tool_names.sort!.should eq(expected)
  end

  it "registers no skill loader and no UI tools" do
    names = Facet::Assistant::App::Registrar.tool_names
    names.should_not contain("read_skill")
    names.should_not contain("navigate")
    names.should_not contain("show_documents")
    names.should_not contain("preview_view")
    names.should_not contain("go_to_page")
  end

  it "registers the tools on an agent under the caller's auth context" do
    with_db do |db|
      role_id = "appas_reg_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-reg-#{unique_suffix}", true)
      ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

      config = Agent::Config.new(
        api_key: "test",
        api_endpoint: "http://localhost:0",
        model: "test-model",
      )
      agent = Agent.new(config)
      Facet::Assistant::App::Registrar.register(agent, ctx)

      agent.registered_app_tool_names.sort.should eq(Facet::Assistant::App::Registrar.tool_names)
      agent.registered_app_tool_names.should_not contain("ping")
    end
  end

  # ── Repeat-refusal guard ──────────────────────────────────────────────

  describe "repeat-refusal guard" do
    it "returns a terminal result after three identical refusals" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "appasdom", %({"name": {"type": "string", "required": true}}))

        role_id = "appas_guard_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-guard-#{unique_suffix}", true)
        grants = %([{"target": "#{domain}.#{doctype}", "actions": [{"name": "read", "required": true}, {"name": "write", "required": true}]}])
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id, grants)

        agent = Agent.new(Agent::Config.new(
          api_key: "test",
          api_endpoint: "http://localhost:0",
          model: "test-model",
        ))
        Facet::Assistant::App::Registrar.register(agent, ctx)

        args = {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "content" => JSON.parse(%({"name": "nope"})),
        }

        first = appas_call_tool(agent, "create_document", args)
        first["ok"].as_bool.should be_false
        first["terminal"]?.should be_nil

        second = appas_call_tool(agent, "create_document", args)
        second["ok"].as_bool.should be_false
        second["terminal"]?.should be_nil

        third = appas_call_tool(agent, "create_document", args)
        third["ok"].as_bool.should be_false
        third["terminal"].as_bool.should be_true
        third["error"].as_s.should contain("stop retrying")

        fourth = appas_call_tool(agent, "create_document", args)
        fourth["terminal"].as_bool.should be_true
      end
    end

    it "does not dedupe successful calls" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "appasdom", %({"name": {"type": "string", "required": true}}))
        created = Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme"}), Facet::RBAC::AuthContext.system)
        created.should be_a(Facet::Document::Create::Result)

        role_id = "appas_guard_ok_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-guard-ok-#{unique_suffix}", true)
        grants = %([{"target": "#{domain}.#{doctype}", "actions": [{"name": "read", "required": true}]}])
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id, grants)

        agent = Agent.new(Agent::Config.new(
          api_key: "test",
          api_endpoint: "http://localhost:0",
          model: "test-model",
        ))
        Facet::Assistant::App::Registrar.register(agent, ctx)

        args = {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
        }

        2.times do
          result = appas_call_tool(agent, "list_documents", args)
          result["ok"].as_bool.should be_true
          result["data"].as_h["data"].as_a.size.should eq(1)
        end
      end
    end
  end
end
