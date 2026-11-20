# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/lua"
require "../../src/document/script_context"
require "../../src/rbac"

module Facet::Document
  # Test value: 2^53 + 1. This is the smallest integer that cannot be
  # exactly represented as a Float64 (it rounds down to 2^53).
  BIG_INT64_SC = 9_007_199_254_740_993_i64

  describe ScriptContext do
    # ── Create context ──────────────────────────────────────────────

    describe "CreateContext" do
      it "passes when the script has no export table" do
        ScriptContext::Create.new("-- no return table", JSON.parse(%({"title": "hello"}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "passes when export.create is absent" do
        script = <<-LUA
          local export = {}
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"quantity": 5}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "passes when create() does not call ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            -- all good, do nothing
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"quantity": 5}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "collects errors when create() calls ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.root.quantity <= 0 then
              ctx.error('quantity must be > 0')
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"quantity": 0}))) do |ctx|
          ctx.run.map(&.message).should eq(["quantity must be > 0"])
        end
      end

      it "collects multiple errors from create()" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.root.quantity <= 0 then
              ctx.error('quantity must be > 0')
            end
            if ctx.root.title == nil or ctx.root.title == '' then
              ctx.error('title is required')
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"quantity": 0, "title": ""}))) do |ctx|
          errors = ctx.run.map(&.message)
          errors.should contain("quantity must be > 0")
          errors.should contain("title is required")
        end
      end

      it "exposes document fields via ctx.root as a Lua table" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.root.title ~= 'Hello' then
              ctx.error('unexpected title')
            end
            if ctx.root.count ~= 42 then
              ctx.error('unexpected count')
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"title": "Hello", "count": 42}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "handles nested document fields as nested tables" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.root.address.city ~= 'Paris' then
              ctx.error('unexpected city')
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"address": {"city": "Paris"}}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "handles document arrays as Lua arrays" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if #ctx.root.tags ~= 3 then
              ctx.error('expected 3 tags')
            end
            if ctx.root.tags[1] ~= 'a' then
              ctx.error('first tag should be a')
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"tags": ["a", "b", "c"]}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "mutates ctx.root and exposes it via root_document" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            ctx.root.slug = ctx.root.title:lower():gsub("%s+", "-")
            if ctx.root.status == nil then
              ctx.root.status = "draft"
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({"title": "My Document"}))) do |ctx|
          ctx.run.should be_empty
          root = ctx.root_document
          root["slug"].as_s.should eq("my-document")
          root["status"].as_s.should eq("draft")
          root["title"].as_s.should eq("My Document")
        end
      end

      it "provides ctx.actor_id and ctx.now" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor_id ~= "test-user" then
              ctx.error("unexpected actor_id")
            end
            if ctx.now == nil then
              ctx.error("now should be set")
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({})), "test-user") do |ctx|
          ctx.run.should be_empty
        end
      end
    end

    # ── ctx.actor (RBAC surface) ──────────────────────────────────

    describe "ctx.actor" do
      it "is nil when no auth_context is passed (backward compat)" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor ~= nil then
              ctx.error("actor should be nil without auth_context")
            end
          end
          return export
        LUA
        ScriptContext::Create.new(script, JSON.parse(%({}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "exposes a minimal table for a system principal" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor == nil then ctx.error("actor missing") end
            if ctx.actor.system ~= true then ctx.error("system should be true") end
            if ctx.actor.id ~= "system" then ctx.error("bad id") end
            if ctx.actor.role_id ~= nil then ctx.error("system has no role_id") end
            if ctx.actor.scope ~= nil then ctx.error("system has no scope") end
          end
          return export
        LUA
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "system",
          auth_context: Facet::RBAC::AuthContext.system
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "exposes role_id, visible_tags, and system=false for a real principal" do
        role = Facet::RBAC::ActiveRole.new(
          role_id: "editor",
          visible_tags: Set{"default", "confidential"},
          permissions: [] of Facet::RBAC::Permission,
        )
        auth = Facet::RBAC::AuthContext.authenticated("account_abc", role)
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor.system ~= false then ctx.error("system should be false") end
            if ctx.actor.id ~= "account_abc" then ctx.error("bad id") end
            if ctx.actor.role_id ~= "editor" then ctx.error("bad role_id") end
            if #ctx.actor.visible_tags ~= 2 then ctx.error("bad tags count") end
            -- Without a domain/doc_type, scope/scopes are absent
            if ctx.actor.scope ~= nil then ctx.error("scope should be nil") end
            if ctx.actor.scopes ~= nil then ctx.error("scopes should be nil") end
            if ctx.actor.context_sets ~= nil then ctx.error("context_sets should be nil") end
          end
          return export
        LUA
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "account_abc",
          auth_context: auth
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "exposes a minimal table for a preview principal" do
        auth = Facet::RBAC::AuthContext.preview("previewer_1", "_draft_abc")
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor == nil then ctx.error("actor missing") end
            if ctx.actor.system ~= false then ctx.error("system should be false") end
            if ctx.actor.id ~= "previewer_1" then ctx.error("bad id") end
            if ctx.actor.role_id ~= nil then ctx.error("preview has no role_id") end
            local count = 0
            for _ in pairs(ctx.actor) do count = count + 1 end
            if count ~= 2 then ctx.error("expected only system and id, got " .. count) end
          end
          return export
        LUA
        # domain/doc_type set on purpose: the preview branch must return
        # before any scope or context-set resolution runs.
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "previewer_1",
          domain: "_draft_abc", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "still exposes role_id for a real principal" do
        role = Facet::RBAC::ActiveRole.new(
          role_id: "editor",
          visible_tags: Set{"default"},
          permissions: [] of Facet::RBAC::Permission,
        )
        auth = Facet::RBAC::AuthContext.authenticated("account_abc", role)
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor.role_id ~= "editor" then ctx.error("bad role_id") end
          end
          return export
        LUA
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "account_abc",
          auth_context: auth
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "exposes the create-permission scope alias when domain/doc_type are set" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "create", domain: "crm", path: ["Project"], scope: "$mine",
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "scoped_creator",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("creator_1", role)
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor == nil then ctx.error("actor missing") end
            if ctx.actor.scope ~= "mine" then ctx.error("bad scope alias") end
            if #ctx.actor.scopes ~= 1 then ctx.error("bad scopes count") end
            if ctx.actor.scopes[1] ~= "mine" then ctx.error("bad scopes value") end
          end
          return export
        LUA
        # No db — context_sets stays absent, but scope is derived purely from
        # the AuthContext, so no DB is needed for this case.
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "creator_1",
          domain: "crm", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "leaves scope nil for an unrestricted create permission" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "create", domain: "crm", path: ["Project"], scope: nil,
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "unscoped_creator",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("creator_2", role)
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            if ctx.actor.scope ~= nil then ctx.error("scope should be nil") end
            if ctx.actor.scopes ~= nil then ctx.error("scopes should be nil") end
          end
          return export
        LUA
        ScriptContext::Create.new(
          script, JSON.parse(%({})), "creator_2",
          domain: "crm", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end
    end

    # ── ctx.actor on Update/Delete/Action ───────────────────────

    describe "ctx.actor across hooks" do
      it "Update exposes the update-permission scope alias" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "update", domain: "crm", path: ["Project"], scope: "$mine",
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "self_editor",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("owner_1", role)
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            if ctx.actor == nil then ctx.error("actor missing") end
            if ctx.actor.system ~= false then ctx.error("system should be false") end
            if ctx.actor.id ~= "owner_1" then ctx.error("bad id") end
            if ctx.actor.role_id ~= "self_editor" then ctx.error("bad role") end
            if ctx.actor.scope ~= "mine" then ctx.error("bad scope") end
            if #ctx.actor.scopes ~= 1 then ctx.error("bad scopes count") end
          end
          return export
        LUA
        ScriptContext::Update.new(
          script, JSON.parse(%({})), "owner_1",
          domain: "crm", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "Delete exposes the delete-permission scope alias (not update)" do
        # Role has an update permission AND a distinct delete permission.
        # The hook must reflect the DELETE permission's scope, proving delete
        # checks its own action name.
        perms = [
          Facet::RBAC::Permission.new(
            action: "update", domain: "crm", path: ["Project"], scope: nil,
          ),
          Facet::RBAC::Permission.new(
            action: "delete", domain: "crm", path: ["Project"], scope: "$mine",
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "self_deleter",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("owner_2", role)
        script = <<-LUA
          local export = {}
          function export.delete(ctx)
            if ctx.actor.scope ~= "mine" then ctx.error("bad scope: " .. tostring(ctx.actor.scope)) end
            if #ctx.actor.scopes ~= 1 then ctx.error("bad scopes count") end
          end
          return export
        LUA
        ScriptContext::Delete.new(
          script, JSON.parse(%({})), "owner_2",
          domain: "crm", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "Delete leaves scope nil when the role only has an unrestricted delete permission" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "delete", domain: "crm", path: ["Project"], scope: nil,
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "open_deleter",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("owner_3", role)
        script = <<-LUA
          local export = {}
          function export.delete(ctx)
            if ctx.actor.scope ~= nil then ctx.error("scope should be nil") end
            if ctx.actor.scopes ~= nil then ctx.error("scopes should be nil") end
          end
          return export
        LUA
        ScriptContext::Delete.new(
          script, JSON.parse(%({})), "owner_3",
          domain: "crm", doc_type: "Project",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "Action exposes the named-action permission's scope alias" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "promote", domain: "hr", path: ["Employee"], scope: "$mine",
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "manager",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("mgr_1", role)
        script = <<-LUA
          local export = {}
          function export.promote(ctx, args)
            if ctx.actor.scope ~= "mine" then ctx.error("bad scope: " .. tostring(ctx.actor.scope)) end
            if ctx.actor.role_id ~= "manager" then ctx.error("bad role") end
          end
          return export
        LUA
        ScriptContext::Action.new(
          script, "promote", JSON.parse(%({})), JSON.parse(%({})), "mgr_1",
          domain: "hr", doc_type: "Employee",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "Action leaves scope nil for an unrestricted action permission" do
        perms = [
          Facet::RBAC::Permission.new(
            action: "promote", domain: "hr", path: ["Employee"], scope: nil,
          ),
        ]
        role = Facet::RBAC::ActiveRole.new(
          role_id: "open_manager",
          visible_tags: Set{"default"},
          permissions: perms,
        )
        auth = Facet::RBAC::AuthContext.authenticated("mgr_2", role)
        script = <<-LUA
          local export = {}
          function export.promote(ctx, args)
            if ctx.actor.scope ~= nil then ctx.error("scope should be nil") end
          end
          return export
        LUA
        ScriptContext::Action.new(
          script, "promote", JSON.parse(%({})), JSON.parse(%({})), "mgr_2",
          domain: "hr", doc_type: "Employee",
          auth_context: auth,
        ) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "Update/Delete/Action expose a minimal system table for system auth_context" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            if ctx.actor.system ~= true then ctx.error("update system") end
            if ctx.actor.role_id ~= nil then ctx.error("update role") end
          end
          function export.delete(ctx)
            if ctx.actor.system ~= true then ctx.error("delete system") end
          end
          function export.promote(ctx, args)
            if ctx.actor.system ~= true then ctx.error("action system") end
          end
          return export
        LUA
        sys = Facet::RBAC::AuthContext.system
        ScriptContext::Update.new(script, JSON.parse(%({})), "system", auth_context: sys) { |c| c.run.should be_empty }
        ScriptContext::Delete.new(script, JSON.parse(%({})), "system", auth_context: sys) { |c| c.run.should be_empty }
        ScriptContext::Action.new(script, "promote", JSON.parse(%({})), JSON.parse(%({})), "system", auth_context: sys) { |c| c.run.should be_empty }
      end
    end

    # ── Update context ─────────────────────────────────────────────

    describe "UpdateContext" do
      it "passes when the script has no update() function" do
        ScriptContext::Update.new("-- no function", JSON.parse(%({"old": 1}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "passes when update() does not call ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            -- all good
          end
          return export
        LUA
        ScriptContext::Update.new(script, JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "provides ctx.root as the current document state" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            if ctx.root.status ~= 'draft' then
              ctx.error('can only update from draft status')
            end
          end
          return export
        LUA
        ScriptContext::Update.new(script, JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "rejects update when script calls ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            if ctx.root.status == 'archived' then
              ctx.error('cannot update archived documents')
            end
          end
          return export
        LUA
        ScriptContext::Update.new(script, JSON.parse(%({"status": "archived"}))) do |ctx|
          ctx.run.map(&.message).should eq(["cannot update archived documents"])
        end
      end

      it "mutates ctx.root via update" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            ctx.root.status = "updated"
          end
          return export
        LUA
        ScriptContext::Update.new(script, JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
          ctx.root_document["status"].as_s.should eq("updated")
        end
      end

      it "exposes ctx.patch as the partial PATCH body the caller submitted" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            -- ctx.patch is the partial body, NOT the merged document.
            -- It is nil for keys the caller did not send and present for
            -- keys they did (even when the value matches the merged root).
            if ctx.patch.status ~= nil then
              ctx.error('status is in the patch')
            end
            if ctx.patch.body ~= nil then
              ctx.error('body should not be in the patch')
            end
          end
          return export
        LUA
        merged = JSON.parse(%({"status": "draft", "body": "hello"}))
        patch = JSON.parse(%({"status": "draft"}))
        ScriptContext::Update.new(script, merged, patch: patch) do |ctx|
          ctx.run.map(&.message).should eq(["status is in the patch"])
        end
      end

      it "does not set ctx.patch when no patch is supplied (backward compatible)" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            if ctx.patch ~= nil then
              ctx.error('ctx.patch should be nil when no patch supplied')
            end
          end
          return export
        LUA
        ScriptContext::Update.new(script, JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
        end
      end
    end

    # ── Delete context ──────────────────────────────────────────────

    describe "DeleteContext" do
      it "passes when the script has no delete() function" do
        ScriptContext::Delete.new("-- no function", JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "passes when delete() does not call ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.delete(ctx)
            -- allow
          end
          return export
        LUA
        ScriptContext::Delete.new(script, JSON.parse(%({"status": "draft"}))) do |ctx|
          ctx.run.should be_empty
        end
      end

      it "provides ctx.root as the current document state" do
        script = <<-LUA
          local export = {}
          function export.delete(ctx)
            if ctx.root.status ~= 'draft' then
              ctx.error('can only delete documents in draft')
            end
          end
          return export
        LUA
        ScriptContext::Delete.new(script, JSON.parse(%({"status": "active"}))) do |ctx|
          ctx.run.map(&.message).should eq(["can only delete documents in draft"])
        end
      end
    end

    # ── Action context ──────────────────────────────────────────────

    describe "ActionContext" do
      it "calls the named action function with ctx and args" do
        script = <<-LUA
          local export = {}
          function export.promote(ctx, args)
            ctx.root.job_title = args.new_title
          end
          return export
        LUA
        ScriptContext::Action.new(script, "promote", JSON.parse(%({"job_title": "Engineer"})), JSON.parse(%({"new_title": "Senior"}))) do |ctx|
          ctx.run.should be_empty
          ctx.root_document["job_title"].as_s.should eq("Senior")
        end
      end

      it "collects errors via ctx.error()" do
        script = <<-LUA
          local export = {}
          function export.promote(ctx, args)
            if ctx.root.status ~= 'active' then
              ctx.error('not active')
            end
          end
          return export
        LUA
        ScriptContext::Action.new(script, "promote", JSON.parse(%({"status": "inactive"})), JSON.parse(%({}))) do |ctx|
          ctx.run.map(&.message).should eq(["not active"])
        end
      end
    end

    # ── Int64 precision ──────────────────────────────────────────────

    describe "int64 precision" do
      it "preserves int64 fields through create ctx.root round-trip" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            -- Read the big integer and echo it back via a new field
            ctx.root.echoed_id = ctx.root.big_id
          end
          return export
        LUA
        doc = JSON.parse(%({"big_id": #{BIG_INT64_SC}}))
        ScriptContext::Create.new(script, doc) do |ctx|
          ctx.run.should be_empty
          root = ctx.root_document
          # The raw value must remain an Int64, not silently become a Float64.
          root["big_id"].raw.should be_a(Int64)
          root["big_id"].raw.should eq BIG_INT64_SC
          root["echoed_id"].raw.should be_a(Int64)
          root["echoed_id"].raw.should eq BIG_INT64_SC
        end
      end

      it "preserves int64 fields through update ctx.root round-trip" do
        script = <<-LUA
          local export = {}
          function export.update(ctx)
            ctx.root.verified_id = ctx.root.big_id
          end
          return export
        LUA
        doc = JSON.parse(%({"big_id": #{BIG_INT64_SC}}))
        ScriptContext::Update.new(script, doc) do |ctx|
          ctx.run.should be_empty
          root = ctx.root_document
          root["big_id"].raw.should be_a(Int64)
          root["big_id"].raw.should eq BIG_INT64_SC
          root["verified_id"].raw.should be_a(Int64)
          root["verified_id"].raw.should eq BIG_INT64_SC
        end
      end
    end

    # ── Lua runtime errors ──────────────────────────────────────────

    describe "runtime errors" do
      it "raises ScriptContext::Error on Lua syntax error" do
        expect_raises(ScriptContext::Error) do
          ScriptContext::Create.new("local export = {}; @@@ invalid syntax @@@ ; return export", JSON.parse(%({}))) do |ctx|
            ctx.run
          end
        end
      end

      it "raises ScriptContext::Error on Lua runtime error (non-error() call)" do
        expect_raises(ScriptContext::Error) do
          ScriptContext::Create.new("local export = {}; function export.create(ctx) mistake() end; return export", JSON.parse(%({}))) do |ctx|
            ctx.run
          end
        end
      end

      # The 422 body embeds this message verbatim (B-131), so it must name
      # the author's line, not the generated wrapper's chunk name and line
      # shift (B-318).
      it "reports a runtime error against the author's script line, without the wrapper chunk name" do
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            mistake()
          end
          return export
        LUA
        ex = expect_raises(ScriptContext::Error) do
          ScriptContext::Create.new(script, JSON.parse(%({}))) do |ctx|
            ctx.run
          end
        end
        msg = ex.message || ""
        msg.should_not contain("[string")
        msg.should start_with("3: ")
      end
    end
  end
end
