# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/webhook"

# ── Helpers (file scope — Crystal does not allow defs inside describe) ──────

private def insert_call(db, call_id : String, webhook_id : String = "wh-log", *,
                        status : String = "pending", job_id : String? = "job-1",
                        event : String = "updated", http_status : Int32? = nil,
                        error : String? = nil, age_seconds : Int32 = 0) : Nil
  db.exec(
    <<-SQL,
    INSERT INTO webhook_calls (id, webhook_id, job_id, event, source_doc_id, mutation_id,
                               attempt, status, http_status, error, response_body, duration_ms,
                               created_at, updated_at)
    VALUES ($1, $2, $3, $4, 'inv-1', 'mut-1', 1, $5, $6, $7, 'body', 12,
            now() - ($8::int * interval '1 second'),
            now() - ($8::int * interval '1 second'))
  SQL
    call_id, webhook_id, job_id, event, status, http_status, error, age_seconds,
  )
end

# Webhook::Calls — the read side over `webhook_calls`: newest first per
# webhook, paginated, optional status filter, webhook-scoped find.
describe Facet::Webhook::Calls do
  before_each do
    # `webhook_calls` (like `background_jobs`) is not in the global
    # truncation list; each spec cleans up its own rows.
    with_db(&.exec("DELETE FROM webhook_calls"))
  end

  # ── list ─────────────────────────────────────────────────────────────────

  it "lists rows newest first, paginated, scoped to the webhook" do
    with_db do |db|
      insert_call(db, "c-1", age_seconds: 30)
      insert_call(db, "c-2", age_seconds: 20)
      insert_call(db, "c-3", age_seconds: 10)
      # A row for another webhook must not leak into this log.
      insert_call(db, "c-x", "wh-other", age_seconds: 5)

      calls, total = Facet::Webhook::Calls.list(db, "wh-log", nil, 1, 2)

      total.should eq(3)
      calls.size.should eq(2)
      calls.map(&.id).should eq(["c-3", "c-2"])
      calls.first.event.should eq("updated")

      calls, total = Facet::Webhook::Calls.list(db, "wh-log", nil, 2, 2)

      # Offset-relative (B-297): one row remains from page 2's offset.
      total.should eq(1)
      calls.map(&.id).should eq(["c-1"])
    end
  end

  it "orders same-instant rows by id descending" do
    with_db do |db|
      insert_call(db, "c-a", age_seconds: 10)
      insert_call(db, "c-b", age_seconds: 10)

      calls, _total = Facet::Webhook::Calls.list(db, "wh-log", nil, 1, 10)
      calls.map(&.id).should eq(["c-b", "c-a"])
    end
  end

  it "applies the status filter to rows and count" do
    with_db do |db|
      insert_call(db, "c-1", status: "succeeded", http_status: 200)
      insert_call(db, "c-2", status: "failed", http_status: 500, error: "boom", age_seconds: 20)
      insert_call(db, "c-3", status: "failed", http_status: 502, error: "bad gateway", age_seconds: 10)
      insert_call(db, "c-4", status: "pending")

      calls, total = Facet::Webhook::Calls.list(db, "wh-log", "failed", 1, 10)

      total.should eq(2)
      calls.map(&.id).should eq(["c-3", "c-2"])
      calls.first.error.should eq("bad gateway")

      calls, total = Facet::Webhook::Calls.list(db, "wh-log", "pending", 1, 10)
      total.should eq(1)
      calls.map(&.id).should eq(["c-4"])
    end
  end

  # ── find ─────────────────────────────────────────────────────────────────

  it "finds one row by id" do
    with_db do |db|
      insert_call(db, "c-1", job_id: "job-9", status: "succeeded", http_status: 200)

      call = Facet::Webhook::Calls.find(db, "wh-log", "c-1").not_nil!

      call.id.should eq("c-1")
      call.webhook_id.should eq("wh-log")
      call.job_id.should eq("job-9")
      call.source_doc_id.should eq("inv-1")
      call.mutation_id.should eq("mut-1")
      call.attempt.should eq(1)
      call.status.should eq("succeeded")
      call.http_status.should eq(200)
      call.response_body.should eq("body")
      call.duration_ms.should eq(12)
      call.created_at.should be_a(Time)
    end
  end

  it "returns nil for a missing row or another webhook's row" do
    with_db do |db|
      insert_call(db, "c-1", "wh-other")

      Facet::Webhook::Calls.find(db, "wh-log", "c-1").should be_nil
      Facet::Webhook::Calls.find(db, "wh-log", "c-missing").should be_nil
    end
  end
end
