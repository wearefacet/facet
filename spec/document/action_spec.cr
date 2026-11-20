# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

describe Facet::Document::Action do
  it "executes a named action on a document" do
    with_temp_doctype("actbasic") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args)
          ctx.root.status = args.new_status
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      actions = %({"promote": {"args": {"new_status": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task", "status": "draft"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", %({"new_status": "published"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["status"].as_s.should eq("published")
      action_res.mutation_id.should_not be_empty
    end
  end

  it "binds the update lifecycle hook to named actions (B-291)" do
    with_temp_doctype("actguard") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.close(ctx, args)
          ctx.root.status = "closed"
          ctx.root.closed = "yes"
        end
        function export.reopen(ctx, args)
          ctx.root.status = args.new_status
        end
        function export.update(ctx)
          if ctx.root.closed == "yes" and ctx.root.status == "draft" then
            ctx.error("closed order cannot return to draft")
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}, "closed": {"type": "string"}})
      actions = %({"close": {"args": {}}, "reopen": {"args": {"new_status": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Order", "status": "draft", "closed": "no"}), Facet::RBAC::AuthContext.system)).projection.id

      # Closing lands a state the guard accepts.
      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "close", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      closed = result.as(Facet::Document::Action::Result).projection
      closed.content["status"].as_s.should eq("closed")
      closed.content["closed"].as_s.should eq("yes")

      # The same guard refuses the closed → draft transition on both paths.
      patch_res = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"status": "draft"}), Facet::RBAC::AuthContext.system)
      patch_res.should be_a(Facet::ServiceError)
      patch_err = patch_res.as(Facet::ServiceError)
      patch_err.status.should eq(422)
      patch_err.message.should contain("Script validation failed")
      patch_err.details.not_nil!.any?(&.message.includes?("closed order cannot return to draft")).should be_true

      action_res = Facet::Document::Action.call(db, domain, doctype, doc_id, "reopen", %({"new_status": "draft"}), Facet::RBAC::AuthContext.system)
      action_res.should be_a(Facet::ServiceError)
      action_err = action_res.as(Facet::ServiceError)
      action_err.status.should eq(422)
      action_err.message.should contain("Action 'reopen' failed")
      action_err.details.not_nil!.any?(&.message.includes?("closed order cannot return to draft")).should be_true

      # A transition the guard accepts still lands.
      ok_res = Facet::Document::Action.call(db, domain, doctype, doc_id, "reopen", %({"new_status": "review"}), Facet::RBAC::AuthContext.system)
      ok_res.should be_a(Facet::Document::Action::Result)
      ok_res.as(Facet::Document::Action::Result).projection.content["status"].as_s.should eq("review")
    end
  end

  it "exposes ctx.action to every hook on the action path and stays absent on PATCH" do
    with_temp_doctype("actctx") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.validate(ctx)
          ctx.root.validate_saw = ctx.action or "none"
        end
        function export.promote(ctx, args)
          ctx.root.status = args.new_status
        end
        function export.update(ctx)
          ctx.root.updated_via = ctx.action or "patch"
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}, "validate_saw": {"type": "string"}, "updated_via": {"type": "string"}})
      actions = %({"promote": {"args": {"new_status": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T", "status": "draft"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", %({"new_status": "published"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      proj = result.as(Facet::Document::Action::Result).projection
      proj.content["updated_via"].as_s.should eq("promote")
      proj.content["validate_saw"].as_s.should eq("promote")

      patch_res = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"status": "review"}), Facet::RBAC::AuthContext.system)
      patch_res.should be_a(Facet::Document::Update::Result)
      patch_proj = patch_res.as(Facet::Document::Update::Result).projection
      patch_proj.content["updated_via"].as_s.should eq("patch")
      patch_proj.content["validate_saw"].as_s.should eq("none")
    end
  end

  it "exposes ctx.changed to the update hook on the action path only" do
    with_temp_doctype("actdiff") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args)
          ctx.root.status = args.new_status
          ctx.root.note = args.note
        end
        function export.update(ctx)
          if ctx.changed ~= nil then
            ctx.root.changed_seen = table.concat(ctx.changed, ",")
          else
            ctx.root.changed_seen = "none"
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}, "note": {"type": "string"}, "changed_seen": {"type": "string"}})
      actions = %({"promote": {"args": {"new_status": {"type": "string", "required": true}, "note": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T", "status": "draft"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", %({"new_status": "published", "note": "n"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      result.as(Facet::Document::Action::Result).projection.content["changed_seen"].as_s.should eq("note,status")

      patch_res = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "T2"}), Facet::RBAC::AuthContext.system)
      patch_res.should be_a(Facet::Document::Update::Result)
      patch_res.as(Facet::Document::Update::Result).projection.content["changed_seen"].as_s.should eq("none")
    end
  end

  it "maps a Lua runtime error in the action-path update hook to a 422" do
    with_temp_doctype("actuerr") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args)
          ctx.root.status = "published"
        end
        function export.update(ctx)
          no_such_helper()
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      actions = %({"promote": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should start_with("Script error: ")
      err.message.should contain("no_such_helper")
    end
  end

  it "returns 404 for an unknown doctype" do
    with_db do |db|
      result = Facet::Document::Action.call(db, "nonexistent", "Unknown", "some-id", "promote", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("Unknown doctype")
    end
  end

  it "returns 404 for an unknown action" do
    with_temp_doctype("actunkn") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "nonexistent_action", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("Unknown action")
    end
  end

  it "returns 404 for a non-existent document" do
    with_temp_doctype("actnf") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args) end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"promote": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      result = Facet::Document::Action.call(db, domain, doctype, "nonexistent", "promote", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("not found")
    end
  end

  it "returns 422 when the doctype has no script (B-299)" do
    with_temp_doctype("actnoscr") do |db, domain, doctype|
      ensure_domain(db, domain)
      actions = %({"promote": {"args": {}}})
      # Authoring now rejects actions without a script; seed the legacy
      # definition directly through the mutation log to exercise the
      # runtime guard.
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}, "actions": #{actions}})
      parsed = Facet::Doctype::DoctypeDefinition.from_json(defn)
      Facet::Mutation::Client.create(
        db, "core", "DocType",
        doc_id: "#{domain}.#{doctype}",
        content: parsed.to_json,
        actioner_id: "system:test",
      )
      Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("No script defined")
    end
  end

  it "returns 422 for invalid JSON in action arguments" do
    with_temp_doctype("actjson") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args) end
        return export
      LUA
      actions = %({"promote": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", "not json", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Invalid JSON")
    end
  end

  it "returns 422 when required action arguments are missing" do
    with_temp_doctype("actargs") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args) end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"promote": {"args": {"new_status": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Invalid action arguments")
      err.details.not_nil!.any? { |e| e.field == "new_status" && e.code == "required" }.should be_true
    end
  end

  it "returns 422 when the Lua action calls ctx.error()" do
    with_temp_doctype("acterr") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.promote(ctx, args)
          if args.new_status == 'archived' then
            ctx.error('cannot archive directly via promote')
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      actions = %({"promote": {"args": {"new_status": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Task", "status": "draft"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "promote", %({"new_status": "archived"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("failed")
      err.details.not_nil!.map(&.message).should contain("cannot archive directly via promote")
    end
  end

  it "surfaces a refused nested document.create with the guard's native 422 (B-30)" do
    with_temp_doctype("actguard") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Kid"

      parent_script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.sneaky(ctx, args)
          document.create("#{child_dt}", { label = "orphan" })
        end
        return export
      LUA
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}, "actions": {"sneaky": {"args": {}}}, "script": #{parent_script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "P"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "sneaky", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Document '#{child_dt}' belongs to '#{doctype}'")

      # The guard refused the nested create — no orphan row landed.
      count = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = $1 AND doc_type = $2",
        domain, child_dt, as: Int64)
      count.should eq(0)
    end
  end

  # ── Cross-domain read denial (G4) is a catchable Lua error (B-48) ─────

  it "catches a grant-denied cross-domain document.list with pcall and completes the action (B-48)" do
    with_temp_doctype("actxlist") do |db, domain, doctype|
      ensure_domain(db, domain)
      ensure_domain(db, "xlistforeign")
      foreign_defn = %({"doctype": "Ledger", "domain": "xlistforeign", "fields": {"amount": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", foreign_defn, Facet::RBAC::AuthContext.system)

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.price(ctx, args)
          local ok, res = pcall(document.list, "xlistforeign.Ledger", {})
          if ok then
            ctx.root.read_path = "granted"
          else
            ctx.root.read_path = "denied: " .. tostring(res)
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "read_path": {"type": "string"}})
      actions = %({"price": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "price", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      content = result.as(Facet::Document::Action::Result).projection.content
      # pcall caught the denial (ok == false) and the script continued.
      content["read_path"].as_s.should start_with("denied: Cross-domain read denied")
    end
  end

  it "surfaces an uncaught grant-denied cross-domain document.list as 422 (B-48)" do
    with_temp_doctype("actxlistraw") do |db, domain, doctype|
      ensure_domain(db, domain)
      ensure_domain(db, "xlistforeign")
      foreign_defn = %({"doctype": "Ledger", "domain": "xlistforeign", "fields": {"amount": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", foreign_defn, Facet::RBAC::AuthContext.system)

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.price(ctx, args)
          document.list("xlistforeign.Ledger", {})
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"price": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "price", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Cross-domain read denied")
      err.message.should contain("xlistforeign")
      err.message.should contain("Ledger")
    end
  end

  it "catches a grant-denied cross-domain document.get with pcall and completes the action (B-48)" do
    with_temp_doctype("actxget") do |db, domain, doctype|
      ensure_domain(db, domain)
      ensure_domain(db, "xlistforeign")
      foreign_defn = %({"doctype": "Ledger", "domain": "xlistforeign", "fields": {"amount": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", foreign_defn, Facet::RBAC::AuthContext.system)

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.price(ctx, args)
          local ok, res = pcall(document.get, "xlistforeign.Ledger", "some-id")
          if ok then
            ctx.root.read_path = "granted"
          else
            ctx.root.read_path = "fallback"
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "read_path": {"type": "string"}})
      actions = %({"price": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "price", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      content = result.as(Facet::Document::Action::Result).projection.content
      content["read_path"].as_s.should eq("fallback")
    end
  end

  it "surfaces an uncaught grant-denied cross-domain document.get as 422 (B-48)" do
    with_temp_doctype("actxgetraw") do |db, domain, doctype|
      ensure_domain(db, domain)
      ensure_domain(db, "xlistforeign")
      foreign_defn = %({"doctype": "Ledger", "domain": "xlistforeign", "fields": {"amount": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", foreign_defn, Facet::RBAC::AuthContext.system)

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.price(ctx, args)
          document.get("xlistforeign.Ledger", "some-id")
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"price": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "price", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Cross-domain read denied")
    end
  end

  # ── Write doctype-name form (B-386) ──────────────────────────

  # Writes accept the bare doctype, plus a qualified name whose domain is
  # the script's own domain (stripped). A foreign qualifier is refused fast.
  it "accepts a qualified own-domain doctype name on every document write (B-386)" do
    with_temp_doctype("actwq") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.drive(ctx, args)
          local created = document.create("#{domain}.#{doctype}", { title = "qualified" })
          local updated = document.update("#{domain}.#{doctype}", created.id, '{"title": "qualified2"}')
          document.delete("#{domain}.#{doctype}", updated.id)
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"drive": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "drive", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
    end
  end

  it "refuses a cross-domain qualified doctype name on document.update with the naming message (B-386)" do
    with_temp_doctype("actwx") do |db, domain, doctype|
      ensure_domain(db, domain)
      ensure_domain(db, "wxforeign")
      foreign_defn = %({"doctype": "Ledger", "domain": "wxforeign", "fields": {"amount": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", foreign_defn, Facet::RBAC::AuthContext.system)

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.edit(ctx, args)
          document.update("wxforeign.Ledger", "no-such-id", '{"amount": "1"}')
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"edit": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "edit", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Document writes take a bare same-domain doctype name")
      err.message.should contain("wxforeign")
    end
  end

  it "keeps accepting the bare doctype name on every document write (B-386)" do
    with_temp_doctype("actwbare") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.drive(ctx, args)
          local created = document.create("#{doctype}", { title = "bare" })
          document.update("#{doctype}", created.id, '{"title": "bare2"}')
          document.delete("#{doctype}", created.id)
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"drive": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "drive", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
    end
  end

  it "answers 422 with the Lua message when an action raises an uncaught Lua error (B-131)" do
    with_temp_doctype("actbug") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.boom(ctx, args)
          no_such_helper()
        end
        return export
      LUA
      actions = %({"boom": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "boom", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should start_with("Script error: ")
      err.message.should contain("no_such_helper")
    end
  end

  it "returns the existing projection when the action makes no changes" do
    with_temp_doctype("actnop") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.noop(ctx, args) end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"noop": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Noop"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "noop", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["title"].as_s.should eq("Noop")
    end
  end

  it "re-evaluates computed fields after action execution" do
    with_temp_doctype("actcomp") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.rename(ctx, args)
          ctx.root.name = args.new_name
        end
        function export.compute_slug(ctx)
          if ctx.root.name then
            return ctx.root.name:lower():gsub("%s+", "-")
          end
          return nil
        end
        return export
      LUA
      fields = %({
        "name": {"type": "string"},
        "slug": {"type": "data", "compute": "slug", "compute_when": ["name"]}
      })
      actions = %({"rename": {"args": {"new_name": {"type": "string", "required": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"name": "Original"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "rename", %({"new_name": "My Document"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["slug"].as_s.should eq("my-document")
    end
  end

  # Verify that an action's update mutation carries a structured `cause`
  # (kind=action, event=escalated) on the typed provenance columns, and that
  # any nested `document.*` Lua calls driven by the action inherit the same
  # cause **plus** `cause_parent` bound to the action's own mutation id and
  # the original caller's `actioner_id` (rather than `system`). The trace
  # ties the whole cluster to the action mutation.
  it "stamps the action's cause on the action mutation and links nested document.* calls via parent + trace" do
    with_temp_doctype("actorigin") do |db, domain, primary_dt|
      ensure_domain(db, domain)

      sibling_dt = "Sibling"
      sibling_script = "local export = {}\nfunction export.create(ctx) end\nreturn export"
      sibling_defn = %({
        "doctype": "#{sibling_dt}",
        "domain": "#{domain}",
        "fields": {"status": {"type": "string"}},
        "script": #{sibling_script.to_json}
      })
      res = Facet::Document::Create.call(db, "core", "DocType", sibling_defn, Facet::RBAC::AuthContext.system)
      res.should be_a(Facet::Document::Create::Result)

      sibling_doc = Facet::Document::Create.call(db, domain, sibling_dt, %({"status": "draft"}), Facet::RBAC::AuthContext.system)
      sibling_id = expect_create_success(sibling_doc).projection.id

      # Primary doctype: an action `escalate` (event name `escalated`) that
      # mutates `ctx.root` (producing one update mutation on the primary)
      # and also calls `document.update` on the sibling (producing a second,
      # Lua-driven update mutation on the sibling).
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.escalate(ctx, args)
          ctx.root.status = "escalated"
          document.update("#{sibling_dt}", "#{sibling_id}", '{"status": "escalated"}')
        end
        return export
      LUA
      fields = %({"status": {"type": "string"}})
      actions = %({"escalate": {"args": {}}})
      defn = %({"doctype": "#{primary_dt}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, primary_dt, %({"status": "open"}), Facet::RBAC::AuthContext.system)
      primary_id = expect_create_success(doc_res).projection.id

      # Drive the action as an explicit authenticated principal so the
      # propagated actioner_id is observable in the audit log. The role
      # carries an unrestricted `escalate` permission scoped to the
      # primary doctype so RBAC authorizes the action call.
      role = Facet::RBAC::ActiveRole.new(
        role_id: "test",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [
          Facet::RBAC::Permission.new(
            action: "escalate",
            domain: domain,
            path: [primary_dt],
          ),
        ],
      )
      auth = Facet::RBAC::AuthContext.authenticated("user-42", role)

      result = Facet::Document::Action.call(db, domain, primary_dt, primary_id, "escalate", "{}", auth)
      result.should be_a(Facet::Document::Action::Result)

      # Expect the action's own update mutation to carry cause kind=action
      # with event=escalated, trace = its own id, no parent, and the
      # original caller's actioner_id.
      primary_mut = db.query_one(
        "SELECT cause_kind, cause_event, cause_trace, cause_parent, actioner_id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update' ORDER BY idx DESC LIMIT 1",
        domain, primary_dt, primary_id,
        as: {String, String?, String, String?, String}
      )
      primary_mut[0].should eq("action")
      primary_mut[1].should eq("escalated")
      primary_trace = primary_mut[2]
      primary_trace.should be_a(String)
      primary_mut[3].should be_nil
      primary_mut[4].should eq("user-42")

      # Expect the nested Lua-driven mutation on the sibling to inherit the
      # same cause with `parent` bound to the action mutation id (the
      # `trace` equals the action's own id) and the same actioner_id.
      sibling_mut = db.query_one(
        "SELECT cause_kind, cause_event, cause_trace, cause_parent, actioner_id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update' ORDER BY idx DESC LIMIT 1",
        domain, sibling_dt, sibling_id,
        as: {String, String?, String, String?, String}
      )
      sibling_mut[0].should eq("action")
      sibling_mut[1].should eq("escalated")
      sibling_mut[2].should eq(primary_trace)
      sibling_mut[3].should eq(primary_trace)
      sibling_mut[4].should eq("user-42")
    end
  end

  # ── Action argument constraints (B-51, B-52) ──────────────────────

  it "rejects an integer action argument outside its declared min/max (B-51)" do
    with_temp_doctype("actrange") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.record_visit(ctx, args)
          ctx.root.score = args.score
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "score": {"type": "integer"}})
      actions = %({"record_visit": {"args": {"score": {"type": "integer", "min": 1, "max": 5}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "record_visit", %({"score": 9}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "score" && e.code == "out_of_range" && e.message == "must be at most 5" }.should be_true

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "record_visit", %({"score": 0}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "score" && e.code == "out_of_range" && e.message == "must be at least 1" }.should be_true
    end
  end

  it "accepts an integer action argument at the min/max boundaries (B-51)" do
    with_temp_doctype("actbounds") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.record_visit(ctx, args)
          ctx.root.score = args.score
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "score": {"type": "integer"}})
      actions = %({"record_visit": {"args": {"score": {"type": "integer", "min": 1, "max": 5}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      [1, 5].each do |score|
        result = Facet::Document::Action.call(db, domain, doctype, doc_id, "record_visit", %({"score": #{score}}), Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Action::Result)
        action_res = result.as(Facet::Document::Action::Result)
        action_res.projection.content["score"].as_i.should eq(score)
      end
    end
  end

  it "accepts a collection action argument and validates each element (B-52)" do
    with_temp_doctype("actcoll") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.tag(ctx, args)
          ctx.root.joined = table.concat(args.tags, ",")
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "joined": {"type": "string"}})
      actions = %({"tag": {"args": {"tags": {"type": "string", "collection": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "tag", %({"tags": ["alpha", "beta"]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["joined"].as_s.should eq("alpha,beta")

      # A bad element fails with the element path, not the arg name.
      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "tag", %({"tags": ["alpha", 42]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "tags.1" && e.code == "invalid_type" }.should be_true
    end
  end

  it "rejects a scalar submitted for a collection action argument (B-52)" do
    with_temp_doctype("actcollscalar") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.tag(ctx, args) end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      actions = %({"tag": {"args": {"tags": {"type": "string", "collection": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "tag", %({"tags": "alpha"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "tags" && e.code == "invalid_type" && e.message == "must be an array" }.should be_true
    end
  end

  it "checks collection action argument elements against the declared enum (B-52)" do
    with_temp_doctype("actcollenum") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.flag(ctx, args)
          ctx.root.joined = table.concat(args.flags, ",")
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "joined": {"type": "string"}})
      actions = %({"flag": {"args": {"flags": {"type": "enum", "values": ["a", "b", "c"], "collection": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "flag", %({"flags": ["a", "b"]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["joined"].as_s.should eq("a,b")

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "flag", %({"flags": ["a", "z"]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "flags.1" && e.code == "invalid_format" }.should be_true
    end
  end

  it "keeps an untyped array action argument working (B-52)" do
    with_temp_doctype("actarr") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.tally(ctx, args)
          ctx.root.count = #args.items
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "count": {"type": "integer"}})
      actions = %({"tally": {"args": {"items": {"type": "array"}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "tally", %({"items": ["x", "y", "z"]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["count"].as_i.should eq(3)

      # Elements stay unvalidated — mixed element types pass.
      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "tally", %({"items": ["x", 1, true]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["count"].as_i.should eq(3)
    end
  end

  it "qualifies bare ids on a scalar reference action argument (B-52)" do
    with_temp_doctype("actsclareref") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.link(ctx, args)
          ctx.root.seen = args.refs
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "seen": {"type": "string"}})
      actions = %({"link": {"args": {"refs": {"type": "reference", "doctype": "#{domain}.#{doctype}"}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "link", %({"refs": "task-1"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["seen"].as_s.should eq("#{domain}.#{doctype}.task-1")
    end
  end

  it "qualifies bare ids element-wise on a collection reference action argument (B-52)" do
    with_temp_doctype("actcolref") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.link(ctx, args)
          ctx.root.seen = table.concat(args.refs, "|")
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "seen": {"type": "string"}})
      actions = %({"link": {"args": {"refs": {"type": "reference", "doctype": "#{domain}.#{doctype}", "collection": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "link", %({"refs": ["task-1", "task-2"]}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["seen"].as_s.should eq("#{domain}.#{doctype}.task-1|#{domain}.#{doctype}.task-2")
    end
  end

  # ── Action argument defaults (B-57) ─────────────────────────

  it "materializes a declared default when the caller omits the arg (B-57)" do
    with_temp_doctype("actdefault") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.flag_probe(ctx, args)
          if args.flag == nil then
            ctx.root.flag_type = "nil"
          elseif args.flag == true then
            ctx.root.flag_type = "boolean"
          else
            ctx.root.flag_type = type(args.flag)
          end
          ctx.root.flag = args.flag
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "flag": {"type": "boolean"}, "flag_type": {"type": "string"}})
      actions = %({"flag_probe": {"args": {"flag": {"type": "boolean", "default": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "flag_probe", %({}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["flag_type"].as_s.should eq("boolean")
      action_res.projection.content["flag"].should eq(JSON::Any.new(true))
    end
  end

  it "keeps an explicit null arg null instead of applying the default (B-57)" do
    with_temp_doctype("actdefnull") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.flag_probe(ctx, args)
          ctx.root.flag_type = args.flag == nil and "nil" or type(args.flag)
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "flag_type": {"type": "string"}})
      actions = %({"flag_probe": {"args": {"flag": {"type": "boolean", "default": true}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "flag_probe", %({"flag": null}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["flag_type"].as_s.should eq("nil")
    end
  end

  it "rejects a default that does not match the declared arg type (B-57)" do
    with_temp_doctype("actdefbad") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.bump(ctx, args)
          ctx.root.score = args.score
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "score": {"type": "integer"}})
      actions = %({"bump": {"args": {"score": {"type": "integer", "default": "abc"}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "bump", %({}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "score" }.should be_true
    end
  end

  it "satisfies a required arg through its declared default (B-57)" do
    with_temp_doctype("actdefreq") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.bump(ctx, args)
          ctx.root.score = args.score
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "score": {"type": "integer"}})
      actions = %({"bump": {"args": {"score": {"type": "integer", "required": true, "default": 3}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "bump", %({}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
      action_res = result.as(Facet::Document::Action::Result)
      action_res.projection.content["score"].as_i.should eq(3)
    end
  end

  it "enforces declared min/max on a string action argument (B-57)" do
    with_temp_doctype("actstrrange") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.set_code(ctx, args)
          ctx.root.code = args.code
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "code": {"type": "string"}})
      actions = %({"set_code": {"args": {"code": {"type": "string", "min": 2, "max": 4}}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "Task"}), Facet::RBAC::AuthContext.system)).projection.id

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "set_code", %({"code": "a"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "code" && e.code == "out_of_range" && e.message == "must be at least 2 characters" }.should be_true

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "set_code", %({"code": "abcde"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "code" && e.code == "out_of_range" && e.message == "must be at most 4 characters" }.should be_true

      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "set_code", %({"code": "ab"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Action::Result)
    end
  end

  # ── State gate (B-323) ───────────────────────────────────────────

  it "gates a named action on the declared document state (B-323)" do
    with_temp_doctype("actgate") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.approve(ctx, args)
          ctx.root.status = "approved"
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      actions = %({"approve": {"args": {}, "states": {"status": ["submitted"]}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      draft_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T", "status": "draft"}), Facet::RBAC::AuthContext.system)).projection.id
      submitted_id = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"title": "T", "status": "submitted"}), Facet::RBAC::AuthContext.system)).projection.id

      # Wrong state: the guard refuses before the script runs.
      result = Facet::Document::Action.call(db, domain, doctype, draft_id, "approve", "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("not available in the current state")

      # The refused action left no mutation behind.
      count = db.query_one(
        "SELECT count(*) FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update'",
        domain, doctype, draft_id, as: Int64)
      count.should eq(0)

      # Declared state: the action lands.
      ok = Facet::Document::Action.call(db, domain, doctype, submitted_id, "approve", "{}", Facet::RBAC::AuthContext.system)
      ok.should be_a(Facet::Document::Action::Result)
      ok.as(Facet::Document::Action::Result).projection.content["status"].as_s.should eq("approved")
    end
  end
end
