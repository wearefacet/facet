# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "openssl/hmac"
require "../support/http_helper"
require "../support/webhook_helper"
require "../../src/webhook"
require "../../src/http/server"

HTTPTest.init

# Test action (decision 10) — one inline outbound POST with a synthetic
# test envelope, observed end to end.
#
# The transport is stubbed by reopening `Webhook::Test` and replacing the
# `post` seam with a recording fake (the dispatcher spec reaches the same
# seam through a subclass; a module has no subclass, so the spec reopens
# the module instead — the last definition wins). No real network.
module Facet::Webhook::Test
  record Sent, uri : URI, body : String, headers : ::HTTP::Headers

  class_property next_response : ::HTTP::Client::Response = ::HTTP::Client::Response.new(200)
  class_property next_error : Exception? = nil
  class_getter sent : Array(Sent) = [] of Sent

  def self.post(uri : URI, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
    sent << Sent.new(uri, body, headers)
    if error = @@next_error
      raise error
    end
    @@next_response
  end

  def self.reset_transport : Nil
    @@sent = [] of Sent
    @@next_response = ::HTTP::Client::Response.new(200)
    @@next_error = nil
  end
end

TEST_SECRET = "secret-key-123456"

# ── Helpers (file scope — Crystal does not allow defs inside describe) ──────

# Seeds the source doctype + document, one account + role with `update` on
# `core.Webhook` (the test-action audience, decision 10), and the webhook.
private def setup_webhook(db, webhook_id = "wh-test", extra = "", secret = TEST_SECRET) : {String, String}
  seed_webhook_source(db)
  role_id = seed_role(db, "wh_tester", [{"action" => "update", "on" => "core.Webhook"}])
  account_id = create_test_account(db, roles: [role_id], default_role: role_id)
  create_bound_webhook(db, webhook_id, "sales.Invoice", account_id, role_id, extra, secret: secret)
  {account_id, role_id}
end

private def tester_auth(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

# An auth context without `update core.Webhook` — the denial case.
private def outsider_auth(db) : Facet::RBAC::AuthContext
  role_id = seed_role(db, "wh_outsider", [{"action" => "read", "on" => "sales.Invoice"}])
  account_id = create_test_account(db, email: "outsider@example.com", roles: [role_id], default_role: role_id)
  tester_auth(db, account_id, role_id)
end

describe "Webhook test action" do
  before_each do
    Facet::Webhook::Test.reset_transport
    with_db do |db|
      db.exec("DELETE FROM background_jobs")
      db.exec("DELETE FROM webhook_calls")
    end
  end

  it "delivers the synthetic envelope inline and answers 200 on a receiver 2xx" do
    with_db do |db|
      account_id, role_id = setup_webhook(db)
      Facet::Webhook::Test.next_response = HTTP::Client::Response.new(200, body: "ok")

      response = call_api_as(
        HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"),
        tester_auth(db, account_id, role_id),
      )
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["http_status"].as_i.should eq(200)
      json["response_body"].as_s.should eq("ok")
      json["transport_error"].raw.should be_nil
      json["duration_ms"].as_i.should be >= 0
      # signed_body rides as a JSON string — the exact bytes the transport
      # sent — so the test dialog can render it verbatim (B-79).
      json["signed_body"].as_s.should eq(Facet::Webhook::Test.sent.first.body)
    end
  end

  # ── Probe logging (decision 8) ──────────────────────────────────────

  it "logs the probe as a succeeded call row" do
    with_db do |db|
      account_id, role_id = setup_webhook(db)
      Facet::Webhook::Test.next_response = HTTP::Client::Response.new(200, body: "ok")

      response = call_api_as(
        HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"),
        tester_auth(db, account_id, role_id),
      )
      assert_http_status(response, 200)

      row = db.query_one(
        "SELECT webhook_id, job_id, event, attempt, status, http_status, error, response_body, duration_ms
         FROM webhook_calls",
        as: {
          webhook_id:    String,
          job_id:        String?,
          event:         String,
          attempt:       Int32,
          status:        String,
          http_status:   Int32?,
          error:         String?,
          response_body: String?,
          duration_ms:   Int32?,
        })
      row[:webhook_id].should eq("wh-test")
      row[:job_id].should be_nil
      row[:event].should eq("test")
      row[:attempt].should eq(1)
      row[:status].should eq("succeeded")
      row[:http_status].should eq(200)
      row[:error].should be_nil
      row[:response_body].should eq("ok")
      row[:duration_ms].should_not be_nil
    end
  end

  it "logs a failed call row when the receiver answers non-2xx" do
    with_db do |db|
      setup_webhook(db)
      Facet::Webhook::Test.next_response = HTTP::Client::Response.new(401, body: "denied")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      status, http_status, error = db.query_one(
        "SELECT status, http_status, error FROM webhook_calls",
        as: {String, Int32?, String?})
      status.should eq("failed")
      http_status.should eq(401)
      error.should be_nil
    end
  end

  it "logs a failed call row with the error on a transport failure" do
    with_db do |db|
      setup_webhook(db)
      Facet::Webhook::Test.next_error = IO::TimeoutError.new("connect timeout")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      status, http_status, error = db.query_one(
        "SELECT status, http_status, error FROM webhook_calls",
        as: {String, Int32?, String?})
      status.should eq("failed")
      http_status.should be_nil
      error.should eq("connect timeout")
    end
  end

  it "writes no call row for Facet-side rejections — no wire contact happened" do
    with_db do |db|
      setup_webhook(db, extra: ", \"enabled\": false")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 422)

      count = db.query_one("SELECT count(*) FROM webhook_calls", as: Int64)
      count.should eq(0)
    end
  end

  it "carries the decision-10 envelope shape and the X-Facet-Test header" do
    with_db do |db|
      account_id, role_id = setup_webhook(db)

      call_api_as(
        HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"),
        tester_auth(db, account_id, role_id),
      )

      sent = Facet::Webhook::Test.sent.first
      sent.uri.to_s.should eq("https://receiver.test/hook")
      sent.headers["X-Facet-Test"].should eq("true")

      envelope = JSON.parse(sent.body)
      envelope["webhook_id"].as_s.should eq("wh-test")
      envelope["delivery_id"].as_s.should start_with("test-")
      envelope["event"].as_s.should eq("test")
      envelope["domain"].as_s.should eq("core")
      envelope["doc_type"].as_s.should eq("Webhook")
      envelope["doc_id"].as_s.should eq("wh-test")
      envelope["mutation_id"].raw.should be_nil
      envelope["actioner_id"].as_s.should eq(account_id)
      envelope["cause"]["kind"].as_s.should eq("webhook_test")
      envelope["cause"]["name"].as_s.should eq("wh-test")
      envelope["cause"]["event"].as_s.should eq("test")
      envelope["content"]["id"].as_s.should eq("wh-test")
      envelope["content"]["test"].as_bool.should be_true
      envelope["emitted_at"].as_s.should_not be_empty
    end
  end

  it "returns the receiver's 4xx / 5xx as data, not a Facet error" do
    with_db do |db|
      setup_webhook(db)
      Facet::Webhook::Test.next_response = HTTP::Client::Response.new(401, body: "denied")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["http_status"].as_i.should eq(401)
      json["response_body"].as_s.should eq("denied")
      json["transport_error"].raw.should be_nil
    end
  end

  it "returns a transport error as data — http_status null, no raise" do
    with_db do |db|
      setup_webhook(db)
      Facet::Webhook::Test.next_error = IO::TimeoutError.new("connect timeout")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["http_status"].raw.should be_nil
      json["transport_error"].as_s.should eq("connect timeout")
    end
  end

  it "signs the test body with the webhook secret exactly like a real delivery" do
    with_db do |db|
      setup_webhook(db)

      call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))

      sent = Facet::Webhook::Test.sent.first
      expected = "sha256=" + OpenSSL::HMAC.hexdigest(:sha256, TEST_SECRET, sent.body)
      sent.headers["X-Facet-Signature"].should eq(expected)
    end
  end

  it "denies a caller without update on core.Webhook with 403" do
    with_db do |db|
      setup_webhook(db)

      response = call_api_as(
        HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"),
        outsider_auth(db),
      )
      assert_http_status(response, 403)
      Facet::Webhook::Test.sent.should be_empty
    end
  end

  it "returns 404 for a non-existent webhook" do
    with_db do
      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-missing/test"))
      assert_http_status(response, 404)
      Facet::Webhook::Test.sent.should be_empty
    end
  end

  it "returns 422 for a disabled webhook" do
    with_db do |db|
      setup_webhook(db, extra: ", \"enabled\": false")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 422)

      JSON.parse(response.body)["error"].to_s.should contain("disabled")
      Facet::Webhook::Test.sent.should be_empty
    end
  end

  it "returns 422 when the secret is missing" do
    with_db do |db|
      setup_webhook(db, secret: "")

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 422)

      JSON.parse(response.body)["error"].to_s.should contain("secret")
      Facet::Webhook::Test.sent.should be_empty
    end
  end

  it "merges custom headers but never lets them override X-Facet-*" do
    with_db do |db|
      custom = %(, "headers": {"X-Trace": "tier-1", "Content-Type": "application/vnd.facet.test+json", "X-Facet-Signature": "attacker"})
      setup_webhook(db, extra: custom)

      call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))

      sent = Facet::Webhook::Test.sent.first
      sent.headers["X-Trace"].should eq("tier-1")
      sent.headers["Content-Type"].should eq("application/vnd.facet.test+json")
      expected = "sha256=" + OpenSSL::HMAC.hexdigest(:sha256, TEST_SECRET, sent.body)
      sent.headers["X-Facet-Signature"].should eq(expected)
    end
  end

  it "truncates the response body above 4 KB" do
    with_db do |db|
      setup_webhook(db)
      big_body = "a" * 5000
      Facet::Webhook::Test.next_response = HTTP::Client::Response.new(200, body: big_body)

      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      body = JSON.parse(response.body)["response_body"].as_s
      body.should end_with("… [truncated]")
      body.bytesize.should eq(Facet::Webhook::Test::MAX_RESPONSE_BODY_BYTES + "… [truncated]".bytesize)
    end
  end

  it "uses the shared build_signed_request header set — only X-Facet-Test is added" do
    with_db do |db|
      setup_webhook(db)

      call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))

      sent = Facet::Webhook::Test.sent.first
      envelope = JSON.parse(sent.body)
      payload = Facet::Webhook::Payload.new(
        webhook_id: envelope["webhook_id"].as_s,
        delivery_id: envelope["delivery_id"].as_s,
        event: envelope["event"].as_s,
        domain: envelope["domain"].as_s,
        doc_type: envelope["doc_type"].as_s,
        doc_id: envelope["doc_id"].as_s,
        mutation_id: nil,
        actioner_id: envelope["actioner_id"].as_s,
        cause: envelope["cause"]?,
        content: envelope["content"],
        emitted_at: envelope["emitted_at"].as_s,
        url: sent.uri.to_s,
        secret: TEST_SECRET,
        headers: nil,
      )
      _body, shared_headers = Facet::Webhook::Dispatcher.build_signed_request(payload)

      shared_headers.each do |name, values|
        sent.headers[name].should eq(values.join(", "))
      end
      (sent.headers.to_a.map(&.first) - shared_headers.to_a.map(&.first)).should eq(["X-Facet-Test"])
    end
  end

  it "creates no background_jobs row" do
    with_db do |db|
      setup_webhook(db)

      count_before = db.query_one("SELECT count(*) FROM background_jobs", as: Int64)
      response = call_api(HTTP::Request.new("POST", "/Api/core/Webhook/wh-test/test"))
      assert_http_status(response, 200)

      count_after = db.query_one("SELECT count(*) FROM background_jobs", as: Int64)
      count_after.should eq(count_before)
      count_after.should eq(0)
    end
  end
end
