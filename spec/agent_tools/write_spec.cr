# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# Write tool group (MCP tools plan, step 5).
#
# Acceptance:
# - `create_document` persists a document and returns {data, meta} with the
#   created content; the mutation is attributed to the acting account.
# - `create_document` surfaces schema-validation failures as `InvalidParams`
#   with per-field diagnostics (reuses the service's `ValidationError` list).
# - `update_document` patches one document; missing document → NotFound.
# - `delete_document` soft-deletes; the tombstone is reflected on a
#   subsequent `get_document`.
# - Write tools are visible only to a role holding a write grant.
describe "AgentTools::Write" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "creates a document and returns the projection" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      result = call_tool(ctx, "create_document", %({
        "domain": "#{domain}", "doctype": "#{doctype}",
        "content": {"name": "Acme"}
      }))
      data = result.as_h["data"].as_h
      data["name"].as_s.should eq("Acme")
      meta = result.as_h["meta"].as_h
      meta["id"].as_s.should_not be_empty
      meta["mid"].as_s.should_not be_empty # mutation id of the create mutation
      meta["domain"].as_s.should eq(domain)
      meta["doc_type"].as_s.should eq(doctype)
    end
  end

  it "surfaces schema-validation failures as InvalidParams with diagnostics" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      ex = expect_raises(Facet::AgentTools::InvalidParams) do
        call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {}}))
      end
      # The `details` array carries the per-field `ValidationError` records.
      ex.data.should_not be_nil
      details = ex.data.not_nil!.as_h["details"].as_a
      details.any? { |d| d.as_h["field"].as_s == "name" }.should be_true
      # The message names the field, so message-only clients learn the cause.
      (ex.message || "").should contain("name")
    end
  end

  it "names the unique-constraint violation in the InvalidParams message" do
    with_db do |db|
      ensure_domain(db, "mcpwrite")
      doctype = "U#{unique_suffix}"
      defn = %({"doctype": "#{doctype}", "domain": "mcpwrite", "aggregate_root": true, "search": "{{ display_name }}",
                "fields": {"name": {"type": "string", "required": true, "unique": true}}})
      Facet::Doctype::DefinitionStore.invalidate("mcpwrite.#{doctype}")
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
      ctx = build_context(db, "iam.Roles.editor")

      call_tool(ctx, "create_document", %({"domain": "mcpwrite", "doctype": "#{doctype}", "content": {"name": "Growth"}}))
      ex = expect_raises(Facet::AgentTools::InvalidParams, /name.*(already|exists|unique)/i) do
        call_tool(ctx, "create_document", %({"domain": "mcpwrite", "doctype": "#{doctype}", "content": {"name": "Growth"}}))
      end
      (ex.message || "").should contain("name")
    end
  end

  it "updates a document with a partial patch" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "update_document", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}",
        "patch": {"name": "Globex"}
      }))
      result.as_h["data"].as_h["name"].as_s.should eq("Globex")
      # `mid` carries the update mutation id.
      result.as_h["meta"].as_h["mid"].as_s.should_not be_empty
    end
  end

  it "raises NotFound when updating a missing document" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      expect_raises(Facet::AgentTools::NotFound, /not found/i) do
        call_tool(ctx, "update_document", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "absent",
          "patch": {"name": "x"}
        }))
      end
    end
  end

  it "soft-deletes a document (subsequent get_document is NotFound deleted)" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "delete_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      result.as_h["data"].raw.should be_nil
      result.as_h["meta"].as_h["deleted"].as_bool.should be_true
      result.as_h["meta"].as_h["mid"].as_s.should_not be_empty

      ex = expect_raises(Facet::AgentTools::NotFound, /deleted/) do
        call_tool(ctx, "get_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      end
      ex.data.not_nil!.as_h["deleted"].as_bool.should be_true
    end
  end

  it "raises NotFound when deleting an already-deleted document" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      call_tool(ctx, "delete_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      # Second delete hits Document::Delete's "already deleted" guard (410).
      expect_raises(Facet::AgentTools::NotFound, /deleted/) do
        call_tool(ctx, "delete_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      end
    end
  end

  it "attributes the mutation to the acting user" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")
      account_id = ctx.account_id

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      row = db.query_one(
        "SELECT actioner_id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
        domain, doctype, doc_id,
        as: String,
      )
      row.should eq(account_id)
    end
  end

  it "creates a child document through parent_id and returns meta.parent_id" do
    with_db do |db|
      domain, parent, child = build_parent_child_doctypes(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      parent_id = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{parent}", "content": {}})).as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "create_document", %({
        "domain": "#{domain}", "doctype": "#{child}",
        "content": {"role": "primary"}, "parent_id": "#{parent_id}"
      }))
      result.as_h["meta"].as_h["parent_id"].as_s.should eq(parent_id)
    end
  end

  it "rejects parent_id on a doctype without member_of" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      expect_raises(Facet::AgentTools::InvalidParams, /member_of/) do
        call_tool(ctx, "create_document", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "content": {"name": "Acme"}, "parent_id": "some-parent"
        }))
      end
    end
  end

  it "refuses a child doctype created without parent_id (flat-create guard)" do
    with_db do |db|
      domain, _parent, child = build_parent_child_doctypes(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      expect_raises(Facet::AgentTools::InvalidParams, /parent_id/) do
        call_tool(ctx, "create_document", %({
          "domain": "#{domain}", "doctype": "#{child}",
          "content": {"role": "primary"}
        }))
      end
    end
  end

  it "raises NotFound for an unknown parent" do
    with_db do |db|
      domain, _parent, child = build_parent_child_doctypes(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      expect_raises(Facet::AgentTools::NotFound, /parent/i) do
        call_tool(ctx, "create_document", %({
          "domain": "#{domain}", "doctype": "#{child}",
          "content": {"role": "primary"}, "parent_id": "absent-parent"
        }))
      end
    end
  end

  it "raises NotFound when parent_id names a live row of another doctype (B-276)" do
    with_db do |db|
      domain, _parent, child = build_parent_child_doctypes(db, "mcpwrite")
      _d2, other_doctype = build_simple_doctype(db, domain)
      ctx = build_context(db, "iam.Roles.editor")

      other_id = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{other_doctype}", "content": {"name": "Other"}})).as_h["meta"].as_h["id"].as_s

      expect_raises(Facet::AgentTools::NotFound) do
        call_tool(ctx, "create_document", %({
          "domain": "#{domain}", "doctype": "#{child}",
          "content": {"role": "primary"}, "parent_id": "#{other_id}"
        }))
      end
    end
  end

  it "stamps the default request cause on a direct tool write" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      kinds = db.query_all(
        "SELECT cause_kind FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3",
        domain, doctype, doc_id,
        as: String,
      )
      # The MCP path passes no cause: every mutation of the call is a root
      # `request` (the action tool keeps the action kind — not exercised here).
      kinds.should eq(["request"])
    end
  end

  it "stamps the caller's cause on the write services" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpwrite")
      ctx = build_context(db, "iam.Roles.editor")

      cause = Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Assistant)
      created = call_tool_with_cause(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}), cause)
      doc_id = created.as_h["meta"].as_h["id"].as_s

      kind, parent = db.query_one(
        "SELECT cause_kind, cause_parent FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
        domain, doctype, doc_id,
        as: {String, String?},
      )
      kind.should eq("assistant")
      parent.should be_nil # root cause: the tool write is its own parent
    end
  end

  it "hides write tools from a read-only role" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer") # read-only on *.*
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should_not contain("create_document")
      names.should_not contain("update_document")
      names.should_not contain("delete_document")
      names.should_not contain("call_action")
      # Read tools remain visible.
      names.should contain("list_documents")
    end
  end
end
