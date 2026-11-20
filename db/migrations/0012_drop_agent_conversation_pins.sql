-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Ends the conversation pin/snapshot contract on `agent_conversations`.
--
-- With runtime settings (`core.SystemSettings`) the assistant connection
-- resolves at every turn start from the effective settings — endpoint, key,
-- model, and the sampling knobs. Existing conversations switch to a changed
-- model on their next turn, so the `model` column and the `config` snapshot
-- lose their behavioral role. The `system_prompt` column stays: it is
-- conversation data (the main assistant captures the setting at create;
-- the workspace and builder assistants build their prompts from context).
-- The per-turn model history survives in `assistant_usage.model`.
-- See `doc/backend/system-settings.md` and `doc/backend/agent-conversations.md`.
-- UP

ALTER TABLE agent_conversations DROP COLUMN model;
ALTER TABLE agent_conversations DROP COLUMN config;

-- DOWN

ALTER TABLE agent_conversations ADD COLUMN model text NOT NULL DEFAULT '';
ALTER TABLE agent_conversations ALTER COLUMN model DROP DEFAULT;
ALTER TABLE agent_conversations ADD COLUMN config jsonb NOT NULL DEFAULT '{}'::jsonb;
