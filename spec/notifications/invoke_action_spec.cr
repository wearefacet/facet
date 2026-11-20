# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/notifications"
require "../../src/iam/helpers"

private def register_action_doctype(db, domain : String, doctype : String) : Nil
  ensure_domain(db, domain)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.approve(ctx, args)
      ctx.root.status = "approved"
    end
    function export.reject(ctx, args)
      ctx.root.status = "rejected"
    end
    return export
  LUA
  fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
  actions = %({"approve": {"args": {}}, "reject": {"args": {}}})
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields},
            "actions": #{actions}, "script": #{script.to_json}})
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
end

private def create_leave_request(db, domain : String, doctype : String) : String
  result = Facet::Document::Create.call(
    db, domain, doctype,
    %({"title": "Summer leave", "status": "pending"}),
    Facet::RBAC::AuthContext.system,
  )
  expect_create_success(result).projection.id
end

private def send_pending_notification(db, account_id : String, domain : String, doctype : String, doc_id : String)
  Facet::Notification::Send.send(
    db, account_id, domain, doctype, doc_id,
    "leave_pending", "A leave request awaits your review",
    actions: [Facet::Notification::Action.new(key: "approve", label: "Approve", variant: "primary")],
  )
end

private def auth_context(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

describe Facet::Notification::InvokeAction do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  describe ".invoke_action" do
    it "dispatches the action, returns the result envelope, and marks the notification read" do
      with_temp_doctype("nvokhp") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        account_id = create_test_account(db, email: "approver-#{unique_suffix}@example.com")
        notification = send_pending_notification(db, account_id, domain, doctype, doc_id)
        auth = auth_context(db, account_id, "iam.Roles.admin")

        outcome = Facet::Notification::InvokeAction.invoke_action(
          db, account_id, notification.id, "approve", auth,
        )

        # The envelope matches the direct action route's {data, meta} shape.
        outcome.result["data"]["status"].as_s.should eq("approved")
        outcome.result["meta"]["id"].as_s.should eq(doc_id)
        outcome.result["meta"]["mid"].as_s.should_not be_empty
        outcome.read_at.should be_close(Time.utc, 1.minute)

        # One-shot: the first successful action stamps actioned_at.
        outcome.actioned_at.should be_close(Time.utc, 1.minute)

        # Decision 10: a successful action always marks the notification read.
        Facet::Notification::List.unread_count(db, account_id).should eq(0)
      end
    end

    it "raises NotFound for an unknown id" do
      with_db do |db|
        account_id = create_test_account(db, email: "unknown-#{unique_suffix}@example.com")
        auth = auth_context(db, account_id, "iam.Roles.admin")

        expect_raises(Facet::Notification::InvokeAction::NotFound) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, Facet::Util::ScriptHelpers.ulid, "approve", auth,
          )
        end
      end
    end

    it "raises NotFound when the notification is owned by another account" do
      with_temp_doctype("nvokow") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        owner = create_test_account(db, email: "owner-#{unique_suffix}@example.com")
        other = create_test_account(db, email: "other-#{unique_suffix}@example.com")
        notification = send_pending_notification(db, owner, domain, doctype, doc_id)
        other_auth = auth_context(db, other, "iam.Roles.admin")

        expect_raises(Facet::Notification::InvokeAction::NotFound) do
          Facet::Notification::InvokeAction.invoke_action(
            db, other, notification.id, "approve", other_auth,
          )
        end

        # The row is untouched: still unread, still invocable by the owner.
        Facet::Notification::List.unread_count(db, owner).should eq(1)
        owner_auth = auth_context(db, owner, "iam.Roles.admin")
        Facet::Notification::InvokeAction.invoke_action(
          db, owner, notification.id, "approve", owner_auth,
        ).read_at.should_not be_nil
      end
    end

    it "raises UnknownAction when the key is absent from actions" do
      with_temp_doctype("nvokua") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        account_id = create_test_account(db, email: "ua-#{unique_suffix}@example.com")
        notification = send_pending_notification(db, account_id, domain, doctype, doc_id)
        auth = auth_context(db, account_id, "iam.Roles.admin")

        ex = expect_raises(Facet::Notification::InvokeAction::UnknownAction) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, notification.id, "nonexistent", auth,
          )
        end
        ex.status.should eq(422)
      end
    end

    it "raises UnknownAction for the reserved __read dismiss key" do
      with_temp_doctype("nvokrd") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        account_id = create_test_account(db, email: "rd-#{unique_suffix}@example.com")
        notification = send_pending_notification(db, account_id, domain, doctype, doc_id)
        auth = auth_context(db, account_id, "iam.Roles.admin")

        ex = expect_raises(Facet::Notification::InvokeAction::UnknownAction) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, notification.id, "__read", auth,
          )
        end
        ex.status.should eq(422)
        Facet::Notification::List.unread_count(db, account_id).should eq(1)
      end
    end

    it "raises RBAC::NotAuthorized when the recipient's role lacks the action permission" do
      with_temp_doctype("nvokrb") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        account_id = create_test_account(
          db,
          email: "viewer-#{unique_suffix}@example.com",
          roles: ["iam.Roles.viewer"],
          default_role: "iam.Roles.viewer",
        )
        notification = send_pending_notification(db, account_id, domain, doctype, doc_id)
        auth = auth_context(db, account_id, "iam.Roles.viewer")

        ex = expect_raises(Facet::RBAC::NotAuthorized) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, notification.id, "approve", auth,
          )
        end
        ex.status.should eq(403)

        # A denied action is not a dismissal.
        Facet::Notification::List.unread_count(db, account_id).should eq(1)
      end
    end

    it "consumes every action after the first successful one (AlreadyActioned, 409)" do
      with_temp_doctype("nvokrp") do |db, domain, doctype|
        ensure_domain(db, domain)
        register_action_doctype(db, domain, doctype)
        doc_id = create_leave_request(db, domain, doctype)
        account_id = create_test_account(db, email: "repeat-#{unique_suffix}@example.com")
        notification = send_pending_notification(db, account_id, domain, doctype, doc_id)
        auth = auth_context(db, account_id, "iam.Roles.admin")

        first = Facet::Notification::InvokeAction.invoke_action(
          db, account_id, notification.id, "approve", auth,
        )

        # A repeat of the same key — double-click, stale tab, replayed
        # request — is rejected, not dispatched twice.
        ex = expect_raises(Facet::Notification::InvokeAction::AlreadyActioned) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, notification.id, "approve", auth,
          )
        end
        ex.status.should eq(409)

        # One click consumes EVERY action on the notification — a second,
        # never-fired key is also dead.
        ex = expect_raises(Facet::Notification::InvokeAction::AlreadyActioned) do
          Facet::Notification::InvokeAction.invoke_action(
            db, account_id, notification.id, "reject", auth,
          )
        end
        ex.status.should eq(409)

        # The one-shot marker and the read mark are stable: the mutation
        # ran exactly once, and no timestamp moved on the rejected calls.
        items, _count, _more = Facet::Notification::List.list(db, account_id)
        items[0].actioned_at.should eq(first.actioned_at)
        items[0].read_at.should eq(first.read_at)
      end
    end

    it "raises ArgumentError on a blank account_id, id, or action key" do
      with_db do |db|
        account_id = create_test_account(db, email: "blank-#{unique_suffix}@example.com")
        auth = auth_context(db, account_id, "iam.Roles.admin")

        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::InvokeAction.invoke_action(db, "", Facet::Util::ScriptHelpers.ulid, "approve", auth)
        end
        expect_raises(ArgumentError, "id is required") do
          Facet::Notification::InvokeAction.invoke_action(db, account_id, "", "approve", auth)
        end
        expect_raises(ArgumentError, "action key is required") do
          Facet::Notification::InvokeAction.invoke_action(db, account_id, Facet::Util::ScriptHelpers.ulid, "", auth)
        end
      end
    end
  end
end
