# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "agent-cr"
require "../../../src/assistant/domain_builder/tools"
require "../../../src/assistant/domain_builder/context"
require "../../../src/assistant/domain_builder/auth"
require "../../../src/doctype/definition_store"
require "../../../src/doctype/check"
require "../../../src/doctype/seed"
require "../../../src/domain/draft"

# ── Test-only Agent access ──────────────────────────────────────────────────
#
# The Agent stores tool callbacks in a private `@registered_tools`
# `Sync::Exclusive` hash and `execute_registered_tools` is private. We reopen
# the class here to expose the registered callback by name, so the spec can
# invoke it directly without mocking the OpenAI HTTP loop.
#
# This is test-only glue; the production code never reaches in here.
class Agent
  def registered_tool_callback(name : String)
    entry = @registered_tools.lock { |t| t[name]? }
    return nil unless entry && (cb = entry[:callback])
    cb
  end
end

# ── Helpers ─────────────────────────────────────────────────────────────────

# Builds a real `Agent`, registers the full domain-builder tool set onto
# it, and returns it. The `db` is the test's connection captured by every
# tool callback.
def build_domain_builder_agent(db : DB::Connection, context : Facet::Assistant::DomainBuilder::Context) : Agent
  config = Agent::Config.new(
    api_key: "test",
    api_endpoint: "http://localhost:0",
    model: "test-model",
  )
  agent = Agent.new(config)
  Facet::Assistant::DomainBuilder::Registrar.register(agent, db, context)
  agent
end

# Invokes a registered tool callback by name and returns the parsed JSON.
def call_domain_builder_tool(agent : Agent, name : String, args : Hash(String, JSON::Any)) : JSON::Any
  cb = agent.registered_tool_callback(name)
  cb.should_not be_nil, "Tool '#{name}' was not registered"
  result = cb.not_nil!.call(args)
  JSON.parse(result)
end

# Invokes a registered tool callback by name and returns the raw string
# return value (no JSON parse). Used for `read_skill`, whose success path
# returns the skill's raw markdown body rather than a JSON envelope.
def call_domain_builder_tool_raw(agent : Agent, name : String, args : Hash(String, JSON::Any)) : String
  cb = agent.registered_tool_callback(name)
  cb.should_not be_nil, "Tool '#{name}' was not registered"
  cb.not_nil!.call(args)
end

# Creates a draft domain and returns a domain-builder `Context`.
def make_domain_builder_context(db : DB::Connection, created_by = "system:assistant") : Facet::Assistant::DomainBuilder::Context
  result = Facet::Domain::Draft.create(db, "{}", created_by)
  result.should be_a(Facet::Domain::Draft::Result)
  draft_domain = result.as(Facet::Domain::Draft::Result).projection.id
  Facet::Assistant::DomainBuilder::Context.new(draft_domain: draft_domain, created_by: created_by)
end

# Builds a minimal doctype definition JSON::Any with the given doctype
# name and domain. The definition has a single required string field,
# just enough to satisfy `Doctype::Create`.
def doctype_definition_json(name : String, domain : String, schema_version = 1) : JSON::Any
  JSON.parse(%({
    "doctype": "#{name}",
    "domain": "#{domain}",
    "schema_version": #{schema_version},
    "fields": {
      "label": {"type": "string", "required": true}
    }
  }))
end

# Persists a doctype directly into the draft domain by writing to
# `core.DocType` via the mutation client — bypasses `Doctype::Create`'s
# domain-name regex (which rejects the `_` prefix), the same pattern used
# by `spec/domain/draft_domains_spec.cr`.
def seed_doctype_in_draft(db : DB::Connection, domain : String, doctype : String) : String
  doc_id = "#{domain}.#{doctype}"
  content = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "schema_version": 1,
    "fields": {"label": {"type": "string", "required": true}}
  })
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
  doc_id
end

# Persists a child doctype (one declaring `member_of`) into the draft —
# the composition edge the `create_document` parent gate reads.
def seed_child_doctype_in_draft(db : DB::Connection, domain : String, doctype : String, parent : String) : String
  doc_id = "#{domain}.#{doctype}"
  content = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "schema_version": 1,
    "member_of": "#{parent}",
    "fields": {"label": {"type": "string", "required": true}}
  })
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate(doc_id)
  doc_id
end

module Facet::Assistant::DomainBuilder
  describe Registrar do
    before_each do
      # The global per-test TRUNCATE wipes the seeded core doctypes
      # (`core.DocType`, `core.Domain`, `core.DocumentView`). The domain
      # builder's write tools call `Document::Create` / `Document::Delete`,
      # which look up the target doctype's definition from `core.DocType`
      # projections — so those meta-doctypes must exist. Re-ensure
      # (idempotent) just the doctypes the tools touch.
      with_db do |db|
        %w[core.DocType core.Domain core.DocumentView core.CollectionView].each do |dir|
          domain, doctype = dir.split(".", 2)
          Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
        end
        Facet::Doctype::DefinitionStore.cache.clear
      end
      Facet::Event::Publisher.flush
    end

    # ── Registration ──────────────────────────────────────────────────────

    describe ".register" do
      it "registers every tool in TOOL_NAMES and none are left out" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # Every tool name in TOOL_NAMES should resolve to a registered
          # callback.
          Registrar::TOOL_NAMES.each do |name|
            agent.registered_tool_callback(name).should_not be_nil,
              "Tool '#{name}' was not registered"
          end
        end
      end
    end

    # ── Draft-domain guards (the most important behavior) ────────────────

    describe "draft-domain guards" do
      it "create_doctype rejects a definition whose domain is not the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # definition.domain = "live-domain" ≠ draft
          definition = doctype_definition_json("Widget", "live-domain")
          result = call_domain_builder_tool(agent, "create_doctype",
            {"definition" => definition})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the conversation's draft domain")
        end
      end

      it "update_doctype refuses a doctype that belongs to another domain" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # Seed a doctype in a live domain.
          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-domain", content: "{}",
            actioner_id: "system:test",
          )
          seed_doctype_in_draft(db, "live-domain", "Widget")

          result = call_domain_builder_tool(agent, "update_doctype",
            {"doctype_id" => JSON::Any.new("live-domain.Widget"),
             "definition" => doctype_definition_json("Widget", context.draft_domain)})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the draft")
        end
      end

      it "delete_doctype refuses a doctype that belongs to another domain" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-domain", content: "{}",
            actioner_id: "system:test",
          )
          seed_doctype_in_draft(db, "live-domain", "Widget")

          result = call_domain_builder_tool(agent, "delete_doctype",
            {"doctype_id" => JSON::Any.new("live-domain.Widget")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the draft")
        end
      end

      it "create_document_view rejects when the parent doctype is not in the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-domain", content: "{}",
            actioner_id: "system:test",
          )
          seed_doctype_in_draft(db, "live-domain", "Widget")

          result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new("live-domain.Widget"),
             "kind"           => JSON::Any.new("form")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the draft")
        end
      end

      it "create_document refuses a doctype not registered in the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # No doctype `Widget` exists in the draft at all — the guard
          # lookups `#{draft}.Widget` and finds nothing.
          result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Widget"),
             "content" => JSON.parse(%({"label": "x"}))})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end

      it "delete_document refuses when the document does not exist in the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "delete_document",
            {"doctype" => JSON::Any.new("Widget"),
             "doc_id"  => JSON::Any.new("01NONEXISTENT")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end
    end

    # ── Missing-argument validation ──────────────────────────────────────

    describe "missing arguments" do
      it "create_doctype reports a missing definition" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "create_doctype", {} of String => JSON::Any)
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("Missing 'definition'")
        end
      end

      it "create_doctype missing-argument error asks for a complete re-emit" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "create_doctype", {} of String => JSON::Any)
          result["ok"].as_bool.should be_false
          # The message states that the call arrived without the argument
          # and asks the caller to send the complete tool call again.
          result["error"].as_s.should contain("the previous call reached the server without it")
          result["error"].as_s.should contain("Re-emit the complete tool call")
        end
      end

      it "get_doctype reports a missing doctype_id" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "get_doctype", {} of String => JSON::Any)
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("Missing 'doctype_id'")
        end
      end

      it "read_skill reports a missing name" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "read_skill", {} of String => JSON::Any)
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("Missing 'name'")
        end
      end
    end

    # ── Read-only tool happy paths ───────────────────────────────────────

    describe "read tools" do
      it "list_domains returns live domains as rows" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # Seed a live domain.
          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-x", content: %({"description":"x"}),
            actioner_id: "system:test",
          )

          result = call_domain_builder_tool(agent, "list_domains", {} of String => JSON::Any)
          result["ok"].as_bool.should be_true
          ids = result["data"].as_a.map(&.["id"].as_s)
          ids.should contain("live-x")
          # The draft domain is also a core.Domain projection — it shows up
          # here too (with draft: true).
          ids.should contain(context.draft_domain)
        end
      end

      it "list_doctypes defaults to the draft domain and returns seeded doctypes" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "list_doctypes", {} of String => JSON::Any)
          result["ok"].as_bool.should be_true
          rows = result["data"].as_a
          widget = rows.find { |r| r["doctype"].as_s == "Widget" }
          widget.should_not be_nil
          widget.not_nil!["domain"].as_s.should eq(context.draft_domain)
        end
      end

      it "get_doctype returns a definition and works cross-domain" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # Live domain + doctype.
          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live", content: "{}",
            actioner_id: "system:test",
          )
          live_doctype_id = seed_doctype_in_draft(db, "live", "Thing")

          result = call_domain_builder_tool(agent, "get_doctype",
            {"doctype_id" => JSON::Any.new(live_doctype_id)})
          result["ok"].as_bool.should be_true
          result["data"]["doctype_id"].as_s.should eq(live_doctype_id)
          result["data"]["definition"].as_h["doctype"].as_s.should eq("Thing")
        end
      end

      it "get_doctype returns an error when the doctype does not exist" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "get_doctype",
            {"doctype_id" => JSON::Any.new("nope.NotFound")})
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end

      it "list_document_views returns views for a draft doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")
          call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form")})

          result = call_domain_builder_tool(agent, "list_document_views",
            {"doctype" => JSON::Any.new(doctype_id)})
          result["ok"].as_bool.should be_true
          items = result["data"]["items"].as_a
          items.size.should eq(1)
          items[0]["kind"].as_s.should eq("form")
          items[0]["parent_doctype"].as_s.should eq(doctype_id)
        end
      end

      it "list_document_views rejects a doctype outside the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-domain", content: "{}",
            actioner_id: "system:test",
          )
          seed_doctype_in_draft(db, "live-domain", "Widget")

          result = call_domain_builder_tool(agent, "list_document_views",
            {"doctype" => JSON::Any.new("live-domain.Widget")})
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the draft")
        end
      end

      it "get_document_view returns the full template" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")
          create_result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form"),
             "template"       => JSON.parse(%({"type":"col","children":[{"type":"capsule","value":"$name"}]}))})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "get_document_view",
            {"doc_id" => JSON::Any.new(view_id)})
          result["ok"].as_bool.should be_true
          result["data"]["kind"].as_s.should eq("form")
          result["data"]["template"].as_h["type"].as_s.should eq("col")
        end
      end

      it "get_document_view returns an error for an unknown view" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "get_document_view",
            {"doc_id" => JSON::Any.new("01NONEXISTENT")})
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end

      it "list_collection_views returns views for a draft doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")
          call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new(doctype_id),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table")})

          result = call_domain_builder_tool(agent, "list_collection_views",
            {"doctype" => JSON::Any.new(doctype_id)})
          result["ok"].as_bool.should be_true
          items = result["data"]["items"].as_a
          items.size.should eq(1)
          items[0]["name"].as_s.should eq("All")
        end
      end

      it "get_collection_view returns the full config" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")
          create_result = call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new(doctype_id),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table"),
             "config"  => JSON.parse(%({"columns":[{"key":"label"}]}))})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "get_collection_view",
            {"doc_id" => JSON::Any.new(view_id)})
          result["ok"].as_bool.should be_true
          result["data"]["name"].as_s.should eq("All")
          result["data"]["config"].as_h["columns"].as_a.size.should eq(1)
        end
      end

      it "get_domain returns the draft domain content" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "get_domain",
            {"domain" => JSON::Any.new(context.draft_domain)})
          result["ok"].as_bool.should be_true
          result["data"]["id"].as_s.should eq(context.draft_domain)
          result["data"]["draft"].as_bool.should be_true
        end
      end

      it "read_skill returns the raw markdown body" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool_raw(agent, "read_skill",
            {"name" => JSON::Any.new("iteration-workflow")})
          # The success payload is the skill's raw markdown, not a JSON
          # envelope — it begins with the `# Title` heading and is not
          # JSON-escaped.
          result.should start_with("# Iteration Workflow")
          result.should contain("create → check → update → re-check")
          result.should_not contain("\\n")
        end
      end

      it "read_skill returns an error for an unknown skill" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "read_skill",
            {"name" => JSON::Any.new("nonexistent")})
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end
    end

    # ── check_doctype ────────────────────────────────────────────────────

    describe "check_doctype" do
      it "returns the doctype_id and an issues array" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "check_doctype",
            {"doctype_id" => JSON::Any.new(doctype_id)})
          result["ok"].as_bool.should be_true
          result["data"]["doctype_id"].as_s.should eq(doctype_id)
          # `issues` is an array — its contents vary based on cross-doctype
          # state, so we only assert the key exists.
          result["data"].as_h.has_key?("issues").should be_true
        end
      end
    end

    # ── check_domain ─────────────────────────────────────────────────────

    describe "check_domain" do
      it "returns the draft domain, its domain_issues and its doctypes" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "check_domain", {} of String => JSON::Any)
          result["ok"].as_bool.should be_true
          result["data"]["domain"].as_s.should eq(context.draft_domain)
          # `domain_issues` is an array — its contents vary based on
          # cross-doctype state, so we only assert the key exists.
          result["data"].as_h.has_key?("domain_issues").should be_true
          # The fresh draft holds exactly one doctype — the seeded one.
          doctypes = result["data"]["doctypes"].as_a
          doctypes.size.should eq(1)
          doctypes[0]["doctype_id"].as_s.should eq(doctype_id)
          doctypes[0].as_h.has_key?("issue_count").should be_true
          doctypes[0].as_h.has_key?("issues").should be_true
          doctypes[0].as_h.has_key?("notices").should be_true
        end
      end

      it "reports a missing draft domain instead of raising" do
        with_db do |db|
          # A context whose draft_domain points at no projection. The read
          # tools register without the draft guard, so the tool — not the
          # registrar — must surface the 404 as an error payload.
          context = Facet::Assistant::DomainBuilder::Context.new(draft_domain: "ghost-domain")
          agent = build_domain_builder_agent(db, context)

          # The draft guard skipped the write tools for this context.
          agent.registered_tool_callback("create_doctype").should be_nil

          result = call_domain_builder_tool(agent, "check_domain", {} of String => JSON::Any)
          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end
    end

    # ── Write tool happy paths ────────────────────────────────────────────

    describe "write tools" do
      it "create_doctype accepts a valid definition scoped to the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          definition = doctype_definition_json("Widget", context.draft_domain)
          result = call_domain_builder_tool(agent, "create_doctype",
            {"definition" => definition})

          result["ok"].as_bool.should be_true
          result["data"]["doctype_id"].as_s.should eq("#{context.draft_domain}.Widget")
          result["data"]["schema_version"].as_i.should eq(1)
        end
      end

      it "update_doctype replaces an existing definition in the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          new_defn = doctype_definition_json("Widget", context.draft_domain)
          result = call_domain_builder_tool(agent, "update_doctype",
            {"doctype_id" => JSON::Any.new(doctype_id),
             "definition" => new_defn})

          result["ok"].as_bool.should be_true
          result["data"]["doctype_id"].as_s.should eq(doctype_id)
          result["data"]["mutation_id"].as_s.should_not be_empty
        end
      end

      it "delete_doctype soft-deletes a doctype in the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "delete_doctype",
            {"doctype_id" => JSON::Any.new(doctype_id)})

          result["ok"].as_bool.should be_true
          result["data"]["doctype_id"].as_s.should eq(doctype_id)
          result["data"]["deleted"].as_bool.should be_true

          # Confirm the row is soft-deleted.
          deleted_at = db.query_one?(
            "SELECT deleted_at FROM projections WHERE id=$1",
            doctype_id,
            as: Time?,
          )
          deleted_at.should_not be_nil
        end
      end

      it "create_document_view persists a view under a draft doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form"),
             "template"       => JSON.parse(%({"type":"col","children":[{"type":"capsule","value":"$name"}]}))})

          result["ok"].as_bool.should be_true
          result["data"]["parent_doctype"].as_s.should eq(doctype_id)
          result["data"]["kind"].as_s.should eq("form")
          result["data"]["doc_id"].as_s.should_not be_empty
        end
      end

      it "create_document_view rejects a malformed template with node paths" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          # The crash class this validation exists for: an input node
          # without its `field` binding.
          result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form"),
             "template"       => JSON.parse(%({"type":"col","children":[{"type":"input-text","label":"Broken"}]}))})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("validation failed")
          details = result["details"].as_a
          details.any? { |d| d["field"].as_s == "template.children.0.field" }.should be_true
          details.any? { |d| d["code"].as_s == "template" }.should be_true
        end
      end

      it "create_document_view rejects an input bound to an unknown field" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget") # fields: label

          result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form"),
             "template"       => JSON.parse(%({"type":"col","children":[{"type":"input-text","field":"nope","label":"Nope"}]}))})

          result["ok"].as_bool.should be_false
          details = result["details"].as_a
          details.any? { |d| d["message"].as_s.includes?("not a defined field") }.should be_true
        end
      end

      it "create_document_view rejects a dotted input binding against the definition" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          # A doctype with a nested object field — the exact shape the
          # Widget incident shipped: config.enabled / config.version.
          doc_id = "#{context.draft_domain}.Widget"
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: doc_id,
            content: %({
              "doctype": "Widget",
              "domain": "#{context.draft_domain}",
              "schema_version": 1,
              "fields": {
                "title": {"type": "string", "required": true},
                "config": {"type": "object", "properties": {
                  "enabled": {"type": "boolean"}
                }}
              }
            }),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate(doc_id)

          result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doc_id),
             "kind"           => JSON::Any.new("form"),
             "template"       => JSON.parse(%({"type":"col","children":[{"type":"input-toggle","field":"config.enabled","label":"Enabled"}]}))})

          result["ok"].as_bool.should be_false
          details = result["details"].as_a
          details.any? { |d| d["message"].as_s.includes?("dotted field paths are not supported") }.should be_true
        end
      end

      it "update_document_view updates an existing view" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form")})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "update_document_view",
            {"doc_id"   => JSON::Any.new(view_id),
             "kind"     => JSON::Any.new("inline"),
             "template" => JSON.parse(%({"type":"col","children":[{"type":"input-text","field":"label","label":"Label"}]}))})

          result["ok"].as_bool.should be_true
          result["data"]["doc_id"].as_s.should eq(view_id)
          result["data"]["updated"].as_bool.should be_true

          # Verify the kind was actually changed in the projection.
          kind = db.query_one?(
            "SELECT content->>'kind' FROM projections WHERE id=$1 AND deleted_at IS NULL",
            view_id,
            as: String?,
          )
          kind.should eq("inline")
        end
      end

      it "delete_document_view soft-deletes a view" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_document_view",
            {"parent_doctype" => JSON::Any.new(doctype_id),
             "kind"           => JSON::Any.new("form")})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "delete_document_view",
            {"doc_id" => JSON::Any.new(view_id)})

          result["ok"].as_bool.should be_true
          result["data"]["doc_id"].as_s.should eq(view_id)
          result["data"]["deleted"].as_bool.should be_true
        end
      end

      it "create_collection_view persists a view under a draft doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new(doctype_id),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table"),
             "config"  => JSON.parse(%({"columns":[{"key":"label"}]}))})

          result["ok"].as_bool.should be_true
          result["data"]["name"].as_s.should eq("All")
          result["data"]["surface"].as_s.should eq("table")
          result["data"]["doc_id"].as_s.should_not be_empty

          # The parent linkage is carried by meta.parent_id.
          parent = db.query_one?(
            "SELECT meta->>'parent_id' FROM projections WHERE id=$1 AND deleted_at IS NULL",
            result["data"]["doc_id"].as_s,
            as: String?,
          )
          parent.should eq(doctype_id)
        end
      end

      it "create_collection_view rejects a doctype outside the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "live-domain", content: "{}",
            actioner_id: "system:test",
          )
          seed_doctype_in_draft(db, "live-domain", "Widget")

          result = call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new("live-domain.Widget"),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not the draft")
        end
      end

      it "update_collection_view updates an existing view" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new(doctype_id),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table")})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "update_collection_view",
            {"doc_id" => JSON::Any.new(view_id),
             "name"   => JSON::Any.new("Open"),
             "config" => JSON.parse(%({"columns":[{"key":"label"}]}))})

          result["ok"].as_bool.should be_true
          result["data"]["updated"].as_bool.should be_true

          name = db.query_one?(
            "SELECT content->>'name' FROM projections WHERE id=$1 AND deleted_at IS NULL",
            view_id,
            as: String?,
          )
          name.should eq("Open")
        end
      end

      it "delete_collection_view soft-deletes a view" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_collection_view",
            {"doctype" => JSON::Any.new(doctype_id),
             "name"    => JSON::Any.new("All"),
             "surface" => JSON::Any.new("table")})
          view_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "delete_collection_view",
            {"doc_id" => JSON::Any.new(view_id)})

          result["ok"].as_bool.should be_true
          result["data"]["deleted"].as_bool.should be_true
        end
      end

      it "create_document persists a document of a draft doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Widget"),
             "content" => JSON.parse(%({"label": "Hello"}))})

          result["ok"].as_bool.should be_true
          result["data"]["doc_id"].as_s.should_not be_empty
          result["data"]["mutation_id"].as_s.should_not be_empty
        end
      end

      it "list_documents returns doc_id and parent_id per item" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Widget"),
             "content" => JSON.parse(%({"label": "Hello"}))})
          doc_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "list_documents",
            {"doctype" => JSON::Any.new("Widget")})

          result["ok"].as_bool.should be_true
          items = result["data"]["items"].as_a
          items.size.should eq(1)
          items.first.as_h["doc_id"].as_s.should eq(doc_id)
          items.first.as_h["content"].as_h["label"].as_s.should eq("Hello")
          items.first.as_h["parent_id"]?.should be_nil
        end
      end

      it "create_document seeds a child document under a parent" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Machine")
          seed_child_doctype_in_draft(db, context.draft_domain, "MachinePart", "Machine")

          parent = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Machine"),
             "content" => JSON.parse(%({"label": "Press 1"}))})
          parent_id = parent["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype"   => JSON::Any.new("MachinePart"),
             "content"   => JSON.parse(%({"label": "Bolt"})),
             "parent_id" => JSON::Any.new(parent_id)})

          result["ok"].as_bool.should be_true
          child_id = result["data"]["doc_id"].as_s

          # The child carries the parent link in its meta and the parent's
          # list reports it back.
          row = db.query_one(
            "SELECT meta->>'parent_id' FROM projections WHERE domain=$1 AND doc_type='MachinePart' AND id=$2",
            context.draft_domain, child_id, as: String?)
          row.should eq(parent_id)

          listed = call_domain_builder_tool(agent, "list_documents",
            {"doctype" => JSON::Any.new("MachinePart")})
          listed["data"]["items"].as_a.first.as_h["parent_id"].as_s.should eq(parent_id)
        end
      end

      it "create_document refuses a child doctype without parent_id" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Machine")
          seed_child_doctype_in_draft(db, context.draft_domain, "MachinePart", "Machine")

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("MachinePart"),
             "content" => JSON.parse(%({"label": "Bolt"}))})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("pass 'parent_id'")
        end
      end

      it "create_document refuses parent_id on a root doctype" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Machine")

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype"   => JSON::Any.new("Machine"),
             "content"   => JSON.parse(%({"label": "Press 1"})),
             "parent_id" => JSON::Any.new("whatever")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("declares no member_of")
        end
      end

      it "create_document refuses a parent_id pointing outside the draft" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Machine")
          seed_child_doctype_in_draft(db, context.draft_domain, "MachinePart", "Machine")

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype"   => JSON::Any.new("MachinePart"),
             "content"   => JSON.parse(%({"label": "Bolt"})),
             "parent_id" => JSON::Any.new("ghost-id")})

          result["ok"].as_bool.should be_false
          result["error"].as_s.should contain("not found")
        end
      end

      it "delete_document soft-deletes a draft document" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Widget")

          create_result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Widget"),
             "content" => JSON.parse(%({"label": "Bye"}))})
          doc_id = create_result["data"]["doc_id"].as_s

          result = call_domain_builder_tool(agent, "delete_document",
            {"doctype" => JSON::Any.new("Widget"),
             "doc_id"  => JSON::Any.new(doc_id)})

          result["ok"].as_bool.should be_true
          result["data"]["doc_id"].as_s.should eq(doc_id)
          result["data"]["deleted"].as_bool.should be_true
        end
      end
    end

    # ── Write-tool audit attribution ────────────────────────────────────

    # Write mutations must be attributed to the conversation owner (the
    # account in `context.created_by`), not to the assistant principal,
    # and must carry the root `assistant` cause named `domain-builder`.
    # The audit surfaces combine both stamps into the actor + via-chip
    # rendering; a bare `system:assistant` / `internal` row here means
    # the attribution regressed.
    describe "write-tool audit attribution" do
      it "create_doctype stamps the owner as actioner and the assistant cause" do
        with_db do |db|
          owner_id = Facet::Util::ScriptHelpers.ulid
          context = make_domain_builder_context(db, owner_id)
          agent = build_domain_builder_agent(db, context)

          definition = doctype_definition_json("Widget", context.draft_domain)
          result = call_domain_builder_tool(agent, "create_doctype",
            {"definition" => definition})

          result["ok"].as_bool.should be_true
          doctype_id = result["data"]["doctype_id"].as_s

          actioner, channel, cause_kind, cause_name, cause_parent, cause_trace = db.query_one(
            "SELECT actioner_id, channel, cause_kind, cause_name, cause_parent, cause_trace " \
            "FROM mutations WHERE domain='core' AND doc_type='DocType' AND doc_id=$1",
            doctype_id,
            as: {String, String, String, String?, String?, String},
          )
          actioner.should eq(owner_id)
          channel.should eq("internal")
          cause_kind.should eq("assistant")
          cause_name.should eq("domain-builder")
          cause_parent.should be_nil
          cause_trace.should_not be_empty
        end
      end

      it "create_doctype chains the seeded default view into the same cause" do
        with_db do |db|
          owner_id = Facet::Util::ScriptHelpers.ulid
          context = make_domain_builder_context(db, owner_id)
          agent = build_domain_builder_agent(db, context)

          definition = doctype_definition_json("Widget", context.draft_domain)
          result = call_domain_builder_tool(agent, "create_doctype",
            {"definition" => definition})

          result["ok"].as_bool.should be_true
          doctype_id = result["data"]["doctype_id"].as_s

          doctype_mut_id = db.query_one(
            "SELECT id FROM mutations WHERE domain='core' AND doc_type='DocType' AND doc_id=$1",
            doctype_id,
            as: String,
          )

          seed_actioner, seed_kind, seed_name, seed_parent = db.query_one(
            "SELECT m.actioner_id, m.cause_kind, m.cause_name, m.cause_parent " \
            "FROM mutations m JOIN projections p " \
            "ON p.domain=m.domain AND p.doc_type=m.doc_type AND p.id=m.doc_id " \
            "WHERE m.domain='core' AND m.doc_type='CollectionView' AND p.meta->>'parent_id'=$1 " \
            "ORDER BY m.id DESC LIMIT 1",
            doctype_id,
            as: {String, String, String?, String?},
          )
          seed_actioner.should eq(owner_id)
          seed_kind.should eq("assistant")
          seed_name.should eq("domain-builder")
          seed_parent.should eq(doctype_mut_id)
        end
      end

      it "update_doctype stamps the owner and the assistant cause" do
        with_db do |db|
          owner_id = Facet::Util::ScriptHelpers.ulid
          context = make_domain_builder_context(db, owner_id)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          new_defn = doctype_definition_json("Widget", context.draft_domain)
          result = call_domain_builder_tool(agent, "update_doctype",
            {"doctype_id" => JSON::Any.new(doctype_id),
             "definition" => new_defn})

          result["ok"].as_bool.should be_true

          actioner, cause_kind = db.query_one(
            "SELECT actioner_id, cause_kind FROM mutations " \
            "WHERE domain='core' AND doc_type='DocType' AND doc_id=$1 " \
            "ORDER BY id DESC LIMIT 1",
            doctype_id,
            as: {String, String},
          )
          actioner.should eq(owner_id)
          cause_kind.should eq("assistant")
        end
      end

      it "delete_doctype stamps the owner and the assistant cause" do
        with_db do |db|
          owner_id = Facet::Util::ScriptHelpers.ulid
          context = make_domain_builder_context(db, owner_id)
          agent = build_domain_builder_agent(db, context)

          doctype_id = seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "delete_doctype",
            {"doctype_id" => JSON::Any.new(doctype_id)})

          result["ok"].as_bool.should be_true

          actioner, cause_kind = db.query_one(
            "SELECT actioner_id, cause_kind FROM mutations " \
            "WHERE domain='core' AND doc_type='DocType' AND doc_id=$1 " \
            "ORDER BY id DESC LIMIT 1",
            doctype_id,
            as: {String, String},
          )
          actioner.should eq(owner_id)
          cause_kind.should eq("assistant")
        end
      end

      it "create_document stamps the owner and the assistant cause" do
        with_db do |db|
          owner_id = Facet::Util::ScriptHelpers.ulid
          context = make_domain_builder_context(db, owner_id)
          agent = build_domain_builder_agent(db, context)

          seed_doctype_in_draft(db, context.draft_domain, "Widget")

          result = call_domain_builder_tool(agent, "create_document",
            {"doctype" => JSON::Any.new("Widget"),
             "content" => JSON.parse(%({"label": "Hello"}))})

          result["ok"].as_bool.should be_true
          doc_id = result["data"]["doc_id"].as_s

          actioner, cause_kind, cause_name = db.query_one(
            "SELECT actioner_id, cause_kind, cause_name FROM mutations " \
            "WHERE domain=$1 AND doc_type='Widget' AND doc_id=$2",
            context.draft_domain, doc_id,
            as: {String, String, String?},
          )
          actioner.should eq(owner_id)
          cause_kind.should eq("assistant")
          cause_name.should eq("domain-builder")
        end
      end
    end

    # ── UI tools (frontend-rendered) ─────────────────────────────────────

    describe "UI tools" do
      it "preview_view acks a document-kind payload" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "preview_view",
            {"kind"     => JSON::Any.new("document"),
             "template" => JSON.parse(%({"type": "label", "value": "$name"}))})

          result["ok"].as_bool.should be_true
          result["data"]["rendered"].as_bool.should be_true
          result["data"]["kind"].as_s.should eq("document")
        end
      end

      it "preview_view acks a collection-kind payload" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "preview_view",
            {"kind"    => JSON::Any.new("collection"),
             "surface" => JSON::Any.new("table")})

          result["ok"].as_bool.should be_true
        end
      end

      it "preview_view rejects an unknown kind / surface / missing template" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          call_domain_builder_tool(agent, "preview_view",
            {"kind" => JSON::Any.new("grid")})["ok"].as_bool.should be_false

          call_domain_builder_tool(agent, "preview_view",
            {"kind"    => JSON::Any.new("collection"),
             "surface" => JSON::Any.new("kanban")})["ok"].as_bool.should be_false

          call_domain_builder_tool(agent, "preview_view",
            {"kind" => JSON::Any.new("document")})["ok"].as_bool.should be_false
        end
      end

      it "go_to_page acks a known page and rejects an unknown one" do
        with_db do |db|
          context = make_domain_builder_context(db)
          agent = build_domain_builder_agent(db, context)

          result = call_domain_builder_tool(agent, "go_to_page",
            {"page"       => JSON::Any.new("doctype"),
             "doctype_id" => JSON::Any.new("logistics.Shipment")})
          result["ok"].as_bool.should be_true
          result["data"]["page"].as_s.should eq("doctype")

          call_domain_builder_tool(agent, "go_to_page",
            {"page" => JSON::Any.new("kanban")})["ok"].as_bool.should be_false
        end
      end
    end
  end
end
