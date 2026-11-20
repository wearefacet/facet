# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-53 reproduction: `notification.send` from a named action was reported
# as silently dropped through the HTTP action route, while the identical
# call in the create hook produced a row in the same run.
#
# The passing service spec (`spec/document/lua_notification_helpers_spec.cr`)
# calls `Document::Action.call` with no ambient transaction and with the
# system auth context. These examples close that gap at two levels:
#
# 1. Service level — `Document::Action.call` inside an ambient
#    `Database.with_transaction` with a real (non-system) auth context.
# 2. Full HTTP — the REST action route under a real principal, then the
#    reported read path: a real login, `GET /Api/notifications`, and
#    `GET /Api/notifications/unread_count` with the bearer token.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/notifications"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# ── Helpers ──────────────────────────────────────────────────────────────
#
# All helpers carry the `b53_` prefix — spec files compile into one binary,
# so top-level names must not collide with the other spec files (this file
# must also stay runnable on its own via
# `crystal spec spec/http/rest_action_notification_spec.cr`).

private def b53_script_action_only : String
  <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.change_email(ctx, args)
      ctx.root.email = args.email
      local ok, sent = pcall(notification.send,
        ctx.actor_id, nil, "email_changed", "Email changed",
        { body = "Your email was changed" })
      if not ok then ctx.error("notification failed: " .. tostring(sent)) end
    end
    return export
  LUA
end

# The harness's control setup: the IDENTICAL send in the create hook.
private def b53_script_with_create_hook : String
  <<-LUA
    local export = {}
    function export.create(ctx)
      local ok, sent = pcall(notification.send,
        ctx.actor_id, nil, "email_changed", "Email changed",
        { body = "Your email was changed" })
      if not ok then ctx.error("create notification failed: " .. tostring(sent)) end
    end
    function export.change_email(ctx, args)
      ctx.root.email = args.email
      local ok, sent = pcall(notification.send,
        ctx.actor_id, nil, "email_changed", "Email changed",
        { body = "Your email was changed" })
      if not ok then ctx.error("notification failed: " .. tostring(sent)) end
    end
    return export
  LUA
end

private def b53_register_doctype(db, domain : String, doctype : String, script : String) : Nil
  ensure_domain(db, domain)
  fields = %({"email": {"type": "string"}})
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
            "fields": #{fields},
            "actions": {"change_email": {"args": {"email": {"type": "string", "required": true}}}},
            "script": #{script.to_json}})
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  expect_create_success(result)
end

# A real (non-system) principal built the way production builds one: the
# account id plus the account's active role resolved from its projection.
private def b53_auth_context(db, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

describe "B-53 notification.send from a named action" do
  before_each do
    # `notifications` is not in the global truncate list — clear it here to
    # keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  it "drains the action queue inside an ambient transaction with a real auth context" do
    with_temp_doctype("notrest") do |db, domain, doctype|
      account_id = create_test_account(db, email: "b53-svc-#{unique_suffix}@example.com")
      b53_register_doctype(db, domain, doctype, b53_script_action_only)
      auth = b53_auth_context(db, account_id)

      proj = expect_create_success(
        Facet::Document::Create.call(db, domain, doctype, %({"email": "old@example.com"}), auth)
      ).projection

      # The conditions the HTTP action route adds: an ambient transaction
      # around the whole action and a non-system auth context.
      Facet::Database.with_transaction do |txn|
        result = Facet::Document::Action.call(txn, domain, doctype, proj.id, "change_email",
          %({"email": "new@example.com"}), auth)
        result.should be_a(Facet::Document::Action::Result)
      end

      row_account, kind = db.query_one(
        "SELECT account_id, kind FROM notifications",
        as: {String, String},
      )
      row_account.should eq(account_id)
      kind.should eq("email_changed")

      # The self-service read path sees the row too.
      items, count, _more = Facet::Notification::List.list(db, account_id)
      count.should eq(1)
      items.first.kind.should eq("email_changed")
      items.first.doc_id.should eq(proj.id)
    end
  end

  it "delivers the notification through the HTTP action route and the login read path" do
    with_temp_doctype("notrest") do |db, domain, doctype|
      admin_email = "b53-admin-#{unique_suffix}@example.com"
      account_id = create_test_account(db, email: admin_email)
      b53_register_doctype(db, domain, doctype, b53_script_with_create_hook)
      auth = b53_auth_context(db, account_id)

      # Real login first — the JWT `sub` is the read identity the harness
      # queried with.
      token = login_token(admin_email, "test-password")
      bearer = HTTP::Headers{"Authorization" => "Bearer #{token}"}

      # Create through the HTTP route under the real principal: the create
      # hook fires the identical send — the harness's control row.
      create_resp = call_api_as(
        HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: %({"email": "old@example.com"})),
        auth)
      assert_http_status(create_resp, 201)
      doc_id = JSON.parse(create_resp.body)["meta"]["id"].as_s

      create_rows = db.query_one("SELECT count(*) FROM notifications", as: Int64)
      create_rows.should eq(1) # control: the create hook drained over HTTP

      # The action through the REST route under the same principal.
      action_resp = call_api_as(
        HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/#{doc_id}/change_email",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: %({"email": "new@example.com"})),
        auth)
      assert_http_status(action_resp, 200)

      # The email updated — the action's mutation persisted.
      email_now = db.query_one(
        "SELECT content->>'email' FROM projections " \
        "WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        domain, doctype, doc_id, as: String)
      email_now.should eq("new@example.com")

      # The harness's read path: bearer-token list + unread badge. The list
      # runs on its own (read-only) connection, so it sees committed data.
      list_resp = call_api(HTTP::Request.new("GET", "/Api/notifications", headers: bearer))
      assert_http_status(list_resp, 200)
      list = JSON.parse(list_resp.body)
      list["meta"]["count"].as_i.should eq(2)
      list["data"].as_a.each do |item|
        item["account_id"].as_s.should eq(account_id)
        item["kind"].as_s.should eq("email_changed")
        item["doc_id"].as_s.should eq(doc_id)
      end

      unread_resp = call_api(HTTP::Request.new("GET", "/Api/notifications/unread_count", headers: bearer))
      assert_http_status(unread_resp, 200)
      JSON.parse(unread_resp.body)["count"].as_i.should eq(2)
    end
  end
end
