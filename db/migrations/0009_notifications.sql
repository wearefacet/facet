-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- In-app notification store (Release 1.0).
--
-- A notification is a per-account message attached to one iam.Account.
-- It is not an event-sourced domain document: it is a derived side
-- effect, so it lives outside `projections` / `mutations` (same
-- precedent as `account_settings`, see db/migrations/0007_account_settings.sql).
--
-- account_id is the bare iam.Account id, not a qualified reference.
--
-- Timezone rule (project-wide): every timestamp column is `timestamp`
-- (without time zone) and stores UTC. The PG session `TimeZone` is pinned
-- to UTC at `Database.init`, so `now()` defaults and text casts are
-- always interpreted as UTC. Do NOT use `timestamptz` here. See
-- `doc/backend/workflow.md` → Time / Timezone.
-- UP
CREATE TABLE notifications (
  id            text        NOT NULL,
  account_id    text        NOT NULL,
  domain        varchar(128) NOT NULL,
  doc_type      varchar(128) NOT NULL,
  doc_id        text        NOT NULL,
  kind          varchar(64) NOT NULL,
  icon          varchar(32),
  title         varchar(256) NOT NULL,
  body          text        NOT NULL DEFAULT '',
  data          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  actions       jsonb       NOT NULL DEFAULT '[]'::jsonb,
  read_at       timestamp,
  actioned_at   timestamp,
  created_at    timestamp   NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

CREATE INDEX notifications_account_unread_idx
  ON notifications (account_id, created_at DESC, id DESC)
  WHERE read_at IS NULL;

CREATE INDEX notifications_account_all_idx
  ON notifications (account_id, created_at DESC, id DESC);

-- No FK on account_id: a notification outlives neither its account's
-- relevance nor the account itself in practice, but the store is a
-- standalone side table — callers that remove accounts clean up their
-- notifications explicitly.

-- actioned_at: set on the first successful action invocation (any action).
-- NULL means the actions are still live. The frontend disables every
-- action button once it is set — one-shot semantics, UI/UX prevention
-- against double-fire. Dismissal (read_at) does NOT consume actions.
--
-- DOWN
DROP TABLE IF EXISTS notifications;
