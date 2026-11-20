-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- UP

CREATE TABLE api_keys (
    id             text PRIMARY KEY,
    account_id     text NOT NULL,
    role_id        text NOT NULL,
    name           text NOT NULL,
    secret_hash    text NOT NULL UNIQUE,
    display_prefix text NOT NULL,
    expires_at     timestamp DEFAULT NULL,
    last_used_at   timestamp DEFAULT NULL,
    created_at     timestamp NOT NULL DEFAULT now(),
    revoked_at     timestamp DEFAULT NULL,
    -- App-owned keys (backend apps): NULL means a normal self-service key;
    -- set means the row belongs to one backend app (app.App) and
    -- authenticates its service account. Keys never enter the event log,
    -- so the linkage lives here, not on the document.
    app_id         text NULL
);

-- List the caller's keys (self-service surface filters by owner).
CREATE INDEX idx_api_keys_account_id ON api_keys(account_id);

-- One active key per app is route-level policy (issue revokes the previous
-- row in the same transaction); the index serves the per-app lookups.
CREATE INDEX idx_api_keys_app_id ON api_keys(app_id) WHERE app_id IS NOT NULL;

-- DOWN

DROP TABLE IF EXISTS api_keys;
