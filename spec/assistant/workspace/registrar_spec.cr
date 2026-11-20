# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../support/workspace_test_helpers"

# Workspace registrar (step 4.4 of the workspace-assistant plan).
#
# Controls pinned here:
# - Toolset parity: the document tool set equals `AgentTools::Registry`
# entries minus `ping`, and each mounted schema equals the registry's
# `input_schema`; the agent exposes exactly the workspace tool set.
# - A seeded account with a scoped role sees only in-scope rows through
# `list_documents`.
# - A denied read maps to the non-disclosing not-found envelope; a refused
# write maps to the refused envelope with no permission detail.
# - `navigate` validates shape and read access; `show_documents` splits ids
# into rendered and skipped.
describe Facet::Assistant::Workspace::Registrar do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  # ── Toolset parity ────────────────────────────────────────────────────

  describe "toolset parity" do
    it "mounts exactly the registry entries minus ping" do
      expected = Facet::AgentTools::Registry.entries
        .reject { |e| e.name == "ping" }
        .map(&.name)
      Facet::Assistant::Workspace::Registrar.document_tool_names.should eq(expected)
    end

    it "exposes exactly the workspace tool set: registry minus ping, read_skill, and the UI tools" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)

        expected = (
          Facet::AgentTools::Registry.entries.reject { |e| e.name == "ping" }.map(&.name) +
          ["read_skill", "navigate", "show_documents"]
        ).sort
        agent.enabled_tools.sort.should eq(expected)
        agent.enabled_tools.sort.should eq(Facet::Assistant::Workspace::Registrar.tool_names)
      end
    end

    it "keeps every registry schema convertible — the mounted schema equals the registry input_schema" do
      # The registrar feeds `schema_parameters(entry.input_schema)` into
      # `register_tool`; pin that the conversion is lossless for every real
      # entry, so mounted metadata always equals the registry's.
      Facet::AgentTools::Registry.entries.each do |entry|
        params = Facet::Assistant::Tools.schema_parameters(entry.input_schema)
        registry = entry.input_schema.as_h
        params.should eq(registry)
      end
    end

    it "does not register ping" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)
        agent.enabled_tools.should_not contain("ping")
      end
    end

    it "declares the show_documents ids argument as a non-empty array of strings" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)
        tool = agent.registered_workspace_tool("show_documents").not_nil!
        ids = tool.function.parameters.not_nil!["properties"].as_h["ids"].as_h
        ids["type"].as_s.should eq("array")
        ids["items"].as_h["type"].as_s.should eq("string")
        ids["minItems"].as_i.should eq(1)
      end
    end
  end

  # ── Delegated document tools ──────────────────────────────────────────

  describe "delegated document tools" do
    it "runs list_documents through the registry with the caller's auth context" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))
        create_ws_doc(db, domain, doctype, "Acme", nil)
        create_ws_doc(db, domain, doctype, "Other", nil)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
        ctx = Facet::RBAC::AuthContext.authenticated(
          caller_id, Facet::RBAC::ActiveRole.from_projection_content(role_content)
        )

        agent = build_workspace_agent(db, ctx)
        data = workspace_tool_data(agent, "list_documents", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
        })
        names = data["data"].as_a.map(&.as_h.["data"].as_h.["name"].as_s)
        names.sort.should eq(["Acme", "Other"])
      end
    end

    it "sees only in-scope rows through list_documents under a scoped role" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, doctype = build_agg_doctype(db, "wsreg", fields, scopes)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "wsreg-other@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        create_ws_doc(db, domain, doctype, "mine", "iam.Account.#{caller_id}")
        create_ws_doc(db, domain, doctype, "theirs", "iam.Account.#{other_id}")

        ctx = scoped_role_context(caller_id, domain, doctype)
        agent = build_workspace_agent(db, ctx)

        data = workspace_tool_data(agent, "list_documents", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
        })
        names = data["data"].as_a.map(&.as_h.["data"].as_h.["name"].as_s)
        names.should eq(["mine"])
      end
    end

    it "maps a denied read to the non-disclosing not-found envelope" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, doctype = build_agg_doctype(db, "wsreg", fields, scopes)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "wsreg-deny@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        hidden_id = create_ws_doc(db, domain, doctype, "secret", "iam.Account.#{other_id}")

        ctx = scoped_role_context(caller_id, domain, doctype)
        agent = build_workspace_agent(db, ctx)

        result = call_workspace_tool(agent, "get_document", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "doc_id"  => JSON::Any.new(hidden_id),
        })

        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("not found")
        # Non-disclosing: the envelope says nothing about permissions.
        result["error"].as_s.downcase.should_not contain("permission")
        result["error"].as_s.downcase.should_not contain("forbidden")
      end
    end

    it "maps a refused write to the refused envelope with no permission detail" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))

        # A read-only principal: create_document must be refused.
        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
        ctx = Facet::RBAC::AuthContext.authenticated(
          caller_id, Facet::RBAC::ActiveRole.from_projection_content(role_content)
        )

        agent = build_workspace_agent(db, ctx)
        result = call_workspace_tool(agent, "create_document", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "content" => JSON.parse(%({"name": "nope"})),
        })

        result["ok"].as_bool.should be_false
        result["error"].as_s.should eq("Forbidden")
      end
    end

    it "stamps the assistant cause on a delegated write" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))

        caller_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
        ctx = Facet::RBAC::AuthContext.authenticated(
          caller_id, Facet::RBAC::ActiveRole.from_projection_content(role_content)
        )

        agent = build_workspace_agent(db, ctx)
        data = workspace_tool_data(agent, "create_document", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "content" => JSON.parse(%({"name": "by assistant"})),
        })
        doc_id = data["meta"].as_h["id"].as_s

        # Root assistant cause: an audit viewer can tell this write from a
        # plain session edit. The session channel alone does not — the tool
        # runs under the caller's own auth context by design.
        kind, actioner = db.query_one(
          "SELECT cause_kind, actioner_id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
          domain, doctype, doc_id,
          as: {String, String},
        )
        kind.should eq("assistant")
        actioner.should eq(caller_id)
      end
    end
  end

  # ── Repeat-refusal guard ──────────────────────────────────────────────

  describe "repeat-refusal guard" do
    it "returns a terminal result after three identical refusals" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
        ctx = Facet::RBAC::AuthContext.authenticated(
          caller_id, Facet::RBAC::ActiveRole.from_projection_content(role_content)
        )

        agent = build_workspace_agent(db, ctx)
        args = {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "content" => JSON.parse(%({"name": "nope"})),
        }

        first = call_workspace_tool(agent, "create_document", args)
        first["ok"].as_bool.should be_false
        first["terminal"]?.should be_nil

        second = call_workspace_tool(agent, "create_document", args)
        second["ok"].as_bool.should be_false
        second["terminal"]?.should be_nil

        third = call_workspace_tool(agent, "create_document", args)
        third["ok"].as_bool.should be_false
        third["terminal"].as_bool.should be_true
        third["error"].as_s.should contain("stop retrying")

        fourth = call_workspace_tool(agent, "create_document", args)
        fourth["terminal"].as_bool.should be_true
      end
    end

    it "does not dedupe successful calls" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))
        create_ws_doc(db, domain, doctype, "Acme", nil)

        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.system)
        args = {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
        }

        2.times do
          data = workspace_tool_data(agent, "list_documents", args)
          data["data"].as_a.size.should eq(1)
        end
      end
    end
  end

  # ── UI tools ──────────────────────────────────────────────────────────

  describe "navigate" do
    it "acks a readable document target" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "wsreg", %({"name": {"type": "string", "required": true}}))
        doc_id = create_ws_doc(db, domain, doctype, "Acme", nil)

        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.system)
        data = workspace_tool_data(agent, "navigate", {
          "target"  => JSON::Any.new("document"),
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "id"      => JSON::Any.new(doc_id),
        })
        data["navigated"].as_bool.should be_true
        data["target"].as_s.should eq("document")
      end
    end

    it "errors on a bad shape" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)

        # Unknown target kind
        result = call_workspace_tool(agent, "navigate", {
          "target" => JSON::Any.new("portal"),
          "domain" => JSON::Any.new("wsreg"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("Unknown target")

        # A document target without id — the error names what arrived
        result = call_workspace_tool(agent, "navigate", {
          "target"  => JSON::Any.new("document"),
          "domain"  => JSON::Any.new("wsreg"),
          "doctype" => JSON::Any.new("T1"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("'id'")
        result["error"].as_s.should contain("got nothing")

        # Missing domain
        result = call_workspace_tool(agent, "navigate", {
          "target" => JSON::Any.new("domain"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("domain")
      end
    end

    it "errors when the document target is unreadable" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, doctype = build_agg_doctype(db, "wsreg", fields, scopes)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "wsreg-nav@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        hidden_id = create_ws_doc(db, domain, doctype, "secret", "iam.Account.#{other_id}")

        ctx = scoped_role_context(caller_id, domain, doctype)
        agent = build_workspace_agent(db, ctx)

        result = call_workspace_tool(agent, "navigate", {
          "target"  => JSON::Any.new("document"),
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "id"      => JSON::Any.new(hidden_id),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("not available")
      end
    end

    it "acks collection and domain targets on shape alone" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)

        data = workspace_tool_data(agent, "navigate", {
          "target"    => JSON::Any.new("collection"),
          "domain"    => JSON::Any.new("wsreg"),
          "doctype"   => JSON::Any.new("T1"),
          "view_slug" => JSON::Any.new("open"),
        })
        data["navigated"].as_bool.should be_true
        data["view_slug"].as_s.should eq("open")

        data = workspace_tool_data(agent, "navigate", {
          "target" => JSON::Any.new("domain"),
          "domain" => JSON::Any.new("wsreg"),
        })
        data["navigated"].as_bool.should be_true
      end
    end
  end

  describe "show_documents" do
    it "acks mixed ids: rendered lists the readable, the report names the rest" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, doctype = build_agg_doctype(db, "wsreg", fields, scopes)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "wsreg-show@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        mine_id = create_ws_doc(db, domain, doctype, "mine", "iam.Account.#{caller_id}")
        theirs_id = create_ws_doc(db, domain, doctype, "theirs", "iam.Account.#{other_id}")
        missing_id = Facet::Util::ScriptHelpers.ulid

        ctx = scoped_role_context(caller_id, domain, doctype)
        agent = build_workspace_agent(db, ctx)

        data = workspace_tool_data(agent, "show_documents", {
          "domain"  => JSON::Any.new(domain),
          "doctype" => JSON::Any.new(doctype),
          "ids"     => JSON.parse(%(["#{mine_id}", "#{theirs_id}", "#{missing_id}"])),
        })
        data["rendered"].as_a.map(&.as_s).should eq([mine_id])
        data["skipped"].as_a.map(&.as_s).sort!.should eq([missing_id, theirs_id].sort)
        data["display"].as_s.should eq("card")
      end
    end

    it "rejects a bad display value" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)
        result = call_workspace_tool(agent, "show_documents", {
          "domain"  => JSON::Any.new("wsreg"),
          "doctype" => JSON::Any.new("T1"),
          "ids"     => JSON.parse(%(["a"])),
          "display" => JSON::Any.new("banner"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("display")
      end
    end

    it "rejects a malformed ids argument and reports what it received" do
      with_db do |db|
        agent = build_workspace_agent(db, Facet::RBAC::AuthContext.denied)

        result = call_workspace_tool(agent, "show_documents", {
          "domain"  => JSON::Any.new("wsreg"),
          "doctype" => JSON::Any.new("T1"),
          "ids"     => JSON.parse("[]"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("ids")
        result["error"].as_s.should contain("empty array")

        result = call_workspace_tool(agent, "show_documents", {
          "domain"  => JSON::Any.new("wsreg"),
          "doctype" => JSON::Any.new("T1"),
          "ids"     => JSON.parse(%([42])),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("non-string item at index 0")
        result["error"].as_s.should contain("number")

        result = call_workspace_tool(agent, "show_documents", {
          "domain"  => JSON::Any.new("wsreg"),
          "doctype" => JSON::Any.new("T1"),
          "ids"     => JSON.parse("null"),
        })
        result["ok"].as_bool.should be_false
        result["error"].as_s.should contain("got null")
      end
    end
  end
end
