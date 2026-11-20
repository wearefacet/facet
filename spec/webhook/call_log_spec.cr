# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/webhook"

# ── Helpers (file scope — Crystal does not allow defs inside describe) ──────

private def build_job(job_id : String, webhook_id : String, attempt : Int32 = 1) : Facet::Jobs::Job
  payload = JSON.parse({
    "webhook_id"  => webhook_id,
    "delivery_id" => job_id,
    "event"       => "updated",
    "domain"      => "sales",
    "doc_type"    => "Invoice",
    "doc_id"      => "inv-1",
    "mutation_id" => "mut-1",
    "actioner_id" => "act-1",
    "cause"       => nil,
    "content"     => {"id" => "inv-1"},
    "emitted_at"  => Time.utc.to_rfc3339,
    "url"         => "https://receiver.test/hook",
    "secret"      => "secret-key-123456",
    "headers"     => nil,
  }.to_json)

  Facet::Jobs::Job.new(
    id: job_id,
    kind: "webhook_delivery",
    payload: payload,
    attempts: attempt,
    max_attempts: 5,
    backoff: nil,
  )
end

private def start_attempt(db, job_id : String, webhook_id : String = "wh-log", attempt : Int32 = 1) : Nil
  job = build_job(job_id, webhook_id, attempt)
  Facet::Webhook::Dispatcher.new.attempt_started(db, job, attempt)
end

private def call_row(db, job_id : String, attempt : Int32 = 1)
  db.query_one?(
    "SELECT webhook_id, job_id, event, source_doc_id, mutation_id, attempt, status,
            http_status, error, response_body, duration_ms
     FROM webhook_calls WHERE job_id = $1 AND attempt = $2",
    job_id, attempt,
  ) do |rs|
    {
      webhook_id:    rs.read(String),
      job_id:        rs.read(String?),
      event:         rs.read(String),
      source_doc_id: rs.read(String?),
      mutation_id:   rs.read(String?),
      attempt:       rs.read(Int32),
      status:        rs.read(String),
      http_status:   rs.read(Int32?),
      error:         rs.read(String?),
      response_body: rs.read(String?),
      duration_ms:   rs.read(Int32?),
    }
  end
end

# Webhook::Dispatcher — the call-log write side over `webhook_calls`
# (one row per outbound HTTP attempt: pending on claim, terminal on
# outcome). The hooks live on the handler itself.
describe Facet::Webhook::Dispatcher do
  before_each do
    # `webhook_calls` (like `background_jobs`) is not in the global
    # truncation list; each spec cleans up its own rows.
    with_db(&.exec("DELETE FROM webhook_calls"))
  end

  # ── attempt_started ──────────────────────────────────────────────────────

  it "inserts one pending row with the denormalized envelope identity" do
    with_db do |db|
      start_attempt(db, "job-1")

      row = call_row(db, "job-1").not_nil!
      row[:webhook_id].should eq("wh-log")
      row[:job_id].should eq("job-1")
      row[:event].should eq("updated")
      row[:source_doc_id].should eq("inv-1")
      row[:mutation_id].should eq("mut-1")
      row[:attempt].should eq(1)
      row[:status].should eq("pending")
      row[:http_status].should be_nil
      row[:error].should be_nil
      row[:response_body].should be_nil
    end
  end

  it "replaces a lingering pending row for the same job" do
    with_db do |db|
      start_attempt(db, "job-1")
      start_attempt(db, "job-1")

      attempts = db.query_all("SELECT attempt FROM webhook_calls WHERE job_id = 'job-1'", as: Int32)
      attempts.size.should eq(1)
    end
  end

  it "writes nothing for a payload without the mandatory identity fields" do
    with_db do |db|
      job = Facet::Jobs::Job.new(
        id: "job-broken",
        kind: "webhook_delivery",
        payload: JSON.parse(%({"n": 1})),
        attempts: 1,
        max_attempts: 5,
        backoff: nil,
      )
      Facet::Webhook::Dispatcher.new.attempt_started(db, job, 1)

      count = db.query_one("SELECT count(*) FROM webhook_calls", as: Int64)
      count.should eq(0)
    end
  end

  # ── attempt_finished ─────────────────────────────────────────────────────

  it "flips the pending row to succeeded with the captured outcome" do
    with_db do |db|
      start_attempt(db, "job-1")
      result = Facet::Jobs::Handler::Result.new(
        status: Facet::Jobs::Handler::Kind::Succeeded,
        http_status: 200,
        response_body: "ok",
        duration_ms: 42,
      )

      Facet::Webhook::Dispatcher.new.attempt_finished(db, "job-1", 1, result)

      row = call_row(db, "job-1").not_nil!
      row[:status].should eq("succeeded")
      row[:http_status].should eq(200)
      row[:response_body].should eq("ok")
      row[:duration_ms].should eq(42)
      row[:error].should be_nil
    end
  end

  it "flips the pending row to failed with the error" do
    with_db do |db|
      start_attempt(db, "job-1")
      result = Facet::Jobs::Handler::Result.new(
        status: Facet::Jobs::Handler::Kind::Failed,
        error: "receiver 500",
        http_status: 500,
        response_body: "boom",
        duration_ms: 7,
      )

      Facet::Webhook::Dispatcher.new.attempt_finished(db, "job-1", 1, result)

      row = call_row(db, "job-1").not_nil!
      row[:status].should eq("failed")
      row[:http_status].should eq(500)
      row[:error].should eq("receiver 500")
      row[:response_body].should eq("boom")
    end
  end

  it "is a no-op for a missing row or an already-terminal row" do
    with_db do |db|
      result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded, http_status: 200)
      log = Facet::Webhook::Dispatcher.new

      # Missing row: no raise, no insert.
      log.attempt_finished(db, "job-missing", 1, result)
      count = db.query_one("SELECT count(*) FROM webhook_calls", as: Int64)
      count.should eq(0)

      # Already-terminal row: the outcome is not overwritten.
      start_attempt(db, "job-1")
      log.attempt_finished(db, "job-1", 1, result)
      failed = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "late write")
      log.attempt_finished(db, "job-1", 1, failed)

      row = call_row(db, "job-1").not_nil!
      row[:status].should eq("succeeded")
      row[:error].should be_nil
    end
  end

  # ── attempt_abandoned ────────────────────────────────────────────────────

  it "marks pending rows failed with the lease-expired error" do
    with_db do |db|
      start_attempt(db, "job-1", attempt: 2)

      Facet::Webhook::Dispatcher.new.attempt_abandoned(db, "job-1")

      row = call_row(db, "job-1", 2).not_nil!
      row[:status].should eq("failed")
      row[:error].should eq("worker lease expired")
      row[:http_status].should be_nil
    end
  end

  # ── prune_expired ────────────────────────────────────────────────────────

  it "deletes only terminal rows past the retention horizon" do
    with_db do |db|
      log = Facet::Webhook::Dispatcher.new
      start_attempt(db, "old-succeeded")
      log.attempt_finished(db, "old-succeeded", 1,
        Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded, http_status: 200))

      start_attempt(db, "old-failed")
      log.attempt_finished(db, "old-failed", 1,
        Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "boom"))

      start_attempt(db, "old-pending")
      start_attempt(db, "recent-succeeded")
      log.attempt_finished(db, "recent-succeeded", 1,
        Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded, http_status: 200))

      db.exec("UPDATE webhook_calls SET updated_at = now() - interval '40 days'
               WHERE job_id IN ('old-succeeded', 'old-failed', 'old-pending')")

      pruned = log.prune_expired(db, 30)

      pruned.should eq(2)
      call_row(db, "old-succeeded").should be_nil
      call_row(db, "old-failed").should be_nil
      # Pending rows survive whatever their age; recent rows survive.
      call_row(db, "old-pending").not_nil![:status].should eq("pending")
      call_row(db, "recent-succeeded").should_not be_nil
    end
  end

  # ── record_test ──────────────────────────────────────────────────────────

  it "records a succeeded probe row: event test, no parent job, attempt 1" do
    with_db do |db|
      Facet::Webhook::Dispatcher.record_test(db, "wh-test",
        http_status: 200, error: nil, response_body: "ok", duration_ms: 12)

      row = db.query_one(
        "SELECT webhook_id, job_id, event, attempt, status, http_status, response_body, duration_ms
         FROM webhook_calls",
        as: {
          webhook_id:    String,
          job_id:        String?,
          event:         String,
          attempt:       Int32,
          status:        String,
          http_status:   Int32?,
          response_body: String?,
          duration_ms:   Int32?,
        })
      row[:webhook_id].should eq("wh-test")
      row[:job_id].should be_nil
      row[:event].should eq("test")
      row[:attempt].should eq(1)
      row[:status].should eq("succeeded")
      row[:http_status].should eq(200)
      row[:response_body].should eq("ok")
      row[:duration_ms].should eq(12)
    end
  end

  it "records a failed probe row on a non-2xx or transport error" do
    with_db do |db|
      Facet::Webhook::Dispatcher.record_test(db, "wh-test",
        http_status: 401, error: nil, response_body: "denied", duration_ms: 5)
      Facet::Webhook::Dispatcher.record_test(db, "wh-test",
        http_status: nil, error: "connect timeout", response_body: nil, duration_ms: nil)

      statuses = db.query_all(
        "SELECT status, error FROM webhook_calls ORDER BY created_at, id",
        as: {String, String?})
      statuses[0].should eq({"failed", nil})
      statuses[1].should eq({"failed", "connect timeout"})
    end
  end
end
