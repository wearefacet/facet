-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Persists the streaming cancel token on the turn row.
--
-- `turn_token` is the Redis Pub/Sub cancel-channel key (`assistant:cancel:<token>`)
-- published by `POST /Api/assistant/cancel/:turn_token`. Storing it on the row
-- lets a client that missed the SSE `meta` event (page reload mid-turn) read
-- the token back from the turns API and still cancel the in-flight turn.
-- NULL for turns that never stream (manual `POST /:id/turns` rows).
-- See `doc/backend/agent-conversations.md`.
-- UP

ALTER TABLE agent_turns ADD COLUMN turn_token text;

-- DOWN

ALTER TABLE agent_turns DROP COLUMN turn_token;
