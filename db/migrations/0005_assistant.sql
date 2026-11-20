-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Assistant storage (LLM conversation sessions + per-account token ledger).
--
-- Three side tables for the `Facet::Assistant` subsystem; none of them are
-- event-sourced domain documents (same precedent as `notifications`,
-- db/migrations/0009_notifications.sql):
--
--   1. `agent_conversations` — one row per Agent session. Holds the stable
--      identity (session_id, cache_key) and a snapshot of the config that
--      produced the conversation, so that a session can be reconstructed
--      byte-for-byte for replay (and KV cache hits).
--   2. `agent_turns` — one row per Agent#ask invocation.
--   3. `assistant_usage` — per-account token usage ledger, one row per
--      billed turn, written by Stream::Session at every terminal path. It
--      survives conversation deletion, so it carries no foreign keys
--      (unlike agent_turns, which is cascade-deleted with its
--      conversation). Rows whose counts the provider never reported on
--      (cancelled turns) are estimates, marked by `estimated`.
--
-- `cache_key` (the OpenAI prompt_cache_key) is kept stable across all turns
-- of the same conversation: the provider hashes cache_key + message prefix
-- to hit its KV cache, so changing either invalidates the cache.
--
-- Timezone rule (project-wide): every timestamp column is `timestamp`
-- (without time zone) and stores UTC. The PG session `TimeZone` is pinned
-- to UTC at `Database.init`, so `now()` defaults are UTC. Do NOT use
-- `timestamptz` here. See `doc/backend/workflow.md` → Time / Timezone.
-- UP

-- ---------------------------------------------------------------------------
-- 1. agent_conversations
-- ---------------------------------------------------------------------------
CREATE TABLE agent_conversations (
    id              text        PRIMARY KEY DEFAULT ulid(),
    session_id      text        NOT NULL,
    cache_key       text        NOT NULL,
    model           text        NOT NULL,
    system_prompt   text,
    config          jsonb       NOT NULL DEFAULT '{}'::jsonb,
    context         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    enabled_tools   jsonb       NOT NULL DEFAULT '[]'::jsonb,
    created_at      timestamp   NOT NULL DEFAULT now(),
    updated_at      timestamp   NOT NULL DEFAULT now()
);

CREATE INDEX idx_agent_conversations_session ON agent_conversations (session_id);

-- ---------------------------------------------------------------------------
-- 2. agent_turns
--
-- The exact input/output message sequence is stored as JSONB so that
-- concatenating turns in idx order reproduces the agent's full history
-- array — the same array Agent#dump would emit — which is what Agent#load
-- consumes to resume a session.
--
-- Intermediate HTTP iterations inside a single turn's tool loop are NOT stored
-- separately: the final message sequence for the turn is deterministic from the
-- tool definitions + the model output, and replaying the flat history is
-- sufficient to keep the provider KV cache hot.
--
-- `status` is the turn lifecycle. The row is written at turn START
-- (`running`, request messages only) and updated at the exit path
-- (`done` / `error` / `cancelled`). The running row makes an in-flight turn
-- observable: the concurrent-stream guard (409) and the catch-up poll both
-- read it. A stale `running` row is dead evidence of an interrupted process
-- — `Cron::AssistantTurnSweep` marks it `error` with message `interrupted`.
-- The partial unique index enforces at most one running turn per
-- conversation, so the read-then-open race is decided by the database.
-- ---------------------------------------------------------------------------
CREATE TABLE agent_turns (
    id                text        PRIMARY KEY DEFAULT ulid(),
    conversation_id   text        NOT NULL REFERENCES agent_conversations(id) ON DELETE CASCADE,
    idx               integer     NOT NULL,
    request_messages  jsonb       NOT NULL DEFAULT '[]'::jsonb,
    response_messages jsonb       NOT NULL DEFAULT '[]'::jsonb,
    status            text        NOT NULL DEFAULT 'done',
    usage             jsonb       NOT NULL DEFAULT '{}'::jsonb,
    finish_reason     text,
    error             text,
    created_at        timestamp   NOT NULL DEFAULT now(),
    UNIQUE (conversation_id, idx)
);

CREATE INDEX idx_agent_turns_conversation_idx ON agent_turns (conversation_id, idx);

CREATE UNIQUE INDEX idx_agent_turns_one_running
    ON agent_turns (conversation_id) WHERE status = 'running';

-- ---------------------------------------------------------------------------
-- 3. assistant_usage
--
-- account_id is the bare iam.Account id, not a qualified reference.
-- No FK on account_id or conversation_id: the ledger answers "how many
-- tokens did an account spend in this window" and therefore outlives
-- conversations (and their CASCADE deletes).
-- ---------------------------------------------------------------------------
CREATE TABLE assistant_usage (
    id              text        PRIMARY KEY DEFAULT ulid(),
    account_id      text        NOT NULL,
    conversation_id text        NOT NULL,
    turn_id         text        NOT NULL,
    model           text,
    input_tokens    bigint      NOT NULL DEFAULT 0,
    output_tokens   bigint      NOT NULL DEFAULT 0,
    estimated       boolean     NOT NULL DEFAULT false,
    recorded_at     timestamp   NOT NULL DEFAULT now()
);

CREATE INDEX assistant_usage_account_recorded_idx
    ON assistant_usage (account_id, recorded_at);

-- DOWN

DROP TABLE IF EXISTS assistant_usage;
DROP TABLE IF EXISTS agent_turns;
DROP TABLE IF EXISTS agent_conversations;
