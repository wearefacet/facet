# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# History tool group (MCP tools plan, step 6).
#
# Acceptance:
# - `list_mutations` returns the document's mutation history in
#   document-history mode; the projection's create/update/delete all appear.
# - `list_mutations` accepts the `action`/`emitted_at` filter keys; unknown
#   fields raise `InvalidParams`.
# - `get_links` returns the projection's precomputed `links` column for a
#   document that points to another (a `reference` field populated).
# - A denied read on the target surfaces as `NotFound` (non-disclosing).
describe "AgentTools::History" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "lists the mutation history of one document (newest first)" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcphist")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s
      call_tool(ctx, "update_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "patch": {"name": "Globex"}}))

      result = call_tool(ctx, "list_mutations", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
      items = result.as_h["data"].as_a
      actions = items.map(&.as_h["action"].as_s)
      actions.should contain("create")
      actions.should contain("update")
      meta = result.as_h["meta"].as_h
      meta["total"].as_i64.should eq(2)
      # Newest first (default sort -emitted_at).
      actions.first.should eq("update")
      actions.last.should eq("create")
    end
  end

  it "honors an ascending sort argument" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcphist")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "list_mutations", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}",
        "sort": ["emitted_at"]
      }))
      items = result.as_h["data"].as_a
      items.first.as_h["action"].as_s.should eq("create") # idx 0
    end
  end

  it "rejects an unknown filter field with InvalidParams" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /'nope'/) do
        call_tool(ctx, "list_mutations", %({
          "domain": "mcphist", "doctype": "T", "doc_id": "x",
          "filters": {"nope": 1}
        }))
      end
      ex.message.not_nil!.should contain("action, actioner_id, app, channel, kind, trace, emitted_at")
      ex.data.not_nil!.as_h["reason"].as_s.should eq("unknown_field")
    end
  end

  it "carries a structured data payload on malformed-argument errors" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      ex = expect_raises(Facet::AgentTools::InvalidParams) do
        call_tool(ctx, "list_mutations", %({"domain": "d", "doctype": "T", "doc_id": "x", "page": -1}))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("invalid_params")
      ex.data.not_nil!.as_h["argument"].as_s.should eq("page")

      ex = expect_raises(Facet::AgentTools::InvalidParams) do
        call_tool(ctx, "list_mutations", %({"domain": "d", "doctype": "T", "doc_id": "x", "sort": "emitted_at"}))
      end
      ex.data.not_nil!.as_h["argument"].as_s.should eq("sort")
    end
  end

  it "rejects an unsupported operator on an audit column" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      # `action` serves eq/ne only — a range operator is dropped by the
      # service today; the tool raises instead.
      ex = expect_raises(Facet::AgentTools::InvalidParams, /'gte'/) do
        call_tool(ctx, "list_mutations", %({
          "domain": "mcphist", "doctype": "T", "doc_id": "x",
          "filters": {"action__gte": "create"}
        }))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("unsupported_operator")
      ex.data.not_nil!.as_h["field"].as_s.should eq("action")
    end
  end

  it "rejects an unsupported operator on emitted_at" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      expect_raises(Facet::AgentTools::InvalidParams, /emitted_at/) do
        call_tool(ctx, "list_mutations", %({
          "domain": "mcphist", "doctype": "T", "doc_id": "x",
          "filters": {"emitted_at__gt": "2026-01-01T00:00:00Z"}
        }))
      end
    end
  end

  it "filters by the action column" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcphist")
      ctx = build_context(db, "iam.Roles.editor")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s
      call_tool(ctx, "update_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "patch": {"name": "Globex"}}))

      result = call_tool(ctx, "list_mutations", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}",
        "filters": {"action": "update"}
      }))
      actions = result.as_h["data"].as_a.map(&.as_h["action"].as_s)
      actions.should eq(["update"])
    end
  end

  it "returns the links of a document that points to another" do
    with_db do |db|
      # Two doctypes in the same domain: Person (target) and Link (carries a
      # reference to Person). The `links` column on Link's projection will
      # carry the outgoing urn:facet:… reference.
      domain = "mcplink"
      ensure_domain(db, domain)
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Person", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {"name": {"type": "string", "required": true}}
      }), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Link", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "person": {"type": "reference", "doctype": "#{domain}.Person"}
        }
      }), Facet::RBAC::AuthContext.system)

      ctx = build_context(db, "iam.Roles.editor")
      person_id = create_doc_via_service(db, domain, "Person", %({"name": "Jane"}))
      created = call_tool(ctx, "create_document", %({
        "domain": "#{domain}", "doctype": "Link",
        "content": {"name": "L1", "person": "#{person_id}"}
      }))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "get_links", %({"domain": "#{domain}", "doctype": "Link", "doc_id": "#{doc_id}"}))
      links = result.as_h["data"].as_a
      links.should_not be_empty
      # The URN prefix for the target doctype: `urn:facet:<domain>:<Doctype>:<id>`.
      links.any?(&.as_s.includes?(":#{domain}:Person:")).should be_true
      meta = result.as_h["meta"].as_h
      meta["id"].as_s.should eq(doc_id)
    end
  end

  it "raises NotFound for a missing document in get_links (non-disclosing)" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")
      ex = expect_raises(Facet::AgentTools::NotFound, /not found/i) do
        call_tool(ctx, "get_links", %({"domain": "mcplink", "doctype": "Link", "doc_id": "absent"}))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("not_found")
    end
  end

  # ── get_backrefs (Step 13) ───────────────────────────────

  # The service contract (fan-out, unreadable-doctype skip, scope
  # composition, tombstone exclusion, state-pinned URNs, the honest
  # `capped` flag) lives in `spec/document/backrefs_spec.cr`. These cases
  # pin the tool layer: argument dispatch, delegation, and error mapping.
  describe "get_backrefs" do
    it "finds referencing documents across doctypes in one call" do
      with_db do |db|
        domain, team_dt, project_dt, task_dt = build_backref_fixture(db)
        team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
        Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
        Facet::Document::Create.call(db, domain, task_dt, %({"name": "T1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
        ctx = build_context(db, "iam.Roles.viewer")

        result = call_tool(ctx, "get_backrefs", %({"domain": "#{domain}", "doctype": "#{team_dt}", "doc_id": "#{team.id}"}))
        items = result.as_h["data"].as_a
        items.size.should eq(2)
        doctypes = items.map(&.as_h["doc_type"].as_s).sort!
        doctypes.should eq(["Project", "Task"])
        result.as_h["meta"].as_h["target"].as_s.should eq("urn:facet:#{domain}:#{team_dt}:#{team.id}")
        result.as_h["meta"].as_h["capped"].as_bool.should be_false

        # The label rides every stub row — null here, because the fixture
        # doctypes declare no display_name template.
        items.each(&.as_h["display_name"].raw.should(be_nil))
      end
    end

    it "answers NotFound for a missing target (non-disclosing)" do
      with_db do |db|
        domain, team_dt, _project_dt, _task_dt = build_backref_fixture(db)
        ctx = build_context(db, "iam.Roles.viewer")

        expect_raises(Facet::AgentTools::NotFound) do
          call_tool(ctx, "get_backrefs", %({"domain": "#{domain}", "doctype": "#{team_dt}", "doc_id": "absent"}))
        end
      end
    end
  end

  # ── global list_mutations (Step 12) ──────────────────────────

  describe "global list_mutations" do
    it "answers the workspace-wide view newest-first for a wildcard-read role" do
      with_db do |db|
        domain, doctype = build_simple_doctype(db, "mcphist", with_promote: false)
        ctx = build_context(db, "iam.Roles.editor")
        call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "A"}}))
        call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "B"}}))

        result = call_tool(ctx, "list_mutations", %({}))
        items = result.as_h["data"].as_a
        items.size.should be >= 2
        times = items.map(&.as_h["emitted_at"].as_s)
        # `sort` (no bang) copies before sorting, so the server order in
        # `times` survives; `reverse!` flips only that copy. A `sort!` here
        # would reorder `times` before the comparison, collapsing the check
        # to "all timestamps equal" and flaking whenever the seed crosses a
        # second boundary.
        times.should eq(times.sort.reverse!)
        actions = items.map(&.as_h["action"].as_s)
        actions.should contain("create")
      end
    end

    it "narrows the global view by domain" do
      with_db do |db|
        domain, doctype = build_simple_doctype(db, "mcphist", with_promote: false)
        ctx = build_context(db, "iam.Roles.editor")
        call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "A"}}))

        result = call_tool(ctx, "list_mutations", %({"domain": "#{domain}"}))
        items = result.as_h["data"].as_a
        items.size.should be >= 1
        items.all?(&.as_h["domain"].as_s.==("#{domain}")).should be_true
      end
    end

    it "denies the global view without the wildcard read" do
      with_db do |db|
        # A role holding only a scoped read on one doctype — no wildcard.
        ctx = build_context_with_permissions(db, [{"action" => "read", "on" => "mcphist.Thing"}])
        ex = expect_raises(Facet::AgentTools::RbacDenied) do
          call_tool(ctx, "list_mutations", %({}))
        end
        ex.data.not_nil!.as_h["reason"].as_s.should eq("rbac_denied")
      end
    end

    it "keeps document mode unchanged (regression)" do
      with_db do |db|
        domain, doctype = build_simple_doctype(db, "mcphist")
        ctx = build_context(db, "iam.Roles.editor")
        created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
        doc_id = created.as_h["meta"].as_h["id"].as_s

        result = call_tool(ctx, "list_mutations", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}"}))
        result.as_h["data"].as_a.size.should eq(1)
        result.as_h["data"].as_a.first.as_h["doc_id"].as_s.should eq(doc_id)
      end
    end

    it "requires domain and doctype together with doc_id" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.editor")
        ex = expect_raises(Facet::AgentTools::InvalidParams, /'doc_id'/) do
          call_tool(ctx, "list_mutations", %({"doc_id": "x"}))
        end
        ex.data.not_nil!.as_h["argument"].as_s.should eq("doc_id")
      end
    end
  end
end
