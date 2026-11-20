# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document"
require "../../src/notifications"
require "../../src/iam/helpers"

private def register_scripted_doctype(
  db,
  domain : String,
  doctype : String,
  script : String,
  actions : String = %({"approve": {"args": {}}, "notify": {"args": {}}}),
) : Nil
  ensure_domain(db, domain)
  fields = %({"title": {"type": "string"}, "status": {"type": "string"}, "sent_ok": {"type": "boolean"}, "error_caught": {"type": "boolean"}})
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields},
            "actions": #{actions}, "script": #{script.to_json}})
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  expect_create_success(result)
end

private def create_leave_request(db, domain : String, doctype : String, body : String = %({"title": "Summer leave", "status": "pending"})) : String
  result = Facet::Document::Create.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
  expect_create_success(result).projection.id
end

private def notification_count(db) : Int64
  db.query_one("SELECT count(*) FROM notifications", as: Int64)
end

private def auth_context(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

describe "Lua notification.send helper" do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  it "sends a notification with actions from a create hook" do
    with_temp_doctype("luanota") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "prod-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          local ok, sent = pcall(notification.send,
            "#{account_id}", "#{doc_ref}", "leave_submitted", "A leave request was submitted",
            { icon = "clock",
              body = "Awaiting review",
              data = { requester = ctx.actor_id },
              actions = {
                { key = "approve", label = "Approve", variant = "primary", confirm = "Approve this request?" },
                { key = "deny", label = "Deny", variant = "danger" }
              } })
          if not ok then
            ctx.error("notification failed: " .. tostring(sent))
            return
          end
          ctx.root.sent_ok = (sent == true)
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"title": "Summer leave"}), Facet::RBAC::AuthContext.system)
      ).projection

      # The row exists after the create commits — the send enqueued it and
      # the create flow drained the queue once the mutation persisted.
      row = db.query_one(
        "SELECT account_id, domain, doc_type, doc_id, kind, icon, title, body, data, actions
         FROM notifications",
        as: {String, String, String, String, String, String?, String, String, JSON::Any, JSON::Any},
      )
      account_id_, _n_domain, _n_doc_type, _n_doc_id, kind, icon, title, body, data, actions = row
      account_id_.should eq(account_id)
      kind.should eq("leave_submitted")
      icon.should eq("clock")
      title.should eq("A leave request was submitted")
      body.should eq("Awaiting review")
      data.as_h["requester"].as_s.should_not be_empty

      # The descriptors round-trip through JSONB.
      descriptors = actions.as_a
      descriptors.size.should eq(2)
      descriptors[0].as_h["key"].as_s.should eq("approve")
      descriptors[0].as_h["label"].as_s.should eq("Approve")
      descriptors[0].as_h["variant"].as_s.should eq("primary")
      descriptors[0].as_h["confirm"].as_s.should eq("Approve this request?")
      descriptors[1].as_h["key"].as_s.should eq("deny")
      descriptors[1].as_h["variant"].as_s.should eq("danger")
      descriptors[1].as_h["confirm"]?.should be_nil

      # notification.send returns true — the notification id is not exposed.
      proj.content["sent_ok"].as_bool.should be_true
    end
  end

  it "resolves doc_ref = nil from a create hook to the created document" do
    with_temp_doctype("luanoth") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "self-#{unique_suffix}@example.com")
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          pcall(notification.send, "#{account_id}", nil, "created", "The document was created")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"title": "Summer leave"}), Facet::RBAC::AuthContext.system)
      ).projection

      # The create hook has no ctx.doc_id — the queue fills in the
      # generated document id at drain time.
      n_domain, n_doc_type, n_doc_id = db.query_one(
        "SELECT domain, doc_type, doc_id FROM notifications",
        as: {String, String, String},
      )
      n_domain.should eq(domain)
      n_doc_type.should eq(doctype)
      n_doc_id.should eq(proj.id)
    end
  end

  it "sends from an action hook with doc_ref nil resolved to the actioned document" do
    with_temp_doctype("luanotb") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "prod-#{unique_suffix}@example.com")
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.approve(ctx, args)
          ctx.root.status = "approved"
        end
        function export.notify(ctx, args)
          local ok, sent = pcall(notification.send,
            "#{account_id}", nil, "leave_pending", "A leave request awaits your review",
            { icon = "clock", data = { requester = ctx.actor_id },
              actions = { { key = "approve", label = "Approve", variant = "primary" } } })
          if not ok then ctx.error("notification failed: " .. tostring(sent)) end
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script)
      doc_id = create_leave_request(db, domain, doctype)

      action_result = Facet::Document::Action.call(db, domain, doctype, doc_id, "notify")
      action_result.should be_a(Facet::Document::Action::Result)

      notification_count(db).should eq(1)
      row = db.query_one(
        "SELECT account_id, domain, doc_type, doc_id, kind FROM notifications",
        as: {String, String, String, String, String},
      )
      row[0].should eq(account_id)

      # doc_ref = nil resolves at drain time to the action flow's
      # domain + doc_type + doc_id — the actioned document.
      row[1].should eq(domain)
      row[2].should eq(doctype)
      row[3].should eq(doc_id)
      row[4].should eq("leave_pending")
    end
  end

  it "splits an explicit qualified doc_ref into the domain, doc_type, and doc_id columns" do
    with_temp_doctype("luanotc") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "ref-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          pcall(notification.send, "#{account_id}", "#{doc_ref}", "commented", "New comment")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))
      create_leave_request(db, domain, doctype)

      notification_count(db).should eq(1)
      _, n_domain, n_doc_type, n_doc_id = db.query_one(
        "SELECT account_id, domain, doc_type, doc_id FROM notifications",
        as: {String, String, String, String},
      )
      n_domain.should eq("hr")
      n_doc_type.should eq("LeaveRequest")
      n_doc_id.should eq(doc_ref.split('.')[2])
    end
  end

  it "rejects a bare doc_ref without the domain.Doctype prefix" do
    with_temp_doctype("luanotd") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "bare-#{unique_suffix}@example.com")
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          local ok, err = pcall(notification.send, "#{account_id}", "01BAREIDNOPREFIX", "k", "t")
          ctx.root.error_caught = (ok == false)
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      ).projection
      proj.content["error_caught"].as_bool.should be_true
      notification_count(db).should eq(0)
    end
  end

  it "lets pcall catch an unknown account_id at send time and commits the parent mutation" do
    with_temp_doctype("luanotd") do |db, domain, doctype|
      ensure_domain(db, domain)
      bogus_account = Facet::Util::ScriptHelpers.ulid
      doc_ref = "#{domain}.#{doctype}.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          local ok, err = pcall(notification.send, "#{bogus_account}", "#{doc_ref}", "k", "t")
          ctx.root.error_caught = (ok == false)
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      ).projection
      proj.content["error_caught"].as_bool.should be_true

      # The enqueue rejected the unknown account synchronously; the parent
      # mutation committed and no notification row exists.
      notification_count(db).should eq(0)
    end
  end

  it "leaves no row when the hook sends and then fails the operation" do
    with_temp_doctype("luanoti") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "ghost-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          pcall(notification.send, "#{account_id}", "#{doc_ref}", "k", "t")
          ctx.error("business rule failed after the notification was sent")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      result = Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)

      # The operation failed, so the queue died with it — no ghost
      # notification pointing at a document that never persisted.
      notification_count(db).should eq(0)
    end
  end

  it "drains into an ambient transaction: visible on the connection, gone after rollback" do
    with_temp_doctype("luanotd") do |conn, domain, doctype|
      ensure_domain(conn, domain)
      account_id = create_test_account(conn, email: "rb-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          pcall(notification.send, "#{account_id}", "#{doc_ref}", "k", "t")
        end
        return export
      LUA
      register_scripted_doctype(conn, domain, doctype, script, actions: %({}))

      rolled_back = false
      begin
        Facet::Database.with_transaction(conn) do |txn|
          result = Facet::Document::Create.call(txn, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
          expect_create_success(result)

          # The drain joined the ambient transaction, so the row is
          # visible on the same connection — but uncommitted.
          notification_count(txn).should eq(1)
          raise "force parent rollback"
        end
      rescue
        rolled_back = true
      end
      rolled_back.should be_true
      notification_count(conn).should eq(0)
    end
  end

  it "strips a qualified iam.Account prefix from the account_id" do
    with_temp_doctype("luanote") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "qual-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          pcall(notification.send, "iam.Account.#{account_id}", "#{doc_ref}", "k", "t")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))
      create_leave_request(db, domain, doctype)

      row_account = db.query_one("SELECT account_id FROM notifications", as: String)
      row_account.should eq(account_id)
    end
  end

  it "dispatches an invoked action on the notification's source document" do
    with_temp_doctype("luanotf") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "disp-#{unique_suffix}@example.com")
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.approve(ctx, args)
          ctx.root.status = "approved"
        end
        function export.notify(ctx, args)
          local ok, sent = pcall(notification.send,
            "#{account_id}", nil, "leave_pending", "A leave request awaits your review",
            { actions = { { key = "approve", label = "Approve", variant = "primary" } } })
          if not ok then ctx.error("notification failed: " .. tostring(sent)) end
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script)
      doc_id = create_leave_request(db, domain, doctype)
      action_result = Facet::Document::Action.call(db, domain, doctype, doc_id, "notify")
      action_result.should be_a(Facet::Document::Action::Result)

      notif_id = db.query_one("SELECT id FROM notifications", as: String)
      auth = auth_context(db, account_id, "iam.Roles.admin")
      outcome = Facet::Notification::InvokeAction.invoke_action(db, account_id, notif_id, "approve", auth)

      # The dispatch target is the document the notification points at —
      # the one the action hook was running on (doc_ref=nil resolution).
      outcome.result["data"]["status"].as_s.should eq("approved")
      outcome.result["meta"]["id"].as_s.should eq(doc_id)
      outcome.read_at.should be_close(Time.utc, 1.minute)
    end
  end

  it "raises a Lua error at send time for reserved __-prefixed action keys" do
    with_temp_doctype("luanotg") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "rsv-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          local ok, err = pcall(notification.send, "#{account_id}", "#{doc_ref}", "k", "t",
            { actions = { { key = "__read", label = "Dismiss" } } })
          ctx.root.error_caught = (ok == false)
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      ).projection
      proj.content["error_caught"].as_bool.should be_true
      notification_count(db).should eq(0)
    end
  end

  it "surfaces an uncaught send-time validation failure as a 422 script refusal" do
    with_temp_doctype("luanoth") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "uncaught-#{unique_suffix}@example.com")
      doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
      script = <<-LUA
        local export = {}
        function export.create(ctx)
          notification.send("#{account_id}", "#{doc_ref}", "k", "")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script, actions: %({}))

      result = Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Notification title is required")
      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).code.should eq("script")

      # The refused create wrote nothing — no document, no notification.
      notification_count(db).should eq(0)
    end
  end

  it "surfaces an uncaught send-time validation failure from a named action as a 422 refusal" do
    with_temp_doctype("luanotj") do |db, domain, doctype|
      ensure_domain(db, domain)
      account_id = create_test_account(db, email: "uncaught-a-#{unique_suffix}@example.com")
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.approve(ctx, args) end
        function export.notify(ctx, args)
          notification.send("#{account_id}", nil, "", "A title")
        end
        return export
      LUA
      register_scripted_doctype(db, domain, doctype, script)
      doc_id = create_leave_request(db, domain, doctype)

      action_result = Facet::Document::Action.call(db, domain, doctype, doc_id, "notify")
      action_result.should be_a(Facet::ServiceError)
      error = action_result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Notification kind is required")
      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).code.should eq("script")

      notification_count(db).should eq(0)
    end
  end
end
