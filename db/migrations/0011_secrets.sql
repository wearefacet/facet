-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Secret store.
--
-- Durable per-document secrets and the out-of-band staging area that feeds
-- them. One concern, three layers:
--
--   1. `secrets` — one durable secret per document + slot, mode enum
--      `hash`/`sealed`/`token`, FK-cascaded to `projections` (DEFERRABLE).
--      Plus `auth_state` — volatile operational state (TOTP replay guard),
--      not a secret, not document data.
--   2. `secret_staging` — staging area for out-of-band secret writes. A
--      stage handle is a single-use, TTL-bound, stager-bound capability.
--      Rows die at adoption or at the prune sweep.
--   3. `mfa_backup_codes` — single-use MFA recovery codes, one row per
--      code, digest-only storage. Minted when a TOTP enrollment completes;
--      not document data, never in the event log.
--
-- Each section maps to one former migration file; the DOWN section
-- reverses the sections in dependency order.

-- UP

-- ---------------------------------------------------------------------------
-- 1. secrets + auth_state
-- ---------------------------------------------------------------------------

-- One durable secret, keyed by document + slot.
-- mode is the closed semantic enum: 'hash' | 'sealed' | 'token'.
-- value is a self-describing payload (algorithm + parameters inside).
--
-- The FK is DEFERRABLE: the create pipeline adopts staged handles BEFORE
-- the mutation insert (the projection row appears only when the mutation
-- trigger fires, later in the same transaction), so the FK check must
-- defer to COMMIT.
CREATE TABLE secrets (
    domain      varchar(128) NOT NULL,
    doc_type    varchar(128) NOT NULL,
    doc_id      text         NOT NULL,
    slot        text         NOT NULL,
    mode        text         NOT NULL CHECK (mode IN ('hash', 'sealed', 'token')),
    value       text         NOT NULL,
    meta        jsonb        NOT NULL DEFAULT '{}',
    expires_at  timestamp    DEFAULT NULL,
    version     integer      NOT NULL DEFAULT 1,
    set_by      text         NOT NULL,
    set_at      timestamp    NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, doc_type, doc_id, slot),
    FOREIGN KEY (domain, doc_type, doc_id)
        REFERENCES projections (domain, doc_type, id) ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED
);

-- Tokens are consumed by value alone (the caller holds only the token).
CREATE UNIQUE INDEX secrets_token_value_idx
    ON secrets (value) WHERE mode = 'token';

-- TTL expiry scans (token sweep, sealed expiry).
CREATE INDEX secrets_expires_idx
    ON secrets (expires_at) WHERE expires_at IS NOT NULL;

-- Volatile operational state (TOTP replay guard). Not a secret, not
-- document data — see doc/backend/iam.md for the justification.
CREATE TABLE auth_state (
    domain         varchar(128) NOT NULL,
    doc_type       varchar(128) NOT NULL,
    doc_id         text         NOT NULL,
    last_totp_step bigint        DEFAULT NULL,
    updated_at     timestamp    NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, doc_type, doc_id),
    FOREIGN KEY (domain, doc_type, doc_id)
        REFERENCES projections (domain, doc_type, id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- 2. secret_staging
-- ---------------------------------------------------------------------------

CREATE TABLE secret_staging (
    id          text        PRIMARY KEY,   -- 'sh_' + ULID
    mode        text        NOT NULL CHECK (mode IN ('hash', 'sealed', 'token')),
    value       text        NOT NULL,      -- codec payload (never plaintext)
    meta        jsonb       NOT NULL DEFAULT '{}',
    domain      varchar(128) NOT NULL,
    doc_type    varchar(128) NOT NULL,
    field_path  text        NOT NULL,
    created_by  text        NOT NULL,
    expires_at  timestamp    NOT NULL,
    created_at  timestamp    NOT NULL DEFAULT now()
);
CREATE INDEX secret_staging_expires_idx ON secret_staging (expires_at);

-- ---------------------------------------------------------------------------
-- 3. mfa_backup_codes
-- ---------------------------------------------------------------------------

-- Single-use MFA backup codes ("recovery codes"), one row per code.
-- Minted when a TOTP enrollment completes; the raw codes are shown to the
-- account exactly once and only the SHA-256 digest of the normalized code
-- is stored — the same secret-storage precedent as `api_keys` (never in
-- the event log). Consumption is one atomic UPDATE that only matches rows
-- still unused, so a replayed code can never succeed twice.
CREATE TABLE mfa_backup_codes (
    account_id text NOT NULL,
    code_hash  text NOT NULL,
    used_at    timestamp DEFAULT NULL,
    created_at timestamp NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, code_hash)
);

-- DOWN

-- 3. mfa_backup_codes
DROP TABLE IF EXISTS mfa_backup_codes;

-- 2. secret_staging
DROP TABLE IF EXISTS secret_staging;

-- 1. secrets + auth_state
DROP TABLE IF EXISTS auth_state;
DROP TABLE IF EXISTS secrets;
