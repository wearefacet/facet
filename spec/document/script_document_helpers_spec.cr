# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "json"
require "../../src/rbac"

module Facet::Document
  describe "Lua document.* helpers" do
    it "allows a create hook to create a child document via document.create" do
      with_temp_doctype("dochelpers") do |db, domain, doctype|
        ensure_domain(db, domain)

        # 1. Create a simple Task doctype (the child)
        task_doctype = %({"doctype": "Task", "domain": "#{domain}", "fields": {"title": {"type": "string"}, "project": {"type": "string"}}})
        result = Facet::Document::Create.call(db, "core", "DocType", task_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # 2. Create a Project doctype whose create hook spawns a Task via document.create
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, task = pcall(document.create, "Task", '{"title": "' .. ctx.root.task_title .. '", "project": "' .. ctx.root.name .. '"}')
            if not ok then
              ctx.error("Failed to create task: " .. tostring(task))
              return
            end
            ctx.root.task_id = task.id
          end
          return export
        LUA

        project_doctype = %({
          "doctype": "#{doctype}",
          "domain": "#{domain}",
          "fields": {"name": {"type": "string"}, "task_title": {"type": "string"}},
          "script": #{script.to_json}
        })
        result = Facet::Document::Create.call(db, "core", "DocType", project_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # 3. Create a Project document — this triggers the create hook
        project_body = %({"name": "Launch Pad", "task_title": "Build rocket"})
        project_res = Facet::Document::Create.call(db, domain, doctype, project_body, Facet::RBAC::AuthContext.system)
        proj = expect_create_success(project_res).projection

        # 4. Verify the project has the task_id from the script
        proj.content["name"].as_s.should eq("Launch Pad")
        proj.content["task_title"].as_s.should eq("Build rocket")
        task_id = proj.content["task_id"]?.try(&.as_s?)
        task_id.should_not be_nil

        # 5. Verify the child Task document exists
        task_proj = Facet::Mutation::Client.fetch_projection(db, domain, "Task", task_id.not_nil!)
        task_proj.content["title"].as_s.should eq("Build rocket")
        task_proj.content["project"].as_s.should eq("Launch Pad")

        # 6. Verify the Task mutation has no `origin` stamp — a plain
        # lifecycle-hook-driven create does not carry an action event name,
        # so its provenance is just the default internal channel/request
        # cause root. `arguments` also stays free of any `_reason` key —
        # provenance lives exclusively on the typed provenance columns.
        task_row = db.query_one?(
          "SELECT arguments, channel, cause_kind FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
          domain, "Task", task_id,
          as: {JSON::Any, String, String}
        )
        task_row.should_not be_nil
        args, channel, cause_kind = task_row.not_nil!
        args.as_h.has_key?("_reason").should be_false
        channel.should eq("internal")
        cause_kind.should eq("request")
      end
    end

    it "handles document.create failure gracefully" do
      with_temp_doctype("docfail") do |db, domain, doctype|
        ensure_domain(db, domain)

        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, err = pcall(document.create, "NonExistent", '{"title": "oops"}')
            if not ok then
              ctx.root.error_caught = true
            end
          end
          return export
        LUA

        project_doctype = %({
          "doctype": "#{doctype}",
          "domain": "#{domain}",
          "fields": {"name": {"type": "string"}, "error_caught": {"type": "boolean"}},
          "script": #{script.to_json}
        })
        result = Facet::Document::Create.call(db, "core", "DocType", project_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        proj_res = Facet::Document::Create.call(db, domain, doctype, %({"name": "Failing"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(proj_res).projection
        proj.content["error_caught"].as_bool.should be_true
      end
    end

    it "allows a create hook to read another document via document.get" do
      with_temp_doctype("docget") do |db, domain, doctype|
        ensure_domain(db, domain)

        # Create a simple Config doctype
        config_doctype = %({"doctype": "Config", "domain": "#{domain}", "fields": {"key": {"type": "string"}, "value": {"type": "string"}}})
        result = Facet::Document::Create.call(db, "core", "DocType", config_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # Create a Config document
        config_res = Facet::Document::Create.call(db, domain, "Config", %({"key": "default_role", "value": "viewer"}), Facet::RBAC::AuthContext.system)
        config_id = expect_create_success(config_res).projection.id

        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, config = pcall(document.get, "Config", "#{config_id}")
            if ok then
              ctx.root.default_role = config.content
            else
              ctx.error("Failed to read config: " .. tostring(config))
            end
          end
          return export
        LUA

        # Create a Project doctype whose create hook reads the config
        project_doctype = %({
          "doctype": "#{doctype}",
          "domain": "#{domain}",
          "fields": {"name": {"type": "string"}, "default_role": {"type": "string"}},
          "script": #{script.to_json}
        })
        result = Facet::Document::Create.call(db, "core", "DocType", project_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        proj_res = Facet::Document::Create.call(db, domain, doctype, %({"name": "MyProject"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(proj_res).projection

        # The script succeeded (no errors) so config content was set
        proj.content["default_role"].should_not be_nil
      end
    end

    it "allows a create hook to list documents via document.list" do
      with_temp_doctype("doclist") do |db, domain, doctype|
        ensure_domain(db, domain)

        # Create a simple Note doctype
        note_doctype = %({"doctype": "Note", "domain": "#{domain}", "fields": {"label": {"type": "string"}, "priority": {"type": "integer"}}})
        result = Facet::Document::Create.call(db, "core", "DocType", note_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # Create two notes
        Facet::Document::Create.call(db, domain, "Note", %({"label": "Urgent", "priority": 1}), Facet::RBAC::AuthContext.system)
        Facet::Document::Create.call(db, domain, "Note", %({"label": "Normal", "priority": 2}), Facet::RBAC::AuthContext.system)

        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, result = pcall(document.list, "Note", {}, {"id"}, 1, 10)
            if ok then
              ctx.root.note_count = result.total
              if result.items and #result.items > 0 then
                ctx.root.first_note_id = result.items[1].id
              end
            else
              ctx.error("Failed to list notes: " .. tostring(result))
            end
          end
          return export
        LUA

        # Create a Summary doctype whose create hook lists notes
        summary_doctype = %({
          "doctype": "#{doctype}",
          "domain": "#{domain}",
          "fields": {"name": {"type": "string"}, "note_count": {"type": "integer"}, "first_note_id": {"type": "string"}},
          "script": #{script.to_json}
        })
        result = Facet::Document::Create.call(db, "core", "DocType", summary_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        proj_res = Facet::Document::Create.call(db, domain, doctype, %({"name": "Summary"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(proj_res).projection

        proj.content["note_count"].as_i64.should eq(2)
      end
    end

    it "passes db connection to create and action script contexts" do
      with_temp_doctype("docdbconn") do |db, domain, doctype|
        ensure_domain(db, domain)

        # Create a "Todo" doctype
        todo_doctype = %({"doctype": "Todo", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
        result = Facet::Document::Create.call(db, "core", "DocType", todo_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, todo = pcall(document.create, "Todo", '{"title": "auto task"}')
            if ok then
              ctx.root.todo_count = 1
            else
              ctx.error("create failed: " .. tostring(todo))
            end
          end
          function export.refresh(ctx, args)
            local ok, result = pcall(document.list, "Todo", {}, nil, 1, 100)
            if ok then
              ctx.root.todo_count = result.total
            else
              ctx.error("list failed: " .. tostring(result))
            end
          end
          return export
        LUA

        project_doctype = %({
          "doctype": "#{doctype}",
          "domain": "#{domain}",
          "fields": {"name": {"type": "string"}, "todo_count": {"type": "integer"}},
          "actions": {"refresh": {"args": {}}},
          "script": #{script.to_json}
        })
        result = Facet::Document::Create.call(db, "core", "DocType", project_doctype, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # Create — should use document.create in the create hook
        proj_res = Facet::Document::Create.call(db, domain, doctype, %({"name": "Test"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(proj_res).projection
        proj.content["todo_count"].as_i64.should eq(1)

        # Action — should use document.list in the action
        action_res = Facet::Document::Action.call(db, domain, doctype, proj.id, "refresh", "{}", Facet::RBAC::AuthContext.system)
        action_res.should be_a(Facet::Document::Action::Result)
        updated_proj = action_res.as(Facet::Document::Action::Result).projection
        updated_proj.content["todo_count"].as_i64.should eq(1)
      end
    end
  end
end
