# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../support/http_helper"
require "../support/webhook_helper"
require "../../src/webhook"
require "../../src/http/server"
require "../../src/jobs"
require "../../src/mutation/client"
require "../../src/rbac"

# Initialize HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# ── Helpers (file scope — Crystal does not allow defs inside describe) ──────

# Seeds the source doctype + document, one bound account + role, and the
# webhook. Returns {account_id, role_id}.
private def setup_webhook(db, webhook_id = "wh-log") : {String, String}
  seed_webhook_source(db)
  role_id = seed_role(db, "wh_reader", [{"action" => "read", "on" => "sales.Invoice"}])
  account_id = create_test_account(db, roles: [role_id], default_role: role_id)
  create_bound_webhook(db, webhook_id, "sales.Invoice", account_id, role_id)
  {account_id, role_id}
end

# Inserts one `webhook_delivery` job row with the payload shape the
# handler stamps, plus the matching `webhook_calls` row. `job_id` nil
# models a test probe (no parent job).
private def insert_call(db, webhook_id, call_id, *, job_id : String? = call_id, status = "pending",
                        event = "updated", url = "https://receiver.test/hook", http_status : Int32? = nil,
                        error : String? = nil, age_seconds : Int32 = 0) : Nil
  payload = JSON.parse({
    "webhook_id"  => webhook_id,
    "delivery_id" => job_id || call_id,
    "event"       => "updated",
    "domain"      => "sales",
    "doc_type"    => "Invoice",
    "doc_id"      => "inv-1",
    "mutation_id" => "mut-1",
    "actioner_id" => "act-1",
    "cause"       => nil,
    "content"     => {"id" => "inv-1", "total" => 100},
    "emitted_at"  => Time.utc.to_rfc3339,
    "url"         => url,
    "secret"      => "secret-key-123456",
    "headers"     => nil,
  }.to_json)

  if job_id
    Facet::Jobs::Queries.insert(db, job_id, "webhook_delivery", payload)
    if status != "pending"
      db.exec("UPDATE background_jobs SET status = $2 WHERE id = $1", job_id, status)
    end
  end

  db.exec(
    <<-SQL,
    INSERT INTO webhook_calls (id, webhook_id, job_id, event, source_doc_id, mutation_id,
                               attempt, status, http_status, error, response_body, duration_ms,
                               created_at, updated_at)
    VALUES ($1, $2, $3, $8, 'inv-1', 'mut-1', 1, $4, $5, $6, 'receiver body', 12,
            now() - ($7::int * interval '1 second'),
            now() - ($7::int * interval '1 second'))
  SQL
    call_id, webhook_id, job_id, status, http_status, error, age_seconds, event,
  )
end

# An auth context whose role can read `sales.Invoice` but has no
# permission on `core.Webhook` — the denial case for every route.
private def outsider_auth(db) : Facet::RBAC::AuthContext
  role_id = seed_role(db, "outsider", [{"action" => "read", "on" => "sales.Invoice"}])
  account_id = create_test_account(db, email: "outsider@example.com", roles: [role_id], default_role: role_id)
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

describe "Webhook call-log HTTP routes" do
  before_each do
    # `background_jobs` and `webhook_calls` are not in the global
    # truncation list; each spec cleans up its own rows. The manager is
    # installed in enqueue-only mode, so the replay endpoint's enqueue
    # inserts rows synchronously.
    with_db do |db|
      db.exec("DELETE FROM background_jobs")
      db.exec("DELETE FROM webhook_calls")
    end
    Facet::Jobs::Manager.instance = Facet::Jobs::Manager.new
  end

  after_each do
    Facet::Jobs::Manager.reset!
  end

  # ── Setup (helpers at file scope — Crystal does not allow defs inside
  #    describe blocks) ──────────────────────────────────────────────────

  it "lists calls newest first, paginated, scoped to the webhook" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1", age_seconds: 30)
      insert_call(db, "wh-log", "c-2", age_seconds: 20)
      insert_call(db, "wh-log", "c-3", age_seconds: 10)
      # A row for another webhook must not leak into this log.
      insert_call(db, "wh-other", "c-x", age_seconds: 5)

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls?items=2&page=1")
      response = call_api(request)
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["data"].as_a.size.should eq(2)
      json["data"][0]["id"].as_s.should eq("c-3")
      json["data"][1]["id"].as_s.should eq("c-2")
      json["meta"]["count"].as_i.should eq(3)
      # `more` means "counting was truncated": three rows fit under the cap.
      json["meta"]["more"].as_bool.should be_false

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls?items=2&page=2")
      response = call_api(request)
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["data"].as_a.size.should eq(1)
      json["data"][0]["id"].as_s.should eq("c-1")
      # Offset-relative: one call remains from page 2's offset.
      json["meta"]["count"].as_i.should eq(1)
      json["meta"]["more"].as_bool.should be_false
    end
  end

  it "filters calls by status" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1", status: "succeeded", http_status: 200, age_seconds: 30)
      insert_call(db, "wh-log", "c-2", status: "failed", http_status: 500, error: "boom", age_seconds: 20)
      insert_call(db, "wh-log", "c-3", status: "pending", age_seconds: 10)

      response = call_api(HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls?status=failed"))
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["data"].as_a.size.should eq(1)
      json["data"][0]["id"].as_s.should eq("c-2")
      json["meta"]["count"].as_i.should eq(1)
    end
  end

  it "rejects an unknown status filter with 422" do
    with_db do |db|
      setup_webhook(db)

      response = call_api(HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls?status=dead"))
      assert_http_status(response, 422)
    end
  end

  it "exposes the call fields, including the captured response body" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1", status: "failed", http_status: 500, error: "receiver exploded")

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls/c-1")
      response = call_api(request)
      assert_http_status(response, 200)

      json = JSON.parse(response.body)
      json["id"].as_s.should eq("c-1")
      json["webhook_id"].as_s.should eq("wh-log")
      json["job_id"].as_s.should eq("c-1")
      json["event"].as_s.should eq("updated")
      json["source_doc_id"].as_s.should eq("inv-1")
      json["mutation_id"].as_s.should eq("mut-1")
      json["attempt"].as_i.should eq(1)
      json["status"].as_s.should eq("failed")
      json["http_status"].as_i.should eq(500)
      json["error"].as_s.should eq("receiver exploded")
      json["response_body"].as_s.should eq("receiver body")
      json["duration_ms"].as_i.should eq(12)
      json["created_at"]?.should_not be_nil
      json["updated_at"]?.should_not be_nil

      # The signing secret never enters the call log, so it cannot echo here.
      response.body.should_not contain("secret-key-123456")
    end
  end

  it "returns 404 for a non-existent call" do
    with_db do |db|
      setup_webhook(db)

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls/c-missing")
      response = call_api(request)
      assert_http_status(response, 404)
    end
  end

  it "returns 404 for a call owned by another webhook" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-other", "c-1")

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls/c-1")
      response = call_api(request)
      assert_http_status(response, 404)
    end
  end

  it "denies a caller without read on core.Webhook with a non-disclosing 404" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1")
      ctx = outsider_auth(db)

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls")
      response = call_api_as(request, ctx)
      assert_http_status(response, 404)

      request = HTTP::Request.new("GET", "/Api/core/Webhook/wh-log/calls/c-1")
      response = call_api_as(request, ctx)
      assert_http_status(response, 404)
    end
  end

  # ── POST /calls/:id/replay ──────────────────────────────────────────

  it "replay through a call id re-runs the enqueue-time check and enqueues a fresh row" do
    with_db do |db|
      setup_webhook(db)
      # The original row was enqueued with a transport snapshot that has
      # since changed on the projection.
      insert_call(db, "wh-log", "c-1", job_id: "job-1", url: "https://stale.test/hook")
      original = Facet::Jobs::Queries.find(db, "job-1").not_nil!

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-1/replay")
      response = call_api(request)
      assert_http_status(response, 202)

      json = JSON.parse(response.body)
      json["call_id"].as_s.should eq("c-1")
      json["job_id"].as_s.should_not be_empty

      # Two job rows now: the original untouched, plus the replay.
      rows = db.query_all(
        "SELECT id, payload FROM background_jobs WHERE kind = 'webhook_delivery' ORDER BY created_at, id",
        as: {String, JSON::Any},
      )
      rows.size.should eq(2)

      original_row = rows.find! { |r| r[0] == "job-1" }
      # Original row untouched — same payload, stale url still in it.
      original_row[1]["url"].as_s.should eq("https://stale.test/hook")
      original_row[1]["delivery_id"].as_s.should eq("job-1")

      replayed_row = rows.find! { |r| r[0] != "job-1" }
      # Envelope fields replayed verbatim from the original…
      replayed_row[1]["event"].as_s.should eq("updated")
      replayed_row[1]["doc_id"].as_s.should eq("inv-1")
      replayed_row[1]["mutation_id"].as_s.should eq("mut-1")
      replayed_row[1]["emitted_at"].as_s.should eq(original.payload["emitted_at"].as_s)
      # …with a fresh delivery id and transport fields re-read from the
      # projection at replay time (decision 9).
      replayed_row[1]["url"].as_s.should eq("https://receiver.test/hook")
      replayed_row[1]["secret"].as_s.should eq("secret-key-123456")
    end
  end

  it "replay of a test probe (no parent job) returns 422" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1", job_id: nil, event: "test")

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-1/replay")
      response = call_api(request)
      assert_http_status(response, 422)

      JSON.parse(response.body)["error"].to_s.should contain("test probes are not replayable")
      count = db.query_one("SELECT count(*) FROM background_jobs", as: Int64)
      count.should eq(0)
    end
  end

  it "replay when the original job row is no longer retained returns 422" do
    with_db do |db|
      setup_webhook(db)
      # The call row survives, the parent job row does not (past the
      # retention prune).
      insert_call(db, "wh-log", "c-1")
      db.exec("DELETE FROM background_jobs WHERE id = 'c-1'")

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-1/replay")
      response = call_api(request)
      assert_http_status(response, 422)

      JSON.parse(response.body)["error"].to_s.should contain("no longer retained")
    end
  end

  it "replay with a revoked binding returns 422 naming the failed check, original rows untouched" do
    with_db do |db|
      account_id, _role_id = setup_webhook(db)
      insert_call(db, "wh-log", "c-1")

      # Revoke the bound role from the account.
      db.exec(
        "UPDATE projections SET content = jsonb_set(content, '{roles}', '[]') WHERE id = $1",
        account_id,
      )

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-1/replay")
      response = call_api(request)
      assert_http_status(response, 422)

      JSON.parse(response.body)["error"].to_s.should contain("bound role not assigned to account")

      # Original rows untouched.
      Facet::Jobs::Queries.find(db, "c-1").should_not be_nil
      Facet::Webhook::Calls.find(db, "wh-log", "c-1").should_not be_nil
      count = db.query_one("SELECT count(*) FROM background_jobs", as: Int64)
      count.should eq(1)
    end
  end

  it "replay of a non-existent call returns 404" do
    with_db do |db|
      setup_webhook(db)

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-missing/replay")
      response = call_api(request)
      assert_http_status(response, 404)
    end
  end

  it "replay denies a caller without update on core.Webhook with a non-disclosing 404" do
    with_db do |db|
      setup_webhook(db)
      insert_call(db, "wh-log", "c-1")
      ctx = outsider_auth(db)

      request = HTTP::Request.new("POST", "/Api/core/Webhook/wh-log/calls/c-1/replay")
      response = call_api_as(request, ctx)
      assert_http_status(response, 404)

      count = db.query_one("SELECT count(*) FROM background_jobs", as: Int64)
      count.should eq(1)
    end
  end
end
