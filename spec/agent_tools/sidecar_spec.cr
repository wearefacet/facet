# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "yaml"
require "../../src/iam"
require "../../src/document"
require "../../src/artifact/store"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# Sidecar tool group — the host-scoped sidecar routes as generic MCP tools.
#
# Acceptance:
# - `create_sidecar` attaches a record to a host document through
#   `SidecarHandler.create`: the route owns `target` (the qualified host
#   ref) and each sidecar's Lua create hook forces its ownership anchor
#   (`author` on core.Comment, `uploaded_by` on core.Attachment).
# - Generic over segments and doctypes: the same tool serves a
#   `core.Comment` comment and a `core.Attachment` attachment; the host's
#   `sidecars` map decides what exists.
# - `reply_to` threads a reply onto the same host; a reply pointing at a
#   comment on another host (or a missing one) is refused by the hook.
# - The two REST gates apply: host read (missing/denied → NotFound) and
#   the nested grant on the host-scoped path (read-only role → RbacDenied;
#   flat-only core.Comment grants → NotFound, they serve the flat route).
# - `list_sidecars` lists one host's segment with the list_documents
#   envelope — paginated, `total` excluding the has-more probe row.
# - Flat `create_document` on a sidecar doctype reports the nested-route
#   hint, not the missing-`target` schema error.
# - `get_schema` exposes the host's `sidecars` map so an agent can
#   discover which segments a host declares.
# - Visibility: `create_sidecar` needs a write grant; `list_sidecars` a
#   read grant.
describe "AgentTools::Sidecar" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
    seed_sidecar_tool_comment_doctype
    seed_sidecar_tool_attachment_doctype
  end

  it "attaches a comment to a host document and forces the author" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      ctx = build_context(db, "iam.Roles.editor")

      result = call_tool(ctx, "create_sidecar", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
        "segment": "comments",
        "content": {"body": "hi from the agent"}
      }))
      data = result.as_h["data"].as_h
      data["body"].as_s.should eq("hi from the agent")
      # The route owns `target` — the qualified host ref, not the body.
      data["target"].as_s.should eq("#{domain}.#{host}.#{host_id}")
      # The Lua create hook forces authorship; the Normalize pass
      # qualifies the bare actor id.
      data["author"].as_s.should eq("iam.Account.#{ctx.account_id}")
      meta = result.as_h["meta"].as_h
      meta["id"].as_s.should_not be_empty
      meta["mid"].as_s.should_not be_empty
      meta["doc_type"].as_s.should eq("Comment")
      meta["domain"].as_s.should eq("core")
    end
  end

  it "threads a reply onto the same host" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      ctx = build_context(db, "iam.Roles.editor")

      parent = call_tool(ctx, "create_sidecar", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
        "segment": "comments", "content": {"body": "parent"}
      }))
      parent_id = parent.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "create_sidecar", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
        "segment": "comments", "content": {"body": "reply", "reply_to": "#{parent_id}"}
      }))
      result.as_h["data"].as_h["reply_to"].as_s.should eq("core.Comment.#{parent_id}")
    end
  end

  it "refuses a reply pointing at a comment on another host" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_a = create_doc_via_service(db, domain, host, %({"name": "A"}))
      host_b = create_doc_via_service(db, domain, host, %({"name": "B"}))
      ctx = build_context(db, "iam.Roles.editor")

      other = call_tool(ctx, "create_sidecar", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_a}",
        "segment": "comments", "content": {"body": "on A"}
      }))
      other_id = other.as_h["meta"].as_h["id"].as_s

      ex = expect_raises(Facet::AgentTools::InvalidParams, /same resource/) do
        call_tool(ctx, "create_sidecar", %({
          "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_b}",
          "segment": "comments", "content": {"body": "cross-host reply", "reply_to": "#{other_id}"}
        }))
      end
      ex.data.not_nil!.as_h["details"].as_a.should_not be_empty
    end
  end

  it "raises NotFound for an unknown host doctype" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.editor")
      expect_raises(Facet::AgentTools::NotFound, /Unknown doctype/) do
        call_tool(ctx, "create_sidecar", %({"domain": "mcpscr", "doctype": "Ghost", "doc_id": "x", "segment": "comments", "content": {"body": "hi"}}))
      end
    end
  end

  it "raises InvalidParams naming the declared segments when the segment is unknown" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      ctx = build_context(db, "iam.Roles.editor")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /no sidecar segment 'notes'/) do
        call_tool(ctx, "create_sidecar", %({
          "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
          "segment": "notes", "content": {"body": "hi"}
        }))
      end
      (ex.message || "").should contain("declared segments: comments")
    end
  end

  it "surfaces a missing host document as NotFound (non-disclosing)" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      ctx = build_context(db, "iam.Roles.editor")

      expect_raises(Facet::AgentTools::NotFound, /not found/) do
        call_tool(ctx, "create_sidecar", %({
          "domain": "#{domain}", "doctype": "#{host}", "doc_id": "absent-host",
          "segment": "comments", "content": {"body": "hi"}
        }))
      end
    end
  end

  it "raises RbacDenied for a read-only role" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      # viewer holds wildcard read — the host read gate passes — but no
      # create grant, so the nested create gate denies with 403.
      ctx = build_context(db, "iam.Roles.viewer")

      expect_raises(Facet::AgentTools::RbacDenied) do
        call_tool(ctx, "create_sidecar", %({
          "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
          "segment": "comments", "content": {"body": "hi"}
        }))
      end
    end
  end

  it "raises RbacDenied for a flat-only core.Comment grant (no host read grant)" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      # comment_author holds author-scoped grants on core.Comment only —
      # no hr read and no nested grant — so the host read gate is a
      # class-level denial on the host doctype (RbacDenied).
      ctx = build_context(db, "iam.Roles.comment_author")

      expect_raises(Facet::AgentTools::RbacDenied) do
        call_tool(ctx, "create_sidecar", %({
          "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
          "segment": "comments", "content": {"body": "hi"}
        }))
      end
    end
  end

  it "creates an attachment through a different segment and doctype" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr", with_attachments: true)
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      artifact_id = upload_sidecar_tool_artifact(db, domain, host, host_id)
      ctx = build_context(db, "iam.Roles.editor")

      result = call_tool(ctx, "create_sidecar", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}",
        "segment": "attachments",
        "content": {"name": "Spec file", "file": "#{artifact_id}"}
      }))
      data = result.as_h["data"].as_h
      data["name"].as_s.should eq("Spec file")
      data["file"].as_s.should eq(artifact_id)
      data["target"].as_s.should eq("#{domain}.#{host}.#{host_id}")
      # The Lua create hook forces uploadership; the Normalize pass
      # qualifies the bare actor id.
      data["uploaded_by"].as_s.should eq("iam.Account.#{ctx.account_id}")

      listed = call_tool(ctx, "list_sidecars", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}", "segment": "attachments"
      }))
      items = listed.as_h["data"].as_a
      items.size.should eq(1)
      items.first.as_h["data"].as_h["name"].as_s.should eq("Spec file")
    end
  end

  it "reports the nested-route hint when create_document targets a sidecar doctype" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.editor")

      ex = expect_raises(Facet::AgentTools::InvalidParams, /Sidecar doctypes cannot be created through the flat route/) do
        call_tool(ctx, "create_document", %({
          "domain": "core", "doctype": "Comment", "content": {"body": "nope"}
        }))
      end
      (ex.message || "").should contain("nested route")
    end
  end

  it "lists one host's segment and excludes other hosts'" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_a = create_doc_via_service(db, domain, host, %({"name": "A"}))
      host_b = create_doc_via_service(db, domain, host, %({"name": "B"}))
      ctx = build_context(db, "iam.Roles.editor")

      call_tool(ctx, "create_sidecar", %({"domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_a}", "segment": "comments", "content": {"body": "a1"}}))
      call_tool(ctx, "create_sidecar", %({"domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_a}", "segment": "comments", "content": {"body": "a2"}}))
      call_tool(ctx, "create_sidecar", %({"domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_b}", "segment": "comments", "content": {"body": "b1"}}))

      result = call_tool(ctx, "list_sidecars", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_a}", "segment": "comments"
      }))
      items = result.as_h["data"].as_a
      bodies = items.map(&.as_h["data"].as_h["body"].as_s).sort!
      bodies.should eq(["a1", "a2"])
      meta = result.as_h["meta"].as_h
      meta["total"].as_i64.should eq(2)
      meta["truncated"].as_bool.should be_false
      meta["next_cursor"].raw.should be_nil
    end
  end

  it "paginates with the same total semantics as list_documents" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      ctx = build_context(db, "iam.Roles.editor")
      3.times do |i|
        call_tool(ctx, "create_sidecar", %({"domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}", "segment": "comments", "content": {"body": "c#{i}"}}))
      end

      result = call_tool(ctx, "list_sidecars", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}", "segment": "comments", "items": 2
      }))
      meta = result.as_h["meta"].as_h
      meta["items"].as_i64.should eq(2)
      # `total` excludes the has-more probe row.
      meta["total"].as_i64.should eq(2)
      meta["truncated"].as_bool.should be_true
      meta["next_cursor"].as_i64.should eq(2)

      result = call_tool(ctx, "list_sidecars", %({
        "domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}", "segment": "comments", "items": 2, "page": 2
      }))
      meta = result.as_h["meta"].as_h
      meta["items"].as_i64.should eq(1)
      meta["total"].as_i64.should eq(1)
      meta["truncated"].as_bool.should be_false
      meta["next_cursor"].raw.should be_nil
    end
  end

  it "raises RbacDenied on list for a flat-only core.Comment grant (no host read grant)" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      host_id = create_doc_via_service(db, domain, host, %({"name": "Alice"}))
      ctx = build_context(db, "iam.Roles.comment_author")

      expect_raises(Facet::AgentTools::RbacDenied) do
        call_tool(ctx, "list_sidecars", %({"domain": "#{domain}", "doctype": "#{host}", "doc_id": "#{host_id}", "segment": "comments"}))
      end
    end
  end

  it "exposes the sidecars map on get_schema (and omits it when empty)" do
    with_db do |db|
      domain, host = build_sidecar_tool_host(db, "mcpscr")
      plain_domain, plain = build_sidecar_tool_host(db, "mcpscr", with_comments: false)
      ctx = build_context(db, "iam.Roles.viewer")

      schema = call_tool(ctx, "get_schema", %({"domain": "#{domain}", "doctype": "#{host}"})).as_h
      sidecars = schema["sidecars"].as_h
      sidecars["comments"].as_h["doctype"].as_s.should eq("core.Comment")
      sidecars["comments"].as_h["column"].as_s.should eq("target")

      plain_schema = call_tool(ctx, "get_schema", %({"domain": "#{plain_domain}", "doctype": "#{plain}"})).as_h
      plain_schema.has_key?("sidecars").should be_false
    end
  end

  it "hides create_sidecar from a read-only role and shows list_sidecars" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should_not contain("create_sidecar")
      names.should contain("list_sidecars")
    end
  end
end

# ── Helpers (unique names — spec defs are checked across files) ──────────

# Registers a sidecar doctype from a production seed directory, with its
# co-located Lua script (the create hook forces the ownership anchor;
# without the script the hook never runs). Mirrors the seed runner's
# definition+script injection.
def seed_sidecar_tool_doctype(seed_dir : String, label : String) : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "data", "seeds", seed_dir)
    yaml = YAML.parse(File.read(File.join(dir, "definition.yml")))
    parsed = Facet::Doctype::YamlHelper.to_json_any(yaml)

    script_path = File.join(dir, "script.lua")
    parsed.as_h["script"] = JSON::Any.new(File.read(script_path)) if File.exists?(script_path)

    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", parsed.to_json, Facet::RBAC::AuthContext.system)
    raise "#{label} sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

def seed_sidecar_tool_comment_doctype : Nil
  seed_sidecar_tool_doctype("core.Comment", "comment")
end

def seed_sidecar_tool_attachment_doctype : Nil
  seed_sidecar_tool_doctype("core.Attachment", "attachment")
end

# Registers an aggregate-root host doctype that declares (or, with
# `with_comments: false`, omits) a `comments` sidecar entry pointing at
# `core.Comment`, and optionally an `attachments` entry pointing at
# `core.Attachment`. Returns `[domain, host_doctype]`.
def build_sidecar_tool_host(db, domain : String, with_comments : Bool = true, with_attachments : Bool = false) : {String, String}
  ensure_domain(db, domain)
  host = "H#{unique_suffix}"
  segments = [] of String
  segments << %("comments": {"doctype": "core.Comment", "column": "target"}) if with_comments
  segments << %("attachments": {"doctype": "core.Attachment", "column": "target"}) if with_attachments
  sidecars = segments.empty? ? "" : %("sidecars": {#{segments.join(", ")}},)
  defn = %({"doctype": "#{host}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
            "fields": {"name": {"type": "string"}}, #{sidecars}
            "description": "sidecar tool host"})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{host}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
  {domain, host}
end

# Uploads one small artifact bound to the host document and returns its
# id — the `file` field value for a tool-created `core.Attachment`.
def upload_sidecar_tool_artifact(db, domain : String, host : String, host_id : String) : String
  bytes = "sidecar tool payload #{Random::Secure.hex(16)}"
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(bytes), "tool.bin",
    Facet::RBAC::AuthContext.system,
    domain, host, host_id, "file", nil,
  )
  raise "artifact upload failed: #{result}" unless result.is_a?(Facet::Artifact::Uploader::Result)
  result.artifact_id
end
