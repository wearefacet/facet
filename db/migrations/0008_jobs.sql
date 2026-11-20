-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Background job queue and the outbound webhook call log.
--
-- Operational tables, not domain documents: no triggers, no deleted_at,
-- no RBAC. Not event-sourced.
--
--   1. `background_jobs` — one row = one unit of work (e.g. one webhook
--      call). The retry scheduler lives here.
--   2. `webhook_calls` — one row per outbound webhook HTTP attempt. The
--      debug log; delivery is queued through `background_jobs`.
--
-- Each section maps to one former migration file; the DOWN section
-- reverses the sections in dependency order.

-- UP

-- ---------------------------------------------------------------------------
-- 1. background_jobs
-- ---------------------------------------------------------------------------

-- Status state machine: pending | running | succeeded | failed. No 'dead'.
--   pending  -> running   (claim; attempts incremented on claim, not outcome)
--   running  -> pending   (failure with attempts left; lease sweep)
--   running  -> succeeded (outcome)
--   running  -> failed    (outcome; attempts >= max_attempts)
--
-- backoff_seconds is the per-attempt delay list, indexed by the attempt
-- that failed. NULL means "retry immediately" (caller did not set a policy).
-- run_after is NULL only on terminal rows (succeeded / failed); the plan's
-- outcome writes set it to NULL, so it must be nullable.
--
-- last_error / last_http_status carry the transport-level debug capture of
-- the last attempt. result is the terminal outcome payload a handler
-- returns for its caller (e.g. an export job's {artifact_id, row_count,
-- format}): the status route reads it while the row is terminal, and it
-- stays NULL while the row is pending/running. Not access-bearing — the
-- route gates the read on the requesting account carried in the payload.
--
-- lease_ttl_s is the per-row lease horizon. The worker's lease_ttl_s is one
-- value per worker (default 60 s), and the lease sweep is the only mechanism
-- that notices a dead worker. A long job (a document import or export)
-- always outlives that default, so a healthy, still-running row would be
-- requeued mid-flight. A nullable column lets a caller set a generous,
-- per-row horizon at enqueue time; NULL keeps the worker default. No
-- infinite leases — a finite horizon is what turns a crashed job into a
-- clean re-execution. See doc/backend/jobs.md and the import/export plan
-- (§6.9).
CREATE TABLE background_jobs (
  id              TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,
  payload         JSONB NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending',
  attempts        INT  NOT NULL DEFAULT 0,
  max_attempts    INT  NOT NULL DEFAULT 5,
  backoff_seconds INT[],
  lease_ttl_s     INT,
  run_after       TIMESTAMPTZ DEFAULT now(),
  locked_by       TEXT,
  locked_until    TIMESTAMPTZ,
  last_error      TEXT,
  last_http_status INT,
  result          JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Claim path: due pending rows, ordered by run_after.
CREATE INDEX idx_background_jobs_claim
  ON background_jobs (run_after)
  WHERE status = 'pending';

-- Prune path: terminal rows past the retention horizon.
CREATE INDEX idx_background_jobs_prune
  ON background_jobs (status, updated_at)
  WHERE status IN ('succeeded', 'failed');

-- ---------------------------------------------------------------------------
-- 2. webhook_calls
-- ---------------------------------------------------------------------------

-- Status vocabulary mirrors the queue: pending | succeeded | failed.
-- No 'dead' state — a call that ends with no outcome (worker crash) is
-- marked failed by the lease-loss sweep.
--
-- job_id is NULL for test probes (Webhook::Test), which are logged with
-- event = 'test'.
CREATE TABLE webhook_calls (
  id            TEXT PRIMARY KEY,
  webhook_id    TEXT NOT NULL,
  job_id        TEXT,
  event         TEXT NOT NULL,
  source_doc_id TEXT,
  mutation_id   TEXT,
  attempt       INT  NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'succeeded', 'failed')),
  http_status   INT,
  error         TEXT,
  response_body TEXT,
  duration_ms   INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The log query: newest first per webhook.
CREATE INDEX idx_webhook_calls_log
  ON webhook_calls (webhook_id, updated_at DESC, id DESC);

-- The debug filter: failed calls only, same ordering.
CREATE INDEX idx_webhook_calls_failed
  ON webhook_calls (webhook_id, updated_at DESC)
  WHERE status = 'failed';

-- Call → parent job resolution (replay, lease-loss sweep).
CREATE INDEX idx_webhook_calls_job ON webhook_calls (job_id);

-- Prune path: terminal rows past the retention horizon.
CREATE INDEX idx_webhook_calls_prune
  ON webhook_calls (updated_at)
  WHERE status IN ('succeeded', 'failed');

-- DOWN

-- 2. webhook_calls
DROP TABLE IF EXISTS webhook_calls;

-- 1. background_jobs
DROP TABLE IF EXISTS background_jobs;
