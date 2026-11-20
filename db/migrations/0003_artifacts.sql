-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- UP

-- ---------------------------------------------------------------------------
-- Artifacts
--
-- File storage for `file`-typed doctype fields and inline
-- `urn:facet:artifact:…` links in longtext. Bytes live in object storage
-- (S3 via shrine); metadata and access control live here.
--
-- Design invariants:
--
--   1. `artifacts` holds content facts only — no domain, no owner, no
--      publicity. Dedup merges rows on `signature_sha256`, so anything
--      access-bearing on this table would be shared between unrelated
--      uploaders.
--
--   2. `artifact_owners` rows are append-only. They are removed only when
--      their document or domain is removed. Domain drop cleans
--      `artifact_owners` and `artifact_references` (both domain-scoped);
--      the `artifacts` rows themselves fall out on the next prune, which
--      is join-derived.
--
-- See `doc/backend/artifact.md` for the full design.
-- ---------------------------------------------------------------------------

-- content facts; no domain, no owner, no publicity
CREATE TABLE artifacts (
    id               text        PRIMARY KEY DEFAULT ulid(),
    filename         text        NOT NULL,
    mime_type        text        NOT NULL,            -- derived from magic bytes at upload
    size             bigint      NOT NULL,
    signature_sha256 text        NOT NULL,
    path             text        NOT NULL,             -- shrine key: {sha256}/{ulid}
    deleted_at       timestamp   NULL,
    created_at       timestamp   NOT NULL DEFAULT now()
);

-- Dedup lookup: candidates by sha256, excluding tombstoned rows.
-- Not UNIQUE — see the upload flow. A caller that cannot read an existing
-- row stores a second copy rather than reading someone else's bytes.
CREATE INDEX artifacts_dedup_idx
    ON artifacts (signature_sha256)
    WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- artifact_owners — provenance; drives the ACL
-- ---------------------------------------------------------------------------
CREATE TABLE artifact_owners (
    id           text         PRIMARY KEY DEFAULT ulid(),
    artifact_id  text         NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    domain       varchar(128) NOT NULL,
    doc_type     varchar(128) NOT NULL,
    doc_id       text         NOT NULL,
    field_path   text         NOT NULL,               -- normalized, array indices included
    view_tag     jsonb        NULL,                   -- snapshot of FieldDefinition#view at upload
    created_by   text         NOT NULL,
    created_at   timestamp    NOT NULL DEFAULT now(),
    UNIQUE (artifact_id, domain, doc_type, doc_id, field_path)
);

-- ACL lookup: for a given artifact, find owner rows the caller might read,
-- scoped by (artifact_id, domain, doc_type).
CREATE INDEX artifact_owners_lookup_idx
    ON artifact_owners (artifact_id, domain, doc_type);

-- ---------------------------------------------------------------------------
-- artifact_grants — signed URLs; the only way bytes reach an unauthenticated
-- caller (browsers cannot send a DPoP proof, so authenticated callers
-- exchange their credentials for a short-lived signed URL served from a
-- separate origin).
-- ---------------------------------------------------------------------------
CREATE TABLE artifact_grants (
    id           text         PRIMARY KEY DEFAULT ulid(),  -- appears in the URL
    artifact_id  text         NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    owner_id     text         NOT NULL REFERENCES artifact_owners(id) ON DELETE CASCADE,
    kind         varchar(16)  NOT NULL,                     -- 'ephemeral' | 'permanent'
    expires_at   timestamp    NULL,                         -- NULL for permanent
    epoch        int          NOT NULL DEFAULT 0,           -- bump to invalidate issued URLs
    created_by   text         NOT NULL,
    created_at   timestamp    NOT NULL DEFAULT now()
);

CREATE INDEX artifact_grants_owner_idx
    ON artifact_grants (owner_id);

-- Admin-surface lookup: the per-artifact grant listing and the live-grant
-- counts (`GET /api/Artifacts...`). The other two child tables already lead
-- their indexes with `artifact_id` (`artifact_owners_lookup_idx`, the
-- `artifact_references` primary key); this brings `artifact_grants` in line.
CREATE INDEX artifact_grants_artifact_idx
    ON artifact_grants (artifact_id);

-- ---------------------------------------------------------------------------
-- artifact_references — prune bookkeeping only.
--
-- Tracks what points at what so prune can decide eligibility. It is
-- rebuilt from the mutation log (a projection: truncate-and-rebuild
-- replays it) and NEVER participates in an access decision.
-- ---------------------------------------------------------------------------
CREATE TABLE artifact_references (
    artifact_id       text         NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    domain            varchar(128) NOT NULL,
    resource_id       text         NOT NULL,
    resource_field    text         NOT NULL,
    last_reference_at timestamp    NOT NULL DEFAULT now(),
    PRIMARY KEY (artifact_id, domain, resource_id, resource_field)
);

-- DOWN

DROP TABLE IF EXISTS artifact_references;
DROP TABLE IF EXISTS artifact_grants;
DROP TABLE IF EXISTS artifact_owners;
DROP TABLE IF EXISTS artifacts;
