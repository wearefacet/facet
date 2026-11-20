# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/notifications"
require "../../src/iam"
require "../../src/http/server"
require "../support/iam_helper"
require "../support/http_helper"

# Register the notification routes and build the shared handler chain.
# `Routes.register` is guarded and `HTTPTest.init` is idempotent, so the
# order in which spec files load does not matter.
Facet::Notification::Routes.register
HTTPTest.init

private def routes_auth_cookie(account_id : String) : HTTP::Headers
  pem_key = Facet::IAM::TokenEmitter.signing_key
  payload, _exp = Facet::IAM::JWT.build_access_payload(account_id, "fake-sid", "admin")
  token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")
  HTTP::Headers{"Cookie" => "auth_token=#{token}"}
end

# POST routes carry the X-Requested-With header (CSRF defense) on top of
# the auth cookie.
private def routes_post_cookie(account_id : String) : HTTP::Headers
  headers = routes_auth_cookie(account_id)
  headers["X-Requested-With"] = "XMLHttpRequest"
  headers
end

private def routes_auth_context(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

private def routes_send(
  db,
  account_id : String,
  kind : String,
  title : String = "Title",
  domain : String = "hr",
  doctype : String = "LeaveRequest",
  doc_id : String = Facet::Util::ScriptHelpers.ulid,
  actions : Array(Facet::Notification::Action) = [] of Facet::Notification::Action,
)
  Facet::Notification::Send.send(
    db, account_id, domain, doctype, doc_id, kind, title, actions: actions)
end

private def routes_action_doctype(db, domain : String, doctype : String) : Nil
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
  actions = %({"approve": {"args": {}}})
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "display_name": "{{ title }}", "fields": #{fields},
            "actions": #{actions}, "script": #{script.to_json}})
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
end

private def routes_create_leave(db, domain : String, doctype : String) : String
  result = Facet::Document::Create.call(
    db, domain, doctype,
    %({"title": "Summer leave", "status": "pending"}),
    Facet::RBAC::AuthContext.system,
  )
  expect_create_success(result).projection.id
end

describe "Notifications HTTP routes" do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  after_each { Fiber.current.auth_context = nil }

  describe "authentication" do
    it "returns 401 without a token" do
      headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      [
        {"GET", "/Api/notifications"},
        {"GET", "/Api/notifications/unread_count"},
        {"POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/read"},
        {"POST", "/Api/notifications/read_all"},
        {"POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/actions/approve"},
      ].each do |method, path|
        response = call_api(HTTP::Request.new(method, path, headers: headers))
        assert_http_status(response, 401)
        JSON.parse(response.body)["error"].to_s.should contain("Authentication")
      end
    end
  end

  describe "CSRF defense" do
    it "returns 403 on POST routes when X-Requested-With is missing" do
      with_db do |db|
        account_id = create_test_account(db)
        [
          {"POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/read"},
          {"POST", "/Api/notifications/read_all"},
          {"POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/actions/approve"},
        ].each do |method, path|
          # Raw dispatch — `call_api` would add the browser default header
          # and mask the missing-header negative path.
          response = call_api_raw(HTTP::Request.new(method, path, headers: routes_auth_cookie(account_id)))
          assert_http_status(response, 403)
          JSON.parse(response.body)["error"].to_s.should contain("CSRF")
        end
      end
    end
  end

  describe "GET /Api/notifications" do
    it "returns the account's notifications newest-first" do
      with_db do |db|
        account_id = create_test_account(db)
        routes_send(db, account_id, "a")
        routes_send(db, account_id, "b")
        routes_send(db, account_id, "c")

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications", headers: routes_auth_cookie(account_id)))

        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["data"].as_a.map(&.["kind"].as_s).should eq(["c", "b", "a"])
        json["meta"]["count"].as_i.should eq(3)
        json["meta"]["more"].as_bool.should be_false

        first = json["data"][0]
        first["id"].as_s.should_not be_empty
        first["account_id"].as_s.should eq(account_id)
        first["domain"].as_s.should eq("hr")
        first["read_at"].raw.should be_nil
        first["actioned_at"].raw.should be_nil
        first["created_at"].as_s.should_not be_empty
      end
    end

    it "filters with ?unread=true" do
      with_db do |db|
        account_id = create_test_account(db)
        read_one = routes_send(db, account_id, "a")
        routes_send(db, account_id, "b")
        Facet::Notification::MarkRead.mark_read(db, account_id, read_one.id)

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications?unread=true", headers: routes_auth_cookie(account_id)))

        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["meta"]["count"].as_i.should eq(1)
        json["data"][0]["kind"].as_s.should eq("b")
      end
    end

    it "filters with ?kind=" do
      with_db do |db|
        account_id = create_test_account(db)
        routes_send(db, account_id, "leave_pending")
        routes_send(db, account_id, "mention")

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications?kind=mention", headers: routes_auth_cookie(account_id)))

        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["meta"]["count"].as_i.should eq(1)
        json["data"][0]["kind"].as_s.should eq("mention")
      end
    end

    it "paginates with page/per_page and the more flag" do
      with_db do |db|
        account_id = create_test_account(db)
        routes_send(db, account_id, "a")
        routes_send(db, account_id, "b")
        routes_send(db, account_id, "c")

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications?page=1&per_page=2", headers: routes_auth_cookie(account_id)))
        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        # `count` is the real number from this page's offset; three rows fit
        # under the cap, so `more` stays false.
        json["meta"]["count"].as_i.should eq(3)
        json["meta"]["more"].as_bool.should be_false
        json["data"].as_a.map(&.["kind"].as_s).should eq(["c", "b"])

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications?page=2&per_page=2", headers: routes_auth_cookie(account_id)))
        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["meta"]["count"].as_i.should eq(1)
        json["meta"]["more"].as_bool.should be_false
        json["data"][0]["kind"].as_s.should eq("a")
      end
    end

    it "only lists the caller's own notifications" do
      with_db do |db|
        owner = create_test_account(db, email: "route-own-#{unique_suffix}@example.com")
        other = create_test_account(db, email: "route-other-#{unique_suffix}@example.com")
        routes_send(db, owner, "a")
        routes_send(db, owner, "b")

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications", headers: routes_auth_cookie(other)))
        assert_http_status(response, 200)
        JSON.parse(response.body)["meta"]["count"].as_i.should eq(0)

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications", headers: routes_auth_cookie(owner)))
        assert_http_status(response, 200)
        JSON.parse(response.body)["meta"]["count"].as_i.should eq(2)
      end
    end
  end

  describe "GET /Api/notifications/unread_count" do
    it "returns the unread badge count" do
      with_db do |db|
        account_id = create_test_account(db)
        read_one = routes_send(db, account_id, "a")
        routes_send(db, account_id, "b")
        routes_send(db, account_id, "c")
        Facet::Notification::MarkRead.mark_read(db, account_id, read_one.id)

        response = call_api(HTTP::Request.new(
          "GET", "/Api/notifications/unread_count", headers: routes_auth_cookie(account_id)))

        assert_http_status(response, 200)
        JSON.parse(response.body)["count"].as_i.should eq(2)
      end
    end
  end

  describe "POST /Api/notifications/:id/read" do
    it "marks one notification read" do
      with_db do |db|
        account_id = create_test_account(db)
        notification = routes_send(db, account_id, "a")
        headers = routes_post_cookie(account_id)

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/read", headers: headers))
        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["id"].as_s.should eq(notification.id)
        read_at = json["read_at"].as_s
        read_at.should_not be_empty

        # Idempotent: a re-mark stays 200 and keeps the first read_at.
        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/read", headers: headers))
        assert_http_status(response, 200)
        JSON.parse(response.body)["read_at"].as_s.should eq(read_at)

        Facet::Notification::List.unread_count(db, account_id).should eq(0)
      end
    end

    it "returns 404 for an unknown id" do
      with_db do |db|
        account_id = create_test_account(db)

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/read",
          headers: routes_post_cookie(account_id)))

        assert_http_status(response, 404)
        JSON.parse(response.body)["error"].to_s.should contain("Not found")
      end
    end

    it "does not let another account mark the notification" do
      with_db do |db|
        owner = create_test_account(db, email: "route-own-#{unique_suffix}@example.com")
        other = create_test_account(db, email: "route-mrk-#{unique_suffix}@example.com")
        notification = routes_send(db, owner, "a")

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/read",
          headers: routes_post_cookie(other)))
        assert_http_status(response, 404)

        # The row is untouched: still unread, still dismissible by the owner.
        Facet::Notification::List.unread_count(db, owner).should eq(1)
        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/read",
          headers: routes_post_cookie(owner)))
        assert_http_status(response, 200)
      end
    end
  end

  describe "POST /Api/notifications/read_all" do
    it "marks every unread notification read" do
      with_db do |db|
        account_id = create_test_account(db)
        3.times { routes_send(db, account_id, "a") }
        headers = routes_post_cookie(account_id)

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/read_all", headers: headers))
        assert_http_status(response, 200)
        JSON.parse(response.body)["marked"].as_i.should eq(3)

        # Idempotent: a second call marks nothing.
        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/read_all", headers: headers))
        assert_http_status(response, 200)
        JSON.parse(response.body)["marked"].as_i.should eq(0)
      end
    end

    it "does not touch another account's notifications" do
      with_db do |db|
        owner = create_test_account(db, email: "route-own-#{unique_suffix}@example.com")
        other = create_test_account(db, email: "route-all-#{unique_suffix}@example.com")
        2.times { routes_send(db, owner, "a") }
        routes_send(db, other, "b")

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/read_all", headers: routes_post_cookie(owner)))
        assert_http_status(response, 200)
        JSON.parse(response.body)["marked"].as_i.should eq(2)

        Facet::Notification::List.unread_count(db, owner).should eq(0)
        Facet::Notification::List.unread_count(db, other).should eq(1)
      end
    end
  end

  describe "POST /Api/notifications/:id/actions/:key" do
    it "dispatches the action and returns the envelope plus read_at" do
      with_temp_doctype("nvrte") do |db, domain, doctype|
        routes_action_doctype(db, domain, doctype)
        doc_id = routes_create_leave(db, domain, doctype)
        account_id = create_test_account(db, email: "route-act-#{unique_suffix}@example.com")
        notification = routes_send(db, account_id, "leave_pending",
          domain: domain, doctype: doctype, doc_id: doc_id,
          actions: [Facet::Notification::Action.new(key: "approve", label: "Approve", variant: "primary")])

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/approve",
          headers: routes_post_cookie(account_id)))

        assert_http_status(response, 200)
        json = JSON.parse(response.body)
        json["result"]["data"]["status"].as_s.should eq("approved")
        json["result"]["meta"]["id"].as_s.should eq(doc_id)
        json["result"]["meta"]["mid"].as_s.should_not be_empty
        json["read_at"].as_s.should_not be_empty
        json["actioned_at"].as_s.should_not be_empty

        # Decision 10: a successful action marks the notification read.
        Facet::Notification::List.unread_count(db, account_id).should eq(0)

        # One-shot: the actions are consumed — a repeat click is 409, and
        # the list payload exposes the marker for the UI to disable buttons.
        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/approve",
          headers: routes_post_cookie(account_id)))
        assert_http_status(response, 409)

        response = call_api(HTTP::Request.new("GET", "/Api/notifications",
          headers: routes_auth_cookie(account_id)))
        assert_http_status(response, 200)
        first = JSON.parse(response.body)["data"].as_a[0]
        first["actioned_at"].as_s.should_not be_empty
      end
    end

    it "returns 404 for an unknown id" do
      with_db do |db|
        account_id = create_test_account(db)

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{Facet::Util::ScriptHelpers.ulid}/actions/approve",
          headers: routes_post_cookie(account_id)))

        assert_http_status(response, 404)
      end
    end

    it "returns 404 when the notification belongs to another account" do
      with_temp_doctype("nvrto") do |db, domain, doctype|
        routes_action_doctype(db, domain, doctype)
        doc_id = routes_create_leave(db, domain, doctype)
        owner = create_test_account(db, email: "route-own-#{unique_suffix}@example.com")
        other = create_test_account(db, email: "route-inv-#{unique_suffix}@example.com")
        notification = routes_send(db, owner, "leave_pending",
          domain: domain, doctype: doctype, doc_id: doc_id,
          actions: [Facet::Notification::Action.new(key: "approve", label: "Approve")])

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/approve",
          headers: routes_post_cookie(other)))
        assert_http_status(response, 404)

        # The row is untouched: still unread, still invocable by the owner.
        Facet::Notification::List.unread_count(db, owner).should eq(1)
      end
    end

    it "returns 422 for an unknown action key" do
      with_temp_doctype("nvrtk") do |db, domain, doctype|
        routes_action_doctype(db, domain, doctype)
        doc_id = routes_create_leave(db, domain, doctype)
        account_id = create_test_account(db, email: "route-key-#{unique_suffix}@example.com")
        notification = routes_send(db, account_id, "leave_pending",
          domain: domain, doctype: doctype, doc_id: doc_id,
          actions: [Facet::Notification::Action.new(key: "approve", label: "Approve")])

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/nonexistent",
          headers: routes_post_cookie(account_id)))

        assert_http_status(response, 422)
        JSON.parse(response.body)["error"].to_s.should contain("nonexistent")
      end
    end

    it "returns 422 for the reserved __read key" do
      with_temp_doctype("nvrtr") do |db, domain, doctype|
        routes_action_doctype(db, domain, doctype)
        doc_id = routes_create_leave(db, domain, doctype)
        account_id = create_test_account(db, email: "route-rsrv-#{unique_suffix}@example.com")
        notification = routes_send(db, account_id, "leave_pending",
          domain: domain, doctype: doctype, doc_id: doc_id,
          actions: [Facet::Notification::Action.new(key: "approve", label: "Approve")])

        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/__read",
          headers: routes_post_cookie(account_id)))
        assert_http_status(response, 422)

        # `__read` is the dismiss control: dismissal goes through
        # POST /Api/notifications/:id/read, which works for this row.
        response = call_api(HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/read",
          headers: routes_post_cookie(account_id)))
        assert_http_status(response, 200)
      end
    end

    it "returns 403 when the recipient's role lacks the action permission" do
      with_temp_doctype("nvrtb") do |db, domain, doctype|
        routes_action_doctype(db, domain, doctype)
        doc_id = routes_create_leave(db, domain, doctype)
        account_id = create_test_account(db,
          email: "route-viewer-#{unique_suffix}@example.com",
          roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        notification = routes_send(db, account_id, "leave_pending",
          domain: domain, doctype: doctype, doc_id: doc_id,
          actions: [Facet::Notification::Action.new(key: "approve", label: "Approve")])

        request = HTTP::Request.new(
          "POST", "/Api/notifications/#{notification.id}/actions/approve",
          headers: routes_post_cookie(account_id))
        response = call_api_as(request, routes_auth_context(db, account_id, "iam.Roles.viewer"))

        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].to_s.should contain("Forbidden")

        # A denied action does not dismiss the notification.
        Facet::Notification::List.unread_count(db, account_id).should eq(1)
      end
    end
  end
end
