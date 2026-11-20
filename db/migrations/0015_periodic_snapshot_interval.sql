-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd
--
-- Corrects the `periodic_snapshot` trigger function:
--
-- 1. The interval resolution now reads the transaction-local
--    `harness.snapshot_every` GUC first. `Mutation::Client.insert_mutation`
--    stages it from the YAML config (`snapshot_every`), which is the single
--    source of truth. The DB-level `facet.snapshot_interval` stays as the
--    operator override, and 10 stays the last-resort fallback.
-- 2. The header comments stated two different defaults ("default 25" and
--    "Default 10, matching the Crystal Config default" — the Crystal default
--    was 25). The comments now state the real resolution order and the real
--    fallback.
-- 3. The tombstone comment claimed a delete clears the projection content.
--    Tombstones keep `content`/`links`/`search` until the prune cron clears
--    them. The trigger skips tombstoned rows for a different reason: a
--    snapshot of a tombstone would persist a stale pre-delete payload as a
--    fresh checkpoint. The code itself is unchanged in behavior.
--
-- DOWN restores the function body from migration 0001 verbatim.

-- UP
CREATE OR REPLACE FUNCTION periodic_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    snap_interval int;
    proj_record   RECORD;
    new_id        text;
BEGIN
    IF COALESCE(current_setting('harness.bypass_projection_triggers', true), '') <> '' THEN
        RETURN NEW;
    END IF;

    -- Skip snapshots of snapshots (avoid recursion)
    IF NEW.action = 'snapshot' THEN
        RETURN NEW;
    END IF;

    -- Snapshot interval, in resolution order:
    --   1. harness.snapshot_every — staged per transaction by
    --      Mutation::Client.insert_mutation from the YAML config.
    --   2. facet.snapshot_interval — the DB-level operator override
    --      (ALTER DATABASE facet SET facet.snapshot_interval TO ...).
    --   3. 10 — the last-resort fallback, matching the pre-0015 behavior.
    snap_interval := COALESCE(
        NULLIF(current_setting('harness.snapshot_every', true), '')::int,
        NULLIF(current_setting('facet.snapshot_interval', true), '')::int,
        10
    );
    IF snap_interval IS NULL OR snap_interval <= 0 THEN
        snap_interval := 10;
    END IF;

    -- Check interval
    IF NEW.idx % snap_interval <> 0 THEN
        RETURN NEW;
    END IF;

    -- Fetch current projection content. Skip tombstoned rows: a delete
    -- tombstone keeps its pre-delete payload (the prune cron clears it
    -- later), so snapshotting it would persist a stale payload as a fresh
    -- checkpoint of a live document. A snapshot is deferred until the
    -- document is resurrected (create-upsert or Audit::Rollback).
    SELECT content, meta, version, created_at
    INTO proj_record
    FROM projections
    WHERE domain = NEW.domain
      AND doc_type = NEW.doc_type
      AND id = NEW.doc_id
      AND deleted_at IS NULL;

    -- If the projection doesn't exist or is tombstoned, skip
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- Generate a new ULID for the snapshot mutation
    new_id := ulid();

    INSERT INTO mutations (
        id, domain, doc_type, doc_id, action, actioner_id, arguments,
        channel, cause_kind, cause_trace
    )
    VALUES (
        new_id,
        NEW.domain,
        NEW.doc_type,
        NEW.doc_id,
        'snapshot',
        'system:snapshot',
        jsonb_build_object(
            'content',    proj_record.content,
            'version',    proj_record.version,
            'meta',       proj_record.meta,
            'created_at', to_char(proj_record.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        -- Provenance: system-internal, root of its own causal cluster.
        -- The document `meta` stays in `arguments` — the provenance
        -- columns are never a copy of the projection payload.
        'internal', 'periodic_snapshot', new_id
    );

    RETURN NEW;
END;
$$;

-- DOWN
CREATE OR REPLACE FUNCTION periodic_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    snap_interval int;
    proj_record   RECORD;
    new_id        text;
BEGIN
    IF COALESCE(current_setting('harness.bypass_projection_triggers', true), '') <> '' THEN
        RETURN NEW;
    END IF;

    -- Skip snapshots of snapshots (avoid recursion)
    IF NEW.action = 'snapshot' THEN
        RETURN NEW;
    END IF;

    -- Read the snapshot interval from database config, default 10
    snap_interval := current_setting('facet.snapshot_interval', true)::int;
    IF snap_interval IS NULL OR snap_interval <= 0 THEN
        snap_interval := 10;
    END IF;

    -- Check interval
    IF NEW.idx % snap_interval <> 0 THEN
        RETURN NEW;
    END IF;

    -- Fetch current projection content. Skip tombstoned rows: their content
    -- is cleared on delete (see projection_from_delete), so snapshotting
    -- would persist an empty payload. A snapshot is deferred until the
    -- document is resurrected (create-upsert or Audit::Rollback).
    SELECT content, meta, version, created_at
    INTO proj_record
    FROM projections
    WHERE domain = NEW.domain
      AND doc_type = NEW.doc_type
      AND id = NEW.doc_id
      AND deleted_at IS NULL;

    -- If the projection doesn't exist or is tombstoned, skip
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- Generate a new ULID for the snapshot mutation
    new_id := ulid();

    INSERT INTO mutations (
        id, domain, doc_type, doc_id, action, actioner_id, arguments,
        channel, cause_kind, cause_trace
    )
    VALUES (
        new_id,
        NEW.domain,
        NEW.doc_type,
        NEW.doc_id,
        'snapshot',
        'system:snapshot',
        jsonb_build_object(
            'content',    proj_record.content,
            'version',    proj_record.version,
            'meta',       proj_record.meta,
            'created_at', to_char(proj_record.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        -- Provenance: system-internal, root of its own causal cluster.
        -- The document `meta` stays in `arguments` — the provenance
        -- columns are never a copy of the projection payload.
        'internal', 'periodic_snapshot', new_id
    );

    RETURN NEW;
END;
$$;
