# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# Read tool group (MCP tools plan, step 4).
#
# Acceptance:
# - `list_documents` returns the filtered page; FilterSet grammar (the
#   `field__op` form) is accepted.
# - `list_documents` rejects an unknown filter field with `InvalidParams`
#   (the service silently drops unknown fields; the tool surfaces them).
# - `list_documents` clamps `items` to `mcp.max_result_rows`.
# - `get_document` returns the document content and meta; a missing doc
#   surfaces as `NotFound` with a non-disclosing message.
# - `aggregate_documents` returns the count (empty items) or a scalar /
#   money-bag aggregate over the same filter grammar; unknown aggregates
#   and non-numeric fields surface as `InvalidParams`, a view-hidden
#   field as `RbacDenied`, and rows outside the caller's RBAC scope do
#   not contribute.
# - All three are visible only to a role with a read grant.
describe "AgentTools::Read" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "lists documents of a doctype" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
      create_doc_via_service(db, domain, doctype, %({"name": "Globex"}))
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      items = result.as_h["data"].as_a
      items.size.should eq(2)
      names = items.map(&.as_h["data"].as_h["name"].as_s).sort!
      names.should eq(["Acme", "Globex"])
      meta = result.as_h["meta"].as_h
      meta["total"].as_i64.should eq(2)
      meta["truncated"].as_bool.should be_false
    end
  end

  it "carries the computed label in every row's meta.display_name" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread", display_name: "{{ name }}")
      doc_id = create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      row = result.as_h["data"].as_a.first
      row.as_h["meta"].as_h["display_name"].as_s.should eq("Acme")

      result = call_tool(ctx, "get_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      result.as_h["meta"].as_h["display_name"].as_s.should eq("Acme")
    end
  end

  it "reports meta.display_name as null when the doctype declares no template" do
    with_db do |db|
      # Searchable by name, but with no display_name template — the label
      # column stays null on list rows and on search stub rows.
      domain, doctype = build_simple_doctype(db, "mcpread", search: "{{ name }}")
      create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({"domain": "#{domain}", "doctype": "#{doctype}"}))
      row = result.as_h["data"].as_a.first
      row.as_h["meta"].as_h["display_name"].raw.should be_nil

      # The key is present (not omitted), so an agent can tell the label
      # field exists — same shape as the REST document meta.
      row.as_h["meta"].as_h.has_key?("display_name").should be_true

      # Search stub rows carry the same shape.
      result = call_tool(ctx, "search_documents", %({"query": "Acme"}))
      stub = result.as_h["data"].as_a.first
      stub.as_h["display_name"].raw.should be_nil
    end
  end

  it "marks truncated and emits the next cursor when the page cuts the result" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      5.times do |i|
        create_doc_via_service(db, domain, doctype, %({"name": "doc-#{i}"}))
      end
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "items": 3, "page": 1
      }))
      meta = result.as_h["meta"].as_h
      meta["items"].as_i64.should eq(3)
      meta["truncated"].as_bool.should be_true
      meta["next_cursor"].as_i64.should eq(2)
      # `total` excludes the has-more probe row: while truncated it is the
      # rows the page returned; the final page reports the exact count.
      meta["total"].as_i64.should eq(3)

      # The cursor fetches the remaining page, which reports no more.
      result = call_tool(ctx, "list_documents", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "items": 3, "page": 2
      }))
      meta = result.as_h["meta"].as_h
      meta["items"].as_i64.should eq(2)
      meta["truncated"].as_bool.should be_false
      meta["next_cursor"].raw.should be_nil
    end
  end

  it "applies the field__op filter grammar" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
      create_doc_via_service(db, domain, doctype, %({"name": "Globex"}))
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({
        "domain": "#{domain}", "doctype": "#{doctype}",
        "filters": {"name__eq": "Globex"}
      }))
      names = result.as_h["data"].as_a.map(&.as_h["data"].as_h["name"].as_s)
      names.should eq(["Globex"])
    end
  end

  it "rejects an unknown filter field with InvalidParams naming it" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      ctx = build_context(db, "iam.Roles.viewer")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /'nonexistent'/) do
        call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "filters": {"nonexistent": 1}
        }))
      end
      ex.message.not_nil!.should contain("#{domain}.#{doctype}")
    end
  end

  # ── filter-operator validation (loud failure at the tool layer) ────
  #
  # The service compiles an unknown operator to `FALSE` and drops a wrong
  # operator on a range field — both silent. The tool rejects them before
  # any SQL runs, using the same routing the compiler itself follows.
  describe "filter operator validation" do
    it "serves id__in (Step 15 regression)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        a = create_doc_via_service(db, domain, doctype, %({"name": "A"}))
        b = create_doc_via_service(db, domain, doctype, %({"name": "B"}))
        create_doc_via_service(db, domain, doctype, %({"name": "C"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "filters": {"id__in": ["#{a}", "#{b}"]}
        }))
        names = result.as_h["data"].as_a.map(&.as_h["data"].as_h["name"].as_s).sort!
        names.should eq(["A", "B"])
      end
    end

    it "serves field__in on a text field" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        create_doc_via_service(db, domain, doctype, %({"name": "A"}))
        create_doc_via_service(db, domain, doctype, %({"name": "B"}))
        create_doc_via_service(db, domain, doctype, %({"name": "C"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "filters": {"name__in": ["A", "C"]}
        }))
        names = result.as_h["data"].as_a.map(&.as_h["data"].as_h["name"].as_s).sort!
        names.should eq(["A", "C"])
      end
    end

    it "serves field__in on an integer field (typed route)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        create_doc_via_service(db, domain, doctype, %({"name": "A", "qty": 10}))
        create_doc_via_service(db, domain, doctype, %({"name": "B", "qty": 20}))
        create_doc_via_service(db, domain, doctype, %({"name": "C", "qty": 30}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "filters": {"qty__in": [10, 30]}
        }))
        names = result.as_h["data"].as_a.map(&.as_h["data"].as_h["name"].as_s).sort!
        names.should eq(["A", "C"])
      end
    end

    it "rejects an over-cap __in array" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")
        over = Array.new(Facet::Util::FilterSet::MAX_IN_VALUES + 1) { |i| "v#{i}" }

        ex = expect_raises(Facet::AgentTools::InvalidParams, /at most 100/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"name__in": #{over.to_json}}
          }))
        end
        ex.data.not_nil!.as_h["reason"].as_s.should eq("invalid_params")
      end
    end

    it "rejects __in on a money field (fail loud, not half-right)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /price/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"price__in": ["USD 10"]}
          }))
        end
        ex.data.not_nil!.as_h["operator"].as_s.should eq("in")
      end
    end

    it "rejects a wrong operator on a period field (silent drop today)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /window/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"window__gt": "2026-01-01"}
          }))
        end
        ex.data.not_nil!.as_h["operator"].as_s.should eq("gt")
      end
    end

    it "rejects a suffixed search key (bare key only)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /no operator suffix/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"search__eq": "Acme"}
          }))
        end
      end
    end

    it "rejects a pattern operator on a money field" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /price/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"price__match": "10"}
          }))
        end
        ex.data.not_nil!.as_h["operator"].as_s.should eq("match")
      end
    end

    it "rejects a range operator on a reference field" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /owner/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "filters": {"owner__gte": "iam.Account.abc"}
          }))
        end
        ex.data.not_nil!.as_h["operator"].as_s.should eq("gte")
      end
    end

    it "still serves the valid forms (regression)" do
      with_db do |db|
        domain, doctype = build_operator_doctype(db, "mcpread")
        account_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        create_doc_via_service(db, domain, doctype, %({"name": "Acme", "qty": 10, "tags": ["a"], "owner": "iam.Account.#{account_id}"}))
        create_doc_via_service(db, domain, doctype, %({"name": "Globex", "qty": 20, "tags": ["b"]}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "filters": {"name__match": "Glob", "qty__gte": 15, "tags__contains": "b", "owner__ne": "iam.Account.#{account_id}", "search": "Globex", "id__gte": "0"}
        }))
        names = result.as_h["data"].as_a.map(&.as_h["data"].as_h["name"].as_s)
        names.should eq(["Globex"])
      end
    end
  end

  it "clamps items to mcp.max_result_rows" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      cap = Facet::Config.instance.mcp.max_result_rows
      (cap + 5).times do |i|
        create_doc_via_service(db, domain, doctype, %({"name": "Deal #{i}"}))
      end
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "list_documents", %({
        "domain": "#{domain}", "doctype": "#{doctype}",
        "items": #{cap + 1000}
      }))
      result.as_h["data"].as_a.size.should eq(cap)
    end
  end

  it "gets one document by id with meta" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      created = Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme"}), Facet::RBAC::AuthContext.system)
      case created
      in Facet::Document::Create::Result
        doc_id = created.projection.id
      in Facet::ServiceError
        raise "setup create failed: #{created.message}"
      end
      ctx = build_context(db, "iam.Roles.viewer")

      result = call_tool(ctx, "get_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      data = result.as_h["data"].as_h
      data["name"].as_s.should eq("Acme")
      meta = result.as_h["meta"].as_h
      meta["id"].as_s.should eq(doc_id)
      meta["domain"].as_s.should eq(domain)
      meta["doc_type"].as_s.should eq(doctype)
      meta["mid"].as_s.should_not be_empty
      # A root document carries no parent link.
      meta.has_key?("parent_id").should be_false
    end
  end

  it "raises NotFound for a missing document (non-disclosing)" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      ex = expect_raises(Facet::AgentTools::NotFound, /not found/) do
        call_tool(ctx, "get_document", %({"domain": "mcpread", "doctype": "Ghost", "doc_id": "absent-id"}))
      end
      ex.data.should_not be_nil
      ex.data.not_nil!.as_h["reason"].as_s.should eq("not_found")
    end
  end

  it "raises NotFound with a 'deleted' note for a tombstoned document" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpread")
      doc_id = create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
      Facet::Mutation::Client.delete(db, domain, doctype, doc_id, actioner_id: "system")
      ctx = build_context(db, "iam.Roles.viewer")

      ex = expect_raises(Facet::AgentTools::NotFound, /deleted/) do
        call_tool(ctx, "get_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      end
      ex.data.not_nil!.as_h["deleted"].as_bool.should be_true
    end
  end

  it "hides the read tools from a system principal" do
    # `list_for` returns no tools for a system principal (D6 — fail closed,
    # covered in tools_spec.cr too); the read tools follow the same rule.
    ctx = Facet::RBAC::AuthContext.system
    Facet::AgentTools.list_for(ctx).each do |tool|
      ["list_documents", "get_document", "aggregate_documents"].should_not contain(tool.name)
    end
  end

  it "shows the read tools to a role holding a read grant" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should contain("list_documents")
      names.should contain("get_document")
      names.should contain("aggregate_documents")
    end
  end

  # ── parent-scoped reads (children of one document) ──────────────────

  describe "parent_id" do
    it "lists the children of one parent" do
      with_db do |db|
        domain, parent, child = build_parent_child_doctypes(db, "mcpread")
        parent_a = create_doc_via_service(db, domain, parent, %({}))
        parent_b = create_doc_via_service(db, domain, parent, %({}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "primary"}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "secondary"}))
        create_child_doc_via_service(db, domain, child, parent_b, %({"role": "primary"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{child}", "parent_id": "#{parent_a}"
        }))
        items = result.as_h["data"].as_a
        items.size.should eq(2)
        result.as_h["meta"].as_h["total"].as_i64.should eq(2)
        items.each do |item|
          item.as_h["meta"].as_h["parent_id"].as_s.should eq(parent_a)
        end
      end
    end

    it "combines filters with parent_id" do
      with_db do |db|
        domain, parent, child = build_parent_child_doctypes(db, "mcpread")
        parent_a = create_doc_via_service(db, domain, parent, %({}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "primary"}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "secondary"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{child}",
          "parent_id": "#{parent_a}", "filters": {"role__eq": "primary"}
        }))
        items = result.as_h["data"].as_a
        items.size.should eq(1)
        items.first.as_h["data"].as_h["role"].as_s.should eq("primary")
      end
    end

    it "counts the children of one parent through aggregate_documents" do
      with_db do |db|
        domain, parent, child = build_parent_child_doctypes(db, "mcpread")
        parent_a = create_doc_via_service(db, domain, parent, %({}))
        parent_b = create_doc_via_service(db, domain, parent, %({}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "primary"}))
        create_child_doc_via_service(db, domain, child, parent_a, %({"role": "secondary"}))
        create_child_doc_via_service(db, domain, child, parent_b, %({"role": "primary"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{child}",
          "aggregate": "count", "parent_id": "#{parent_b}"
        }))
        result.as_h["data"].as_a.should be_empty
        result.as_h["meta"].as_h["total"].as_i64.should eq(1)
      end
    end

    it "rejects parent_id on a doctype without member_of" do
      with_db do |db|
        domain, doctype = build_simple_doctype(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /member_of/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}", "parent_id": "some-id"
          }))
        end
      end
    end

    it "raises NotFound for a missing parent (non-disclosing)" do
      with_db do |db|
        domain, _parent, child = build_parent_child_doctypes(db, "mcpread")
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::NotFound, /not available/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{child}", "parent_id": "unknown-parent"
          }))
        end
        ex.message.not_nil!.downcase.should_not contain("permission")
      end
    end

    it "raises NotFound when the parent is outside the caller's scope" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, parent, child = build_parent_child_doctypes(db, "mcpread", parent_fields: fields, parent_scopes: scopes)

        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "mcpread-parent-other@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        hidden_parent = create_doc_via_service(db, domain, parent, %({"name": "secret", "owner_id": "iam.Account.#{other_id}"}))
        create_child_doc_via_service(db, domain, child, hidden_parent, %({"role": "primary"}))

        # A Real principal whose read grant on the parent carries the
        # `mine` scope — the hidden parent is not readable, so its
        # children are not listable either (same rule as the nested
        # REST route, non-disclosing).
        role = Facet::RBAC::ActiveRole.new(
          role_id: "iam.Roles.parent_scope",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [parent], scope: "$mine")],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(caller_id, role)

        ex = expect_raises(Facet::AgentTools::NotFound, /not available/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{child}", "parent_id": "#{hidden_parent}"
          }))
        end
        ex.message.not_nil!.downcase.should_not contain("permission")
      end
    end

    it "reports the parent in get_document meta for a child document" do
      with_db do |db|
        domain, parent, child = build_parent_child_doctypes(db, "mcpread")
        parent_id = create_doc_via_service(db, domain, parent, %({}))
        child_id = create_child_doc_via_service(db, domain, child, parent_id, %({"role": "primary"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "get_document", %({"domain": "#{domain}", "doctype": "#{child}", "doc_id": "#{child_id}"}))
        result.as_h["meta"].as_h["parent_id"].as_s.should eq(parent_id)
      end
    end
  end

  # ── expand / resolved map (Step 7) ────────────────────────────────

  describe "expand argument" do
    it "resolves expanded reference targets into the resolved map (list)" do
      with_db do |db|
        domain, gadget_dt, widget_dt = build_expand_fixture(db)
        gadget = Facet::Document::Create.call(db, domain, gadget_dt, %({"name": "G1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        Facet::Document::Create.call(db, domain, widget_dt, %({"name": "W1", "gadget": "#{gadget.id}", "title": "t"}), Facet::RBAC::AuthContext.system)
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{widget_dt}", "expand": ["gadget"]
        }))
        # Rows keep their (qualified) stored reference value; the resolved
        # map rides next to data, keyed by URN.
        row = result.as_h["data"].as_a.first.as_h
        row["data"].as_h["gadget"].as_s.should eq("#{domain}.#{gadget_dt}.#{gadget.id}")
        resolved = result.as_h["resolved"].as_h
        resolved.size.should eq(1)
        entry = resolved["urn:facet:#{domain}:#{gadget_dt}:#{gadget.id}"].as_h
        entry["id"].as_s.should eq(gadget.id)
        entry["domain"].as_s.should eq(domain)
        entry["doc_type"].as_s.should eq(gadget_dt)
        entry["data"].as_h["name"].as_s.should eq("G1")
      end
    end

    it "resolves expanded reference targets on get_document" do
      with_db do |db|
        domain, gadget_dt, widget_dt = build_expand_fixture(db)
        gadget = Facet::Document::Create.call(db, domain, gadget_dt, %({"name": "G1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        widget = Facet::Document::Create.call(db, domain, widget_dt, %({"name": "W1", "gadget": "#{gadget.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "get_document", %({
          "domain": "#{domain}", "doctype": "#{widget_dt}", "doc_id": "#{widget.id}", "expand": ["gadget"]
        }))
        resolved = result.as_h["resolved"].as_h
        resolved["urn:facet:#{domain}:#{gadget_dt}:#{gadget.id}"].as_h["data"].as_h["name"].as_s.should eq("G1")
      end
    end

    it "rejects expand on a non-reference field" do
      with_db do |db|
        domain, _gadget_dt, widget_dt = build_expand_fixture(db)
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /'title'/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{widget_dt}", "expand": ["title"]
          }))
        end
        ex.data.not_nil!.as_h["argument"].as_s.should eq("expand")
      end
    end

    it "rejects an unknown expand name" do
      with_db do |db|
        domain, _gadget_dt, widget_dt = build_expand_fixture(db)
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /'ghost'/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{widget_dt}", "expand": ["ghost"]
          }))
        end
      end
    end

    it "omits a denied target from the resolved map" do
      with_db do |db|
        domain, _gadget_dt, _widget_dt = build_expand_fixture(db)
        other = create_test_account(db, email: "expand-denied@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")

        # Gadget list scoped to the caller via a $mine scope on `owner`.
        fields = %({"name": {"type": "string", "required": true}, "owner": {"type": "reference", "doctype": "iam.Account"}})
        scopes = %({"mine": {"where": {"owner": "$self"}}})
        _d, scoped_dt = build_agg_doctype(db, domain, fields, scopes)
        mine = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        denied_gadget = Facet::Document::Create.call(db, domain, scoped_dt, %({"name": "hidden", "owner": "iam.Account.#{other}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        # A reference field on Widget pointing at the scoped doctype.
        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "RefWidget", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
          "fields": {
            "name":  {"type": "string", "required": true},
            "thing": {"type": "reference", "doctype": "#{domain}.#{scoped_dt}"}
          }
        }), Facet::RBAC::AuthContext.system)
        widget = Facet::Document::Create.call(db, domain, "RefWidget", %({"name": "W", "thing": "#{denied_gadget.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpexp.reader",
          visible_tags: Set.new(["default"]),
          permissions: [
            Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["RefWidget"]),
            Facet::RBAC::Permission.new(action: "read", domain: domain, path: [scoped_dt], scope: "$mine"),
          ],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(mine, role)

        result = call_tool(ctx, "get_document", %({
          "domain": "#{domain}", "doctype": "RefWidget", "doc_id": "#{widget.id}", "expand": ["thing"]
        }))
        # The denied target is absent — non-disclosing.
        result.as_h["resolved"].as_h.should be_empty
      end
    end

    it "masks a view-tagged field out of the resolved content" do
      with_db do |db|
        domain, _gadget_dt, _widget_dt = build_expand_fixture(db)
        # Gadget gains a payroll-tagged field.
        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "Secret", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
          "fields": {
            "name":   {"type": "string", "required": true},
            "salary": {"type": "integer", "tags": ["payroll"]}
          }
        }), Facet::RBAC::AuthContext.system)
        secret = Facet::Document::Create.call(db, domain, "Secret", %({"name": "S", "salary": 99}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "HoldWidget", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
          "fields": {
            "name":  {"type": "string", "required": true},
            "held":  {"type": "reference", "doctype": "#{domain}.Secret"}
          }
        }), Facet::RBAC::AuthContext.system)
        widget = Facet::Document::Create.call(db, domain, "HoldWidget", %({"name": "W", "held": "#{secret.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpexp.basic",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["HoldWidget"]), Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["Secret"])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

        result = call_tool(ctx, "get_document", %({
          "domain": "#{domain}", "doctype": "HoldWidget", "doc_id": "#{widget.id}", "expand": ["held"]
        }))
        entry = result.as_h["resolved"].as_h["urn:facet:#{domain}:Secret:#{secret.id}"].as_h
        entry["data"].as_h["name"].as_s.should eq("S")
        entry["data"].as_h.has_key?("salary").should be_false
      end
    end
  end

  # ── fields projection (Step 9) ─────────────────────────────────

  describe "fields argument" do
    it "projects each row's content to the named fields" do
      with_db do |db|
        domain, _gadget_dt, widget_dt = build_expand_fixture(db)
        Facet::Document::Create.call(db, domain, widget_dt, %({"name": "W1", "title": "t"}), Facet::RBAC::AuthContext.system)
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{widget_dt}", "fields": ["name"]
        }))
        content = result.as_h["data"].as_a.first.as_h["data"].as_h
        content["name"].as_s.should eq("W1")
        content.has_key?("title").should be_false
      end
    end

    it "projects get_document content and leaves meta untouched" do
      with_db do |db|
        domain, _gadget_dt, widget_dt = build_expand_fixture(db)
        w1 = Facet::Document::Create.call(db, domain, widget_dt, %({"name": "W1", "title": "t"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "get_document", %({
          "domain": "#{domain}", "doctype": "#{widget_dt}", "doc_id": "#{w1.id}", "fields": ["name"]
        }))
        result.as_h["data"].as_h["name"].as_s.should eq("W1")
        result.as_h["data"].as_h.has_key?("title").should be_false
        # System meta is untouched.
        result.as_h["meta"].as_h["id"].as_s.should eq(w1.id)
      end
    end

    it "rejects an unknown field name" do
      with_db do |db|
        domain, gadget_dt, _widget_dt = build_expand_fixture(db)
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /'ghost'/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{gadget_dt}", "fields": ["ghost"]
          }))
        end
        ex.data.not_nil!.as_h["argument"].as_s.should eq("fields")
      end
    end

    it "keeps a masked field absent even when named" do
      with_db do |db|
        domain = "mcpexp"
        ensure_domain(db, domain)
        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "Payroll", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
          "fields": {
            "name":   {"type": "string", "required": true},
            "salary": {"type": "integer", "tags": ["payroll"]}
          }
        }), Facet::RBAC::AuthContext.system)
        doc = Facet::Document::Create.call(db, domain, "Payroll", %({"name": "P", "salary": 10}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpexp.reader",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["Payroll"])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

        result = call_tool(ctx, "get_document", %({
          "domain": "#{domain}", "doctype": "Payroll", "doc_id": "#{doc.id}", "fields": ["name", "salary"]
        }))
        data = result.as_h["data"].as_h
        data["name"].as_s.should eq("P")
        # The read mask runs first — the result never names a field the
        # role cannot see, even when the caller asks for it.
        data.has_key?("salary").should be_false
      end
    end
  end

  # ── scope argument (Step 10) ────────────────────────────────

  describe "scope argument" do
    it "narrows the result to the named scope without the agent knowing any id" do
      with_db do |db|
        domain, doctype = build_scope_fixture(db)
        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "scope-other@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        create_doc_via_service(db, domain, doctype, %({"title": "mine", "owner": "iam.Account.#{caller_id}"}))
        create_doc_via_service(db, domain, doctype, %({"title": "theirs", "owner": "iam.Account.#{other_id}"}))

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpscope.reader",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(caller_id, role)

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "scope": "mine"
        }))
        titles = result.as_h["data"].as_a.map(&.as_h["data"].as_h["title"].as_s)
        titles.should eq(["mine"])
      end
    end

    it "raises InvalidParams for an unknown scope" do
      with_db do |db|
        domain, doctype = build_scope_fixture(db)
        ctx = build_context(db, "iam.Roles.viewer")

        ex = expect_raises(Facet::AgentTools::InvalidParams, /'ghost'/) do
          call_tool(ctx, "list_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}", "scope": "ghost"
          }))
        end
        ex.data.not_nil!.as_h["argument"].as_s.should eq("scope")
      end
    end

    it "combines a scoped RBAC grant with the scope argument" do
      with_db do |db|
        domain, doctype = build_scope_fixture(db)
        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "scope-combo@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        # Two rows owned by the caller; one also matches an extra filter.
        create_doc_via_service(db, domain, doctype, %({"title": "alpha", "owner": "iam.Account.#{caller_id}"}))
        create_doc_via_service(db, domain, doctype, %({"title": "beta", "owner": "iam.Account.#{caller_id}"}))
        create_doc_via_service(db, domain, doctype, %({"title": "theirs", "owner": "iam.Account.#{other_id}"}))

        # The role itself is scoped ($mine) — visible rows are already only
        # the caller's; the query-time scope ANDs the same predicate again
        # (no widening, no error).
        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpscope.mine",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype], scope: "$mine")],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(caller_id, role)

        result = call_tool(ctx, "list_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "scope": "mine",
          "filters": {"title__eq": "alpha"}
        }))
        titles = result.as_h["data"].as_a.map(&.as_h["data"].as_h["title"].as_s)
        titles.should eq(["alpha"])
      end
    end

    it "applies on aggregate_documents" do
      with_db do |db|
        domain, doctype = build_scope_fixture(db)
        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "scope-agg@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        create_doc_via_service(db, domain, doctype, %({"title": "mine", "owner": "iam.Account.#{caller_id}"}))
        create_doc_via_service(db, domain, doctype, %({"title": "theirs", "owner": "iam.Account.#{other_id}"}))

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpscope.agg",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(caller_id, role)

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "aggregate": "count", "scope": "mine"
        }))
        result.as_h["meta"].as_h["total"].as_i64.should eq(1)
      end
    end
  end

  # ── resolve_refs (Step 8) ─────────────────────────────────────────

  describe "resolve_refs" do
    it "resolves a batch of URNs in one call" do
      with_db do |db|
        domain, gadget_dt, widget_dt = build_expand_fixture(db)
        g1 = Facet::Document::Create.call(db, domain, gadget_dt, %({"name": "G1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        w1 = Facet::Document::Create.call(db, domain, widget_dt, %({"name": "W1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "resolve_refs", %({
          "refs": [
            "urn:facet:#{domain}:#{gadget_dt}:#{g1.id}",
            "urn:facet:#{domain}:#{widget_dt}:#{w1.id}",
            "urn:facet:#{domain}:#{gadget_dt}:01UNKNOWN000000000000000000"
          ]
        }))
        items = result.as_h["data"].as_a
        items.size.should eq(2)
        result.as_h["meta"].as_h["total"].as_i64.should eq(2)
        names = items.map(&.as_h["data"].as_h["name"].as_s).sort!
        names.should eq(["G1", "W1"])
      end
    end

    it "projects resolved content to the named fields" do
      with_db do |db|
        domain, gadget_dt, _widget_dt = build_expand_fixture(db)
        g1 = Facet::Document::Create.call(db, domain, gadget_dt, %({"name": "G1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "resolve_refs", %({
          "refs": ["urn:facet:#{domain}:#{gadget_dt}:#{g1.id}"], "fields": ["name"]
        }))
        content = result.as_h["data"].as_a.first.as_h["data"].as_h
        content["name"].as_s.should eq("G1")
        content.size.should eq(1)
      end
    end

    it "rejects an unknown field projection name" do
      with_db do |db|
        domain, gadget_dt, _widget_dt = build_expand_fixture(db)
        g1 = Facet::Document::Create.call(db, domain, gadget_dt, %({"name": "G1"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /'ghost'/) do
          call_tool(ctx, "resolve_refs", %({
            "refs": ["urn:facet:#{domain}:#{gadget_dt}:#{g1.id}"], "fields": ["ghost"]
          }))
        end
      end
    end

    it "caps the refs list" do
      with_db do |db|
        cap = Facet::Config.instance.mcp.max_result_rows
        ctx = build_context(db, "iam.Roles.viewer")
        refs = Array.new(cap + 1) { |i| "urn:facet:x:Y:#{i}" }

        ex = expect_raises(Facet::AgentTools::Capped) do
          call_tool(ctx, "resolve_refs", %({"refs": #{refs.to_json}}))
        end
        ex.data.not_nil!.as_h["reason"].as_s.should eq("capped")
      end
    end

    it "omits a denied target (non-disclosing)" do
      with_db do |db|
        domain, _gadget_dt, _widget_dt = build_expand_fixture(db)
        fields = %({"name": {"type": "string", "required": true}, "owner": {"type": "reference", "doctype": "iam.Account"}})
        scopes = %({"mine": {"where": {"owner": "$self"}}})
        _d, scoped_dt = build_agg_doctype(db, domain, fields, scopes)
        mine = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other = create_test_account(db, email: "resolve-denied@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        visible = Facet::Document::Create.call(db, domain, scoped_dt, %({"name": "mine", "owner": "iam.Account.#{mine}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        hidden = Facet::Document::Create.call(db, domain, scoped_dt, %({"name": "hidden", "owner": "iam.Account.#{other}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpexp.resolver",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [scoped_dt], scope: "$mine")],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(mine, role)

        result = call_tool(ctx, "resolve_refs", %({
          "refs": [
            "urn:facet:#{domain}:#{scoped_dt}:#{visible.id}",
            "urn:facet:#{domain}:#{scoped_dt}:#{hidden.id}"
          ]
        }))
        items = result.as_h["data"].as_a
        items.size.should eq(1)
        items.first.as_h["data"].as_h["name"].as_s.should eq("mine")
      end
    end
  end

  # ── search_documents (Step 14) ───────────────────────────

  describe "search_documents" do
    it "finds matches across doctypes in one call" do
      with_db do |db|
        # Two doctypes in the app domain sharing a searchable term, plus a
        # third that does not match.
        domain = "mcpsearch"
        ensure_domain(db, domain)
        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "Contact", "domain": "#{domain}", "aggregate_root": true,
          "search": "{{ name }}",
          "fields": {"name": {"type": "string", "required": true}}
        }), Facet::RBAC::AuthContext.system)
        Facet::Document::Create.call(db, "core", "DocType", %({
          "doctype": "Deal", "domain": "#{domain}", "aggregate_root": true,
          "search": "{{ name }}",
          "fields": {"name": {"type": "string", "required": true}}
        }), Facet::RBAC::AuthContext.system)
        create_doc_via_service(db, domain, "Contact", %({"name": "Zephyr Corp"}))
        create_doc_via_service(db, domain, "Deal", %({"name": "Zephyr renewal"}))
        create_doc_via_service(db, domain, "Deal", %({"name": "Unrelated"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "search_documents", %({"query": "Zephyr"}))
        items = result.as_h["data"].as_a
        items.size.should eq(2)
        doctypes = items.map(&.as_h["doc_type"].as_s).sort!
        doctypes.should eq(["Contact", "Deal"])
        items.all?(&.as_h["id"].as_s.size.>(0)).should be_true
      end
    end

    it "narrows to one domain when given" do
      with_db do |db|
        domain, gadget_dt, _widget_dt = build_expand_fixture(db)
        create_doc_via_service(db, domain, gadget_dt, %({"name": "FindMe"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "search_documents", %({"query": "FindMe", "domain": "#{domain}"}))
        result.as_h["data"].as_a.size.should eq(1)
        result.as_h["data"].as_a.first.as_h["domain"].as_s.should eq(domain)
      end
    end

    it "contributes nothing from an unreadable doctype" do
      with_db do |db|
        domain, gadget_dt, widget_dt = build_expand_fixture(db)
        create_doc_via_service(db, domain, gadget_dt, %({"name": "HiddenTarget"}))
        create_doc_via_service(db, domain, widget_dt, %({"name": "ShownTarget"}))

        # Reader may read Widget only — the Gadget match never surfaces.
        role = Facet::RBAC::ActiveRole.new(
          role_id: "mcpsearch.reader",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["Widget"])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

        result = call_tool(ctx, "search_documents", %({"query": "Target"}))
        items = result.as_h["data"].as_a
        items.size.should eq(1)
        items.first.as_h["doc_type"].as_s.should eq("Widget")
      end
    end

    it "contributes nothing from a doctype with no search template" do
      with_db do |db|
        # The search template is the opt-in: a doctype without one stores a
        # NULL search column and never matches, even when a row holds the
        # term in a plain string field.
        domain, doctype = build_agg_doctype(db, "mcpsearch", %({"name": {"type": "string", "required": true}}))
        create_doc_via_service(db, domain, doctype, %({"name": "FindMe"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "search_documents", %({"query": "FindMe"}))
        result.as_h["data"].as_a.size.should eq(0)
      end
    end
  end

  # ── aggregate_documents ───────────────────────────────────────────────────

  describe "aggregate_documents" do
    it "returns the count with empty items" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"name": {"type": "string"}, "qty": {"type": "integer"}}))
        create_doc_via_service(db, domain, doctype, %({"name": "a", "qty": 10}))
        create_doc_via_service(db, domain, doctype, %({"name": "b", "qty": 20}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "aggregate": "count"
        }))
        result.as_h["data"].as_a.should be_empty
        meta = result.as_h["meta"].as_h
        meta["total"].as_i64.should eq(2)
      end
    end

    it "applies the list_documents filter grammar" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"name": {"type": "string", "filters": ["equality"]}}))
        create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
        create_doc_via_service(db, domain, doctype, %({"name": "Globex"}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "aggregate": "count", "filters": {"name__eq": "Globex"}
        }))
        result.as_h["data"].as_a.should be_empty
        result.as_h["meta"].as_h["total"].as_i64.should eq(1)
      end
    end

    it "returns scalars for sum/avg/min/max over an integer field" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"name": {"type": "string"}, "qty": {"type": "integer"}}))
        create_doc_via_service(db, domain, doctype, %({"name": "a", "qty": 10}))
        create_doc_via_service(db, domain, doctype, %({"name": "b", "qty": 20}))
        create_doc_via_service(db, domain, doctype, %({"name": "c", "qty": 30}))
        ctx = build_context(db, "iam.Roles.viewer")

        {"sum" => 60, "avg" => 20, "min" => 10, "max" => 30}.each do |aggregate, expected|
          result = call_tool(ctx, "aggregate_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "aggregate": "#{aggregate}", "field": "qty"
          }))
          data = result.as_h["data"].as_h
          data["aggregate"].as_s.should eq(aggregate)
          data["field"].as_s.should eq("qty")
          data["value"].as_i64.should eq(expected)
          data["count"].as_i64.should eq(3)
        end
      end
    end

    it "returns the per-currency bag for a money field" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"price": {"type": "money"}}))
        create_doc_via_service(db, domain, doctype, %({"price": {"value": "10.50", "currency": "USD"}}))
        create_doc_via_service(db, domain, doctype, %({"price": {"value": "100.00", "currency": "USD"}}))
        create_doc_via_service(db, domain, doctype, %({"price": {"value": "99.95", "currency": "EUR"}}))
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "aggregate": "sum", "field": "price"
        }))
        data = result.as_h["data"].as_h
        bag = data["value"].as_h
        bag.size.should eq(2)
        bag["USD"].as_s.should eq("110.50")
        bag["EUR"].as_s.should eq("99.95")
        data["count"].as_i64.should eq(3)
      end
    end

    it "rejects an unknown aggregate with InvalidParams" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"qty": {"type": "integer"}}))
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /Unknown aggregate/) do
          call_tool(ctx, "aggregate_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}", "aggregate": "median"
          }))
        end
      end
    end

    it "rejects a non-numeric field with InvalidParams" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"name": {"type": "string"}}))
        create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::InvalidParams, /not a numeric field/) do
          call_tool(ctx, "aggregate_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "aggregate": "sum", "field": "name"
          }))
        end
      end
    end

    it "rejects a view-hidden field with RbacDenied" do
      with_db do |db|
        domain, doctype = build_agg_doctype(db, "mcpread", %({"name": {"type": "string"}, "salary": {"type": "integer", "tags": ["confidential"]}}))
        create_doc_via_service(db, domain, doctype, %({"name": "a", "salary": 100}))
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::RbacDenied) do
          call_tool(ctx, "aggregate_documents", %({
            "domain": "#{domain}", "doctype": "#{doctype}",
            "aggregate": "sum", "field": "salary"
          }))
        end
      end
    end

    it "excludes rows outside the caller's RBAC scope" do
      with_db do |db|
        fields = %({
          "name":     {"type": "string", "required": true},
          "qty":      {"type": "integer"},
          "owner_id": {"type": "reference", "doctype": "iam.Account"}
        })
        scopes = %({"mine": {"where": {"owner_id": "$self"}, "description": "Rows owned by the actioner"}})
        domain, doctype = build_agg_doctype(db, "mcpread", fields, scopes)
        caller_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        other_id = create_test_account(db, email: "agg-other@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        create_doc_via_service(db, domain, doctype, %({"name": "mine", "qty": 10, "owner_id": "iam.Account.#{caller_id}"}))
        create_doc_via_service(db, domain, doctype, %({"name": "theirs", "qty": 100, "owner_id": "iam.Account.#{other_id}"}))

        # A Real principal whose read grant on the doctype carries the
        # `mine` scope (`owner_id == $self`) — the same shape a scoped role
        # projection produces.
        role = Facet::RBAC::ActiveRole.new(
          role_id: "iam.Roles.agg_scope",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype], scope: "$mine")],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(caller_id, role)

        result = call_tool(ctx, "aggregate_documents", %({
          "domain": "#{domain}", "doctype": "#{doctype}",
          "aggregate": "sum", "field": "qty"
        }))
        data = result.as_h["data"].as_h
        data["value"].as_i64.should eq(10)
        data["count"].as_i64.should eq(1)
      end
    end
  end
end
