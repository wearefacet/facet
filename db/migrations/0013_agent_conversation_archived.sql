-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Adds the archive state to agent conversations.
--
-- `archived_at` is a tz-naive UTC timestamp, NULL for a live conversation.
-- Archiving is a list-organisation state only: an archived conversation stays
-- readable and streamable, and a new turn unarchives it. The conversation
-- list hides archived rows unless the caller filters `archived__eq=true`.
-- See `doc/backend/agent-conversations.md`.
-- UP

ALTER TABLE agent_conversations ADD COLUMN archived_at timestamp;

-- DOWN

ALTER TABLE agent_conversations DROP COLUMN archived_at;
