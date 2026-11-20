-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Event-sourced document store: the core of Facet.
--
-- Documents live in `projections` (current state) and `mutations`
-- (append-only event log). Every mutation INSERT updates its projection
-- through triggers. This file holds the whole concern:
--
--   1. Extensions + `ulid()` — id generation used by every table below.
--   2. `projections` + `mutations` tables and all their indexes.
--   3. Pure SQL helpers consumed by the projection triggers
--      (jsonb diff application, search computation).
--   4. Mutation-to-projection triggers (`projection_from_*` dispatch,
--      `stamp_mutation_insert`, `periodic_snapshot`), including the
--      transaction-local GUC guards the retention compaction and the
--      write-time coalescing bypass them with.
--
-- Each section maps to one former migration file; the DOWN section
-- reverses the sections in dependency order.

-- UP

-- ---------------------------------------------------------------------------
-- 0. Session timezone backstop
-- ---------------------------------------------------------------------------

-- Every timestamp column in this schema is tz-naive and stores UTC (see
-- doc/backend/workflow.md → Time / Timezone). The application pins the
-- session TimeZone via the libpq `options` parameter on every pooled
-- connection (Database.init); this sets the same default at the role level,
-- so any client that connects with the application role — a human with
-- psql, a BI tool, a one-off script — gets a UTC session even without the
-- libpq pin. With a non-UTC session, `now()` defaults and
-- `text::timestamp` casts store local wall-clock time into the naive
-- columns: PostgreSQL silently drops the offset.
--
-- CURRENT_USER is the role the migration runner connected with — the
-- application role from DATABASE_URL. A role-level setting is independent
-- of the database, so it also covers databases cloned from templates
-- (the test suite's worker databases).
ALTER ROLE CURRENT_USER SET timezone TO 'UTC';

-- ---------------------------------------------------------------------------
-- 1. Extensions + ULID generation function
-- ---------------------------------------------------------------------------

-- Activate required extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- for gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- GIN trigram indexes (search column, Match/ILIKE operator)

-- The `vector` extension (pgvector) is optional. Enable it only when the
-- server provides it. A standard PostgreSQL image has no pgvector; the
-- migration then skips the extension and prints a notice, so classic
-- deployments work. RAG features (assistant retrieval embeddings) need
-- pgvector — see doc/backend/assistant.md.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_available_extensions WHERE name = 'vector') THEN
        CREATE EXTENSION IF NOT EXISTS vector;
    ELSE
        RAISE NOTICE 'pgvector not available on this server - skipped. RAG features (embeddings) stay disabled.';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- ULID generation function
-- Returns a 26-character Crockford Base32 encoded ULID:
--   - 10 chars: timestamp component      (48 bits, millisecond precision,
--              padded with 2 zero low bits to fill 10 base32 chars)
--   -  2 chars: sub-millisecond component (10 bits, ticks of 1/1024 ms
--              counted from the current millisecond boundary)
--   - 14 chars: random component          (70 bits, cryptographically random)
-- All time math is exact integer arithmetic (bigint microseconds), and the
-- ms timestamp is floored (never rounded) so the millisecond bucket starts
-- exactly where the sub-ms tick grid wraps. ULIDs generated within the same
-- millisecond therefore sort by creation order at ~1 µs resolution. Ties
-- within one tick resolve on random bits. Requires PG 14+ (EXTRACT returns
-- numeric, exact).
-- Total: 48 + 10 + 70 = 128 bits (26 Crockford Base32 chars). Not strictly
-- ULID-spec compliant (spec mandates 80 random bits), but remains decodable
-- by standard ULID parsers (the first 10 chars are a spec-compliant
-- millisecond timestamp).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ulid() RETURNS text
    LANGUAGE plpgsql VOLATILE
    AS $$
DECLARE
    -- Crockford's Base32 alphabet (no I, L, O, U to avoid ambiguity)
    alphabet CONSTANT text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    epoch_us bigint;
    unix_ts  bigint;
    sub_ms   bigint;
    rand     bytea;
    result   text := '';
    val      bigint;
    i        int;
BEGIN
    -- Capture time once so ms and sub-ms derive from the same instant.
    -- Keep the math in integers: float math at epoch scale quantizes past
    -- 2^53. unix_ts is floored (bigint division), not rounded, so the tick
    -- grid and the ms bucket share the same boundary.
    epoch_us := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000000)::bigint;
    unix_ts  := epoch_us / 1000;                  -- 48-bit ms timestamp
    sub_ms   := (epoch_us % 1000) * 1024 / 1000;  -- 10 bits, 1/1024 ms ticks

    -- Encode timestamp (48 bits → 10 base32 chars). The value is padded
    -- with 2 zero low bits so it fills 50 bits exactly. Do NOT write the
    -- shift as `unix_ts >> (43 - i * 5)`: on the last char that is a negative
    -- shift, and PostgreSQL resolves `>> -2` as a right shift by 62 — the
    -- low 3 bits of the timestamp would never reach the output, the ms
    -- prefix would quantize to 8 ms, and same-ms ordering would break at
    -- every millisecond boundary.
    FOR i IN 0..9 LOOP
        result := result || substr(alphabet, ((((unix_ts << 2) >> (45 - i * 5)) & 31) + 1)::int, 1);
    END LOOP;

    -- 9 cryptographically random bytes (72 bits; 70 used). Byte 3 straddles
    -- the two 40-bit halves (top 6 bits → first half, bottom 2 bits → second
    -- half); the bottom 2 bits of byte 8 are dropped.
    rand := gen_random_bytes(9);

    -- First 40-bit half: sub_ms (10 bits) ‖ top 30 random bits (bytes 0..2 +
    -- top 6 bits of byte 3) → 8 base32 chars
    val := (sub_ms << 30)
         | (get_byte(rand, 0)::bigint << 22)
         | (get_byte(rand, 1)::bigint << 14)
         | (get_byte(rand, 2)::bigint << 6)
         | (get_byte(rand, 3)::bigint >> 2);
    FOR i IN 0..7 LOOP
        result := result || substr(alphabet, (((val >> (35 - i * 5)) & 31) + 1)::int, 1);
    END LOOP;

    -- Second 40-bit half: bottom 2 bits of byte 3 ‖ bytes 4..7 ‖ top 6 bits
    -- of byte 8 → 8 base32 chars
    val := ((get_byte(rand, 3) & 3)::bigint << 38)
         | (get_byte(rand, 4)::bigint << 30)
         | (get_byte(rand, 5)::bigint << 22)
         | (get_byte(rand, 6)::bigint << 14)
         | (get_byte(rand, 7)::bigint << 6)
         | (get_byte(rand, 8)::bigint >> 2);
    FOR i IN 0..7 LOOP
        result := result || substr(alphabet, (((val >> (35 - i * 5)) & 31) + 1)::int, 1);
    END LOOP;

    RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Core tables: projections + mutations
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- projections
-- ---------------------------------------------------------------------------
CREATE TABLE projections (
    domain       varchar(128) NOT NULL,
    doc_type     varchar(128) NOT NULL,
    id           text        NOT NULL DEFAULT ulid(),
    -- LZ4 decompresses faster than the default pglz, trading a slightly lower
    -- compression ratio for lower read CPU on the TOASTed document body.
    content      jsonb       COMPRESSION lz4 NOT NULL DEFAULT '{}'::jsonb,
    version      integer     NOT NULL DEFAULT 0,
    links        jsonb       NOT NULL DEFAULT '[]'::jsonb,
    meta         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    state        text        NOT NULL,
    search       text,
    display_name varchar(255),
    deleted_at   timestamp,
    updated_at   timestamp   NOT NULL,
    created_at   timestamp   NOT NULL,
    PRIMARY KEY (domain, doc_type, id)
);

-- ---------------------------------------------------------------------------
-- mutations
-- ---------------------------------------------------------------------------
CREATE TABLE mutations (
    domain      varchar(128) NOT NULL,
    doc_type    varchar(128) NOT NULL,
    id          text        NOT NULL DEFAULT ulid(),
    doc_id      text        NOT NULL,
    idx         integer     NOT NULL DEFAULT 0,
    -- Aggregate linkage: the immediate parent at write time. Stamped by
    -- the BEFORE INSERT trigger (see stamp_mutation_insert); roots carry
    -- NULL. No backfill — linkage exists only when the target row carried
    -- meta.parent_id at write time.
    parent_doc_id text,
    action      text        NOT NULL CHECK (action IN ('create', 'update', 'delete', 'snapshot')),
    actioner_id text        NOT NULL,
    arguments   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Provenance — promoted from the former JSONB `meta` column to typed
    -- columns. `channel`, `cause_kind`, and `cause_trace` are NOT NULL:
    -- every mutation is stamped, system triggers included.
    channel      text        NOT NULL CHECK (channel IN ('session', 'oauth_app', 'app_api_key', 'api_key', 'mcp', 'internal')),
    app          text,
    api_key      text,
    acting_role  text,
    cause_kind   text        NOT NULL CHECK (cause_kind IN ('request', 'action', 'hook_event', 'hook_schedule', 'replication', 'cascade', 'rollback', 'migration', 'periodic_snapshot', 'webhook_test', 'assistant', 'compaction', 'seed')),
    cause_name   text,
    cause_event  text,
    cause_source text,
    cause_parent text,
    cause_trace  text        NOT NULL,
    emitted_at  timestamp   NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, doc_type, id)
);

-- Index on mutations for efficient document lookups filtered by type
CREATE INDEX idx_mutations_doc_id_type ON mutations (domain, doc_type, doc_id, action);
CREATE INDEX idx_mutations_actioner ON mutations (domain, doc_type, actioner_id);
CREATE INDEX idx_mutations_doc_idx ON mutations (domain, doc_type, doc_id, idx);

-- Causal-cluster lookup: all mutations of one cluster share `cause_trace`
-- (the root mutation's ULID); "one cluster is one query on trace". The
-- trailing `emitted_at` lets the audit walk return rows in emission order
-- without a sort.
CREATE INDEX idx_mutations_cause_trace ON mutations (cause_trace, emitted_at);

-- Aggregate-feed lookup: "all mutation rows of one parent's children".
-- The trailing `emitted_at` serves the merged timeline ordering; the read
-- path pins the child doctype set from the parent definition, so
-- `doc_type` needs no leading position here.
CREATE INDEX idx_mutations_parent_doc
  ON mutations (domain, parent_doc_id, emitted_at);

-- App attribution: "which mutations did this app cause". Partial on
-- `app IS NOT NULL` — session/internal rows never match an app filter.
CREATE INDEX idx_mutations_app ON mutations (app) WHERE app IS NOT NULL;

-- `channel` and `cause_kind` are deliberately NOT indexed: low cardinality
-- (6 and 12 values), and audit queries scope by (domain, doc_type) via the
-- primary-key btree first. Add expression/column indexes only when a real
-- query needs them.

-- Guard: prevent duplicate idx values on the same document under
-- concurrent inserts. The trigger assigns MAX(idx)+1. Update and delete
-- writers lock the projection row first (SELECT ... FOR UPDATE), so their
-- MAX(idx) read is serialized. The remaining race is the create path with
-- a client-supplied doc id: two concurrent creates both read MAX(idx) as
-- NULL and both compute idx = 1. The index turns that race into a
-- unique_violation error (SQLSTATE 23505, this constraint), which the HTTP
-- layer maps to a 409 with a retry hint. There is no server-side retry
-- loop.
CREATE UNIQUE INDEX idx_mutations_doc_id_idx
  ON mutations (domain, doc_type, doc_id, idx);

-- Index on projections for state-based lookups
CREATE INDEX idx_projections_state ON projections (domain, doc_type, state);

-- GIN trigram index on search, scoped to non-deleted documents.
-- The query always filters by (domain, doc_type) via the primary key btree,
-- so the planner combines both indexes with a bitmap scan.
-- The finished search corpus is supplied via the `harness.mutation_search` GUC
-- (transaction-local set_config) before each mutation INSERT.
CREATE INDEX idx_projections_search_trgm
  ON projections USING gin (search gin_trgm_ops)
  WHERE deleted_at IS NULL;

-- GIN index on links for containment queries ("which documents link to this URN?").
-- Links is a JSON array of canonical URN strings; jsonb_path_ops gives a
-- smaller, faster index for the only operator we support here (`@>` containment).
-- Partial (deleted_at IS NULL) excludes tombstoned documents, matching the
-- other projection indexes. Queries always scope by (domain, doc_type) via the
-- primary-key btree so the planner combines both indexes with a bitmap scan.
CREATE INDEX idx_projections_links_gin
  ON projections USING gin (links jsonb_path_ops)
  WHERE deleted_at IS NULL;

-- Index supporting O(log n) ETag computation for collection reads.
-- `Facet::Document::List.collection_version(db, domain, doc_type)` runs
-- `SELECT max(updated_at) FROM projections WHERE domain = $1 AND doc_type = $2`
-- to derive a microsecond-precision validator for the
-- `GET /api/:domain/:doctype` ETag. The composite index on
-- `(domain, doc_type, updated_at)` lets Postgres answer that with an
-- index-only backward scan returning the top row — no heap fetches, no
-- count(*).
--
-- `updated_at` is preferred over `state` (the mutation ULID) here because:
--   - `state` is randomized within the same millisecond (the ULID random
--     suffix is freshly sampled on every `ulid()` call), so `max(state)` is
--     non-monotonic across same-ms mutations and can fail to bump on a real
--     data change (a false 304).
--   - document IDs are also user-selectable, so any id-derived signal can be
--     pinned to a fixed value by a caller and is unsafe as a version.
-- `updated_at` is set to `mutation.emitted_at` by the projection trigger on
-- every mutation (create/update/delete/snapshot/rollback) and has
-- microsecond resolution, which makes the same-ms collision window
-- negligible for HTTP cache validation.
CREATE INDEX idx_projections_doctype_updated_at
    ON projections (domain, doc_type, updated_at);

-- Index supporting the parent-scoped ETag computation for nested child
-- collection reads. `Facet::Document::List.child_collection_version` runs
-- `SELECT max(updated_at) FROM projections
--  WHERE domain = $1 AND doc_type = $2 AND meta->>'parent_id' = $3`
-- so the `GET /api/:domain/:doctype/:id/:rel` ETag bumps only when the
-- children of THAT parent change. The expression index on
-- `(meta->>'parent_id')` extends the composite pattern of
-- `idx_projections_doctype_updated_at`: Postgres answers the lookup with an
-- index-only backward scan over the one parent's rows — no heap fetch, no
-- scan of the whole doctype.
--
-- Tombstones keep `meta` (only `content`/`links`/`search` are cleared on
-- delete), so a soft-deleted child still matches the parent filter and the
-- tag still busts on delete. No `deleted_at` filter — tombstones are
-- included on purpose, same as the doctype-wide index above.
CREATE INDEX idx_projections_parent_updated_at
    ON projections (domain, doc_type, (meta->>'parent_id'), updated_at);

-- ---------------------------------------------------------------------------
-- 3. Pure helpers consumed by the projection triggers
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Helper: apply a JsonDiff-style diff to a jsonb value
--
-- The diff is a jsonb object with optional "set" and "unset" arrays:
--   diff = {
--     "set":   [{"path": ["key", ...], "value": any}, ...],
--     "unset": [["key", ...], ...]
--   }
-- Returns the modified target.
-- ---------------------------------------------------------------------------
-- Recursively ensure that the path up to (but not including) the last key
-- exists in the target, creating empty objects as needed.
CREATE OR REPLACE FUNCTION jsonb_ensure_path(target jsonb, path text[])
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    i      int;
    sub    text[];
BEGIN
    FOR i IN 1 .. array_length(path, 1) - 1 LOOP
        sub := path[1:i];
        IF target #> sub IS NULL OR jsonb_typeof(target #> sub) <> 'object' THEN
            target := jsonb_set(target, sub, '{}'::jsonb, true);
        END IF;
    END LOOP;
    RETURN target;
END;
$$;

-- Apply a JsonDiff-style diff to a jsonb value.
--
-- The diff is a jsonb object with optional "set" and "unset" arrays:
--   diff = {
--     "set":   [
--       {"path": ["key", ...], "value": any},
--       {"path": ["key", ...], "patch": {"hunks": [...]}}  -- alternative
--     ],
--     "unset": [["key", ...], ...]
--   }
-- A `set` entry carries either `value` (replace) or `patch` (apply a
-- line-based unified diff to an existing string at that path). The two
-- are mutually exclusive. Patches are produced by `Mutation::JsonDiff`
-- for long string-to-string changes.
-- Returns the modified target.
CREATE OR REPLACE FUNCTION jsonb_apply_text_patch(old_text text, patch jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    hunk        jsonb;
    hunk_lines  jsonb;
    raw_line    text;
    marker      char;
    content     text;
    target_idx  int;     -- 0-based index into old_text lines
    old_count   int;
    old_start   int;
    out_arr     text[] := ARRAY[]::text[];
    old_arr     text[];
BEGIN
    IF old_text IS NULL THEN
        RAISE EXCEPTION 'Cannot apply text patch to a NULL value';
    END IF;

    -- Split old_text on '\n', preserving the trailing newline on each line.
    -- regexp_split_to_array leaves a trailing empty element when the text
    -- ends with '\n'; we drop it so that "a\n" => {"a\n"} (one line).
    old_arr := regexp_split_to_array(old_text, '(?<=\n)');
    IF array_length(old_arr, 1) > 0 AND old_arr[array_length(old_arr, 1)] = '' THEN
        old_arr := old_arr[1:array_length(old_arr, 1) - 1];
    END IF;

    target_idx := 0;

    FOR hunk IN SELECT * FROM jsonb_array_elements(COALESCE(patch->'hunks', '[]'::jsonb))
    LOOP
        old_start := (hunk->>'old_start')::int;
        old_count := (hunk->>'old_count')::int;

        -- Compute the 0-based index where this hunk begins consuming old lines.
        -- For pure insertions (old_count = 0), old_start is the line number
        -- *after* which to insert (0 = before line 1).
        DECLARE
            target_idx_hunk int := CASE WHEN old_count = 0 THEN old_start ELSE old_start - 1 END;
        BEGIN
            IF target_idx_hunk < target_idx THEN
                RAISE EXCEPTION 'Patch hunk out of order: old_start % moves backwards', old_start;
            END IF;

            -- Copy unchanged lines up to the hunk.
            WHILE target_idx < target_idx_hunk LOOP
                IF target_idx > array_length(old_arr, 1) THEN
                    RAISE EXCEPTION 'Patch hunk old_start % exceeds old line count %', old_start, array_length(old_arr, 1);
                END IF;
                out_arr := array_append(out_arr, old_arr[target_idx + 1]);
                target_idx := target_idx + 1;
            END LOOP;
        END;

        -- Apply each line of the hunk.
        hunk_lines := COALESCE(hunk->'lines', '[]'::jsonb);
        FOR raw_line IN SELECT * FROM jsonb_array_elements_text(hunk_lines)
        LOOP
            IF raw_line = '' OR raw_line IS NULL THEN
                RAISE EXCEPTION 'Invalid empty patch line in hunk at old_start %', old_start;
            END IF;
            marker := substring(raw_line from 1 for 1)::char;
            content := substring(raw_line from 2);

            IF marker = ' ' THEN
                -- context line: must match old
                IF target_idx + 1 > array_length(old_arr, 1) THEN
                    RAISE EXCEPTION 'Patch hunk at old_start % expects line % but old text has only % lines', old_start, target_idx + 1, array_length(old_arr, 1);
                END IF;
                IF old_arr[target_idx + 1] <> content THEN
                    RAISE EXCEPTION 'Patch context mismatch at old line %: expected %, got %', target_idx + 1, content, old_arr[target_idx + 1];
                END IF;
                out_arr := array_append(out_arr, content);
                target_idx := target_idx + 1;
            ELSIF marker = '-' THEN
                -- removed line: must match old
                IF target_idx + 1 > array_length(old_arr, 1) THEN
                    RAISE EXCEPTION 'Patch hunk at old_start % expects line % but old text has only % lines', old_start, target_idx + 1, array_length(old_arr, 1);
                END IF;
                IF old_arr[target_idx + 1] <> content THEN
                    RAISE EXCEPTION 'Patch context mismatch at old line %: expected %, got %', target_idx + 1, content, old_arr[target_idx + 1];
                END IF;
                target_idx := target_idx + 1;
            ELSIF marker = '+' THEN
                out_arr := array_append(out_arr, content);
            ELSE
                RAISE EXCEPTION 'Invalid patch line marker % in hunk at old_start %', marker, old_start;
            END IF;
        END LOOP;
    END LOOP;

    -- Copy remaining old lines after the last hunk.
    WHILE target_idx < array_length(old_arr, 1) LOOP
        out_arr := array_append(out_arr, old_arr[target_idx + 1]);
        target_idx := target_idx + 1;
    END LOOP;

    RETURN array_to_string(out_arr, '');
END;
$$;

CREATE OR REPLACE FUNCTION jsonb_apply_diff(target jsonb, diff jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    entry      jsonb;
    path_elems text[];
    val        jsonb;
BEGIN
    -- Apply "set" entries: deep-set the value at the given path
    FOR entry IN SELECT * FROM jsonb_array_elements(COALESCE(diff->'set', '[]'::jsonb))
    LOOP
        path_elems := ARRAY(
            SELECT jsonb_array_elements_text(entry->'path')
        );
        IF array_length(path_elems, 1) IS NOT NULL THEN
            -- Ensure all intermediate path elements exist
            target := jsonb_ensure_path(target, path_elems);
            IF entry ? 'patch' THEN
                -- Apply a line-based patch to the existing string at this path.
                DECLARE
                    existing text;
                    existing_jsonb jsonb;
                    patched_text text;
                BEGIN
                    existing_jsonb := target #> path_elems;
                    IF existing_jsonb IS NULL OR jsonb_typeof(existing_jsonb) <> 'string' THEN
                        RAISE EXCEPTION 'Cannot apply text patch at path %: existing value is not a string', path_elems;
                    END IF;
                    existing := existing_jsonb #>> '{}';
                    patched_text := jsonb_apply_text_patch(existing, entry->'patch');
                    target := jsonb_set(target, path_elems, to_jsonb(patched_text), true);
                END;
            ELSE
                val := entry->'value';
                -- entry->'value' returns SQL NULL for JSON null, but we must
                -- preserve JSON null as a value. Use explicit 'null'::jsonb.
                IF val IS NULL THEN
                    target := jsonb_set(target, path_elems, 'null'::jsonb, true);
                ELSE
                    target := jsonb_set(target, path_elems, val, true);
                END IF;
            END IF;
        ELSE
            -- Path is empty — replace root (only `value` form supported)
            target := entry->'value';
        END IF;
    END LOOP;

    -- Apply "unset" entries: remove the key at the given path
    FOR entry IN SELECT * FROM jsonb_array_elements(COALESCE(diff->'unset', '[]'::jsonb))
    LOOP
        path_elems := ARRAY(
            SELECT jsonb_array_elements_text(entry)
        );
        IF array_length(path_elems, 1) IS NOT NULL THEN
            target := target #- path_elems;
        END IF;
    END LOOP;

    RETURN target;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Mutation-to-projection triggers
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Sub-functions for each mutation action
-- ---------------------------------------------------------------------------

-- Handle 'create' action: upsert the projection (resurrection).
-- The search corpus (rendered from the DocType definition's Jinja2 template
-- by Crystal) is supplied via the transaction-local GUC
-- `harness.mutation_search`.
--
-- A `create` mutation for a `doc_id` whose projection row already exists
-- (typically because the document was previously soft-deleted and the
-- tombstone still occupies the primary key) resurrects the projection
-- instead of raising a primary-key violation. The conflict branch fully
-- overwrites the row, mirroring the fresh-INSERT path:
--   * `version` resets to 1 (new lifecycle; old version history lives in
--     the append-only `mutations` log).
--   * `created_at` / `updated_at` reset to this mutation's `emitted_at`.
--   * `deleted_at` is cleared, un-tombstoning the row.
--   * `content`, `meta`, `links`, `search`, `state` are overwritten with
--     the new create's payload (and the GUC-supplied search/links).
--
-- `Audit::Rollback` across create-delete-create still works: it replays
-- the mutations log from the last snapshot up to the target, so a rollback
-- to the post-resurrection create yields the resurrected content.
CREATE OR REPLACE FUNCTION projection_from_create(mutation mutations)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    resolved_content jsonb;
    resolved_meta    jsonb;
    search_value     text;
    links_value      jsonb;
    display_name_val text;
BEGIN
    resolved_content := COALESCE(mutation.arguments->'content', '{}'::jsonb);
    resolved_meta    := COALESCE(mutation.arguments->'meta', '{}'::jsonb);
    search_value     := NULLIF(current_setting('harness.mutation_search', true), '');
    links_value      := COALESCE(NULLIF(current_setting('harness.mutation_links', true), '')::jsonb, '[]'::jsonb);
    display_name_val := COALESCE(NULLIF(current_setting('harness.mutation_display_name', true), ''), NULL);

    INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, search, display_name, deleted_at, updated_at, created_at)
    VALUES (
        mutation.domain,
        mutation.doc_type,
        mutation.doc_id,
        resolved_content,
        1,
        links_value,
        resolved_meta,
        mutation.id,
        search_value,
        display_name_val,
        NULL,
        mutation.emitted_at,
        mutation.emitted_at
    )
    ON CONFLICT (domain, doc_type, id) DO UPDATE SET
        content      = EXCLUDED.content,
        version      = 1,
        links        = EXCLUDED.links,
        meta         = EXCLUDED.meta,
        state        = EXCLUDED.state,
        search       = EXCLUDED.search,
        display_name = EXCLUDED.display_name,
        deleted_at   = NULL,
        updated_at   = EXCLUDED.updated_at,
        created_at   = EXCLUDED.created_at;
END;
$$;

-- Handle 'update' action: apply incremental changes to the projection
-- Uses the JsonDiff format stored in mutation.arguments.
-- Search is recomputed from the updated content using the field paths
-- supplied by Crystal via the GUC.
CREATE OR REPLACE FUNCTION projection_from_update(mutation mutations)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    updated_content jsonb;
    search_value    text;
    links_value     jsonb;
    display_name_val text;
BEGIN
    -- Apply the diff to get the new content
    updated_content := jsonb_apply_diff(
        (SELECT content FROM projections WHERE domain = mutation.domain AND doc_type = mutation.doc_type AND id = mutation.doc_id),
        COALESCE(mutation.arguments->'diff', '{}'::jsonb)
    );
    search_value  := NULLIF(current_setting('harness.mutation_search', true), '');
    links_value   := COALESCE(NULLIF(current_setting('harness.mutation_links', true), '')::jsonb, '[]'::jsonb);
    display_name_val := COALESCE(NULLIF(current_setting('harness.mutation_display_name', true), ''), NULL);

    UPDATE projections
    SET
        content      = updated_content,
        meta         = jsonb_apply_diff(meta,   COALESCE(mutation.arguments->'meta_diff', '{}'::jsonb)),
        links        = links_value,
        state        = mutation.id,
        search       = search_value,
        display_name = display_name_val,
        updated_at   = mutation.emitted_at
    WHERE domain = mutation.domain
      AND doc_type = mutation.doc_type
      AND id = mutation.doc_id;
END;
$$;

-- Handle 'delete' action: tombstone the projection.
-- On delete the row is tombstoned (`deleted_at` set) and the pre-delete
-- payload (`content`, `links`, `search`) is **kept** — tombstone content
-- retention. The retained payload lets per-emit RBAC checks (e.g. WebSocket
-- collection subscriptions) scope-evaluate `deleted` events against the
-- content the principal could already read. `display_name` is also NOT
-- cleared — audit views render a human label next to the tombstone row
-- ("which document was deleted").
-- What survives on the tombstone:
--   * `deleted_at`, `state`, `updated_at` — tombstone marker, last mutation
--     pointer, audit timestamps.
--   * `content`, `links`, `search` — the pre-delete payload, kept until
--     `Cron::TombstoneContentPrune` clears it after the configured retention
--     window (`tombstone.content_retention_days`). Clearing is storage
--     cleanup only — never a feature.
--   * `meta` — RBAC scoped reads of tombstones (e.g. `iam.Roles` permission
--     lookups) and child-cascade `parent_id` resolution both rely on `meta`.
--   * `version` — `projection_from_snapshot` uses `GREATEST(projections.version, …)` on resurrection.
--   * `display_name` — preserved label.
--
-- Safety properties: `Audit::Rollback` replays the mutation log, not the
-- projection row — rolling back past a delete still restores the original
-- content from `mutations.arguments`. The `periodic_snapshot` trigger skips
-- tombstoned rows (`deleted_at IS NULL`), the trigram search index is
-- partial on the same predicate, and every list filter targets
-- `deleted_at IS NULL` — retained payloads never leak into lists, search,
-- or snapshots.
CREATE OR REPLACE FUNCTION projection_from_delete(mutation mutations)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE projections
    SET
        state      = mutation.id,
        deleted_at = mutation.emitted_at,
        updated_at = mutation.emitted_at
    WHERE domain = mutation.domain
      AND doc_type = mutation.doc_type
      AND id = mutation.doc_id;
END;
$$;

-- Handle 'snapshot' action: full overwrite (upsert) of the projection
-- The search corpus (rendered by Crystal) is supplied via the GUC.
CREATE OR REPLACE FUNCTION projection_from_snapshot(mutation mutations)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    resolved_version       int;
    resolved_content       jsonb;
    resolved_meta          jsonb;
    resolved_created_at    timestamp;
    search_value           text;
    links_value            jsonb;
    display_name_val       text;
BEGIN
    resolved_content    := COALESCE(mutation.arguments->'content', '{}'::jsonb);
    resolved_version    := COALESCE((mutation.arguments->>'version')::int, 1);
    resolved_meta       := COALESCE(mutation.arguments->'meta', '{}'::jsonb);
    resolved_created_at := COALESCE((mutation.arguments->>'created_at')::timestamp, mutation.emitted_at);
    search_value        := NULLIF(current_setting('harness.mutation_search', true), '');
    links_value         := COALESCE(NULLIF(current_setting('harness.mutation_links', true), '')::jsonb, '[]'::jsonb);
    display_name_val    := COALESCE(NULLIF(current_setting('harness.mutation_display_name', true), ''), NULL);

    INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, search, display_name, deleted_at, updated_at, created_at)
    VALUES (
        mutation.domain,
        mutation.doc_type,
        mutation.doc_id,
        resolved_content,
        resolved_version,
        links_value,
        resolved_meta,
        mutation.id,
        search_value,
        display_name_val,
        NULL,
        mutation.emitted_at,
        resolved_created_at
    )
    ON CONFLICT (domain, doc_type, id) DO UPDATE SET
        content      = resolved_content,
        version      = GREATEST(projections.version, resolved_version),
        links        = links_value,
        meta         = resolved_meta,
        state        = mutation.id,
        search       = search_value,
        display_name = display_name_val,
        deleted_at   = NULL,
        updated_at   = mutation.emitted_at;
END;
$$;

-- ---------------------------------------------------------------------------
-- Trigger function: dispatch to the appropriate sub-function.
--
-- `harness.bypass_projection_triggers` (transaction-local GUC, staged with
-- set_config(name, value, true)) lets a writer skip the projection dispatch
-- entirely — the writer then advances the projection itself (or not at all).
-- Consumers: Cron::MutationCompaction (never touches the projection) and the
-- write-time coalescing path in Document::Update (advances it manually).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_projection_from_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF COALESCE(current_setting('harness.bypass_projection_triggers', true), '') <> '' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' AND NEW.action = 'create' THEN
        PERFORM projection_from_create(NEW);
    ELSIF TG_OP = 'INSERT' AND NEW.action = 'update' THEN
        PERFORM projection_from_update(NEW);
    ELSIF TG_OP = 'INSERT' AND NEW.action = 'delete' THEN
        PERFORM projection_from_delete(NEW);
    ELSIF TG_OP = 'INSERT' AND NEW.action = 'snapshot' THEN
        PERFORM projection_from_snapshot(NEW);
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Trigger: stamp each inserted mutation row — the sequential idx per
-- document and the aggregate parent linkage.
--
-- `harness.explicit_mutation_idx` (transaction-local GUC) lets a writer pin
-- the idx: the retention-compaction snapshot (Mutation::Client
-- .compaction_snapshot) reuses the cut row's position so every idx-interval
-- reader stays correct. The parent_doc_id stamping always runs. An insert
-- that sets the GUC without naming an idx fails the NOT NULL constraint
-- loudly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stamp_mutation_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF COALESCE(current_setting('harness.explicit_mutation_idx', true), '') = '' THEN
        NEW.idx := COALESCE((
            SELECT MAX(idx) FROM mutations
            WHERE domain = NEW.domain
              AND doc_type = NEW.doc_type
              AND doc_id = NEW.doc_id
        ), 0) + 1;
    END IF;

    -- Immediate parent at write time: create and snapshot rows carry the
    -- full meta in `arguments`; update and delete rows fall back to the
    -- target projection's meta (a PK probe — meta_diff, not meta, rides
    -- updates). Roots resolve to NULL on both branches.
    NEW.parent_doc_id := COALESCE(
        NEW.arguments->'meta'->>'parent_id',
        (
            SELECT meta->>'parent_id' FROM projections
            WHERE domain = NEW.domain
              AND doc_type = NEW.doc_type
              AND id = NEW.doc_id
        )
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_mutation_insert
    BEFORE INSERT ON mutations
    FOR EACH ROW
    EXECUTE FUNCTION stamp_mutation_insert();

-- Trigger: after insert on mutations, upsert the projection
CREATE TRIGGER trg_after_mutation_insert
    AFTER INSERT ON mutations
    FOR EACH ROW
    EXECUTE FUNCTION upsert_projection_from_mutation();

-- ---------------------------------------------------------------------------
-- Periodic snapshot trigger on mutations.
--
-- After every mutation insert, checks if the mutation's idx is a multiple
-- of the configured snapshot interval (default 25). If so, reads the current
-- projection state and creates a snapshot mutation.
--
-- This replaces the Crystal-level Audit::Snapshot.after_mutation calls,
-- guaranteeing snapshots for ALL mutation paths (create, update, delete,
-- action, rollback) without manual calls.
--
-- Skipped under `harness.bypass_projection_triggers` (same guard as the
-- projection dispatch above): a bypassed insert — the compaction snapshot
-- or a coalesced update — never produces a periodic snapshot.
--
-- The snapshot interval is configurable via the facet.snapshot_interval
-- parameter. To change it:
--   ALTER DATABASE facet SET facet.snapshot_interval TO 10;
-- (Default 10, matching the Crystal Config default.)
-- ---------------------------------------------------------------------------
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

CREATE TRIGGER trg_after_mutation_snapshot
    AFTER INSERT ON mutations
    FOR EACH ROW
    EXECUTE FUNCTION periodic_snapshot();

-- DOWN

-- 4. Mutation-to-projection triggers
DROP TRIGGER IF EXISTS trg_after_mutation_snapshot ON mutations;
DROP FUNCTION IF EXISTS periodic_snapshot();
DROP TRIGGER IF EXISTS trg_after_mutation_insert ON mutations;
DROP TRIGGER IF EXISTS trg_before_mutation_insert ON mutations;
DROP FUNCTION IF EXISTS stamp_mutation_insert();
DROP FUNCTION IF EXISTS upsert_projection_from_mutation();
DROP FUNCTION IF EXISTS projection_from_create(mutations);
DROP FUNCTION IF EXISTS projection_from_update(mutations);
DROP FUNCTION IF EXISTS projection_from_delete(mutations);
DROP FUNCTION IF EXISTS projection_from_snapshot(mutations);

-- 3. Pure helpers consumed by the projection triggers
DROP FUNCTION IF EXISTS jsonb_apply_diff(jsonb, jsonb);
DROP FUNCTION IF EXISTS jsonb_apply_text_patch(text, jsonb);
DROP FUNCTION IF EXISTS jsonb_ensure_path(jsonb, text[]);

-- 2. Core tables
DROP INDEX IF EXISTS idx_projections_parent_updated_at;
DROP INDEX IF EXISTS idx_projections_doctype_updated_at;
DROP INDEX IF EXISTS idx_projections_links_gin;
DROP INDEX IF EXISTS idx_projections_search_trgm;
DROP INDEX IF EXISTS idx_projections_state;
DROP INDEX IF EXISTS idx_mutations_doc_id_idx;
DROP INDEX IF EXISTS idx_mutations_doc_idx;
DROP INDEX IF EXISTS idx_mutations_actioner;
DROP INDEX IF EXISTS idx_mutations_doc_id_type;
DROP TABLE IF EXISTS mutations;
DROP TABLE IF EXISTS projections;

-- 0. Session timezone backstop
ALTER ROLE CURRENT_USER RESET timezone;

-- 1. Extensions + ulid()
DROP FUNCTION IF EXISTS ulid();
DROP EXTENSION IF EXISTS pg_trgm;
DROP EXTENSION IF EXISTS vector;
DROP EXTENSION IF EXISTS pgcrypto;
