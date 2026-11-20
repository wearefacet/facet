# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# The `batch` tool — an ordered list of writes in one transaction.
#
# Acceptance:
# - Three creates land together.
# - A failing op (3 of 5) rolls the whole batch back — nothing lands.
# - Every mutation of a batch shares one `cause_trace`.
# - The op cap raises (`Capped`).
# - A malformed op fails before any transaction opens.
describe "AgentTools::Batch" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "applies three creates atomically" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch", with_promote: false)
      ctx = build_context(db, "iam.Roles.editor")

      result = call_tool(ctx, "batch", %({
        "ops": [
          {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "A"}},
          {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "B"}},
          {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "C"}}
        ]
      }))
      items = result.as_h["data"].as_a
      items.size.should eq(3)
      names = items.map(&.as_h["data"].as_h["name"].as_s).sort!
      names.should eq(["A", "B", "C"])

      # The documents are visible after the commit.
      listed = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      listed.as_h["meta"].as_h["total"].as_i64.should eq(3)
    end
  end

  it "rolls the whole batch back when a later op fails" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch", with_promote: false)
      ctx = build_context(db, "iam.Roles.editor")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /op 2/) do
        call_tool(ctx, "batch", %({
          "ops": [
            {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "A"}},
            {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "B"}},
            {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {}}
          ]
        }))
      end
      # The structured validation details of the failing op ride along.
      ex.data.not_nil!.as_h["reason"].as_s.should eq("batch_op_failed")
      ex.data.not_nil!.as_h["op_index"].as_i64.should eq(2)

      # Nothing landed — not even op 0 and op 1.
      listed = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      listed.as_h["meta"].as_h["total"].as_i64.should eq(0)
    end
  end

  it "shares one cause_trace across every mutation of the batch" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch")
      ctx = build_context(db, "iam.Roles.admin")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Seed"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      # A second document so the batch can update one and action the other
      # (two updates on one doc inside the coalesce window would fold into
      # one mutation row — the documented coalescing contract).
      created2 = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Seed2"}}))
      doc_id2 = created2.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "batch", %({
        "ops": [
          {"op": "update", "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "patch": {"name": "One"}},
          {"op": "action", "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "action": "promote", "args": {"new_title": "Two"}},
          {"op": "update", "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id2}", "patch": {"name": "Three"}}
        ]
      }))
      trace = result.as_h["meta"].as_h["trace"].as_s
      trace.should_not be_empty

      mutations = call_tool(ctx, "list_mutations", %({
        "domain": "#{domain}", "doctype": "#{doctype}",
        "filters": {"trace": "#{trace}"}
      }))
      items = mutations.as_h["data"].as_a
      # The two direct writes (updates) share the batch trace. The action
      # op keeps the action's own cause — the same rule as the standalone
      # call_action (the action name is the more precise provenance).
      items.size.should eq(2)
      items.all?(&.as_h["cause_trace"].as_s.==(trace)).should be_true
    end
  end

  it "raises Capped over the op cap" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch", with_promote: false)
      ctx = build_context(db, "iam.Roles.editor")
      cap = Facet::Config.instance.mcp.max_batch_ops
      ops = (cap + 1).times.map { |i| %({"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "D#{i}"}}) }.join(",")

      ex = expect_raises(Facet::AgentTools::Capped) do
        call_tool(ctx, "batch", %({"ops": [#{ops}]}))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("capped")
    end
  end

  it "rejects a malformed op before any write lands" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch", with_promote: false)
      ctx = build_context(db, "iam.Roles.editor")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /unknown kind/) do
        call_tool(ctx, "batch", %({
          "ops": [
            {"op": "upsert", "domain": "#{domain}", "doctype": "#{doctype}"}
          ]
        }))
      end
      ex.data.not_nil!.as_h["op_index"].as_i64.should eq(0)

      # No document was created.
      listed = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      listed.as_h["meta"].as_h["total"].as_i64.should eq(0)
    end
  end

  it "applies a mixed create-and-update sequence in order" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpbatch", with_promote: false)
      ctx = build_context(db, "iam.Roles.editor")
      seed = create_doc_via_service(db, domain, doctype, %({"name": "Seed"}))

      result = call_tool(ctx, "batch", %({
        "ops": [
          {"op": "update", "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{seed}", "patch": {"name": "Renamed"}},
          {"op": "create", "domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "New"}},
          {"op": "delete", "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{seed}"}
        ]
      }))
      items = result.as_h["data"].as_a
      items.size.should eq(3)
      items[0].as_h["op"].as_s.should eq("update")
      items[1].as_h["op"].as_s.should eq("create")
      items[2].as_h["op"].as_s.should eq("delete")

      # The created document survives; the updated one is tombstoned.
      listed = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      listed.as_h["meta"].as_h["total"].as_i64.should eq(1)
      listed.as_h["data"].as_a.first.as_h["data"].as_h["name"].as_s.should eq("New")
    end
  end
end
