-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- Managed doctype indexes.
--
-- Indexes on `projections` that are created and tracked automatically from
-- doctype field definitions. This file holds the whole concern:
--
--   1. `doctype_indexes` — tracking table for managed indexes (CHECK
--      constraint covers all index types including `gist_tstzrange` /
--      `gist_daterange`).
--   2. IMMUTABLE range wrappers `facet_tstzrange` / `facet_daterange` for
--      GiST range expression indexes. The wrappers are required because
--      PostgreSQL marks `text::timestamptz` / `text::date` as STABLE not
--      IMMUTABLE, so a raw `tstzrange((content#>>'{...}')::timestamptz, ...)`
--      expression cannot be used in `CREATE INDEX`. The doctype validation
--      layer guarantees well-formed ISO-8601 UTC inputs, so the IMMUTABLE
--      marking truthfully reflects the runtime guarantee.
--   3. Type-extracting IMMUTABLE helpers for typed filter / sort / index
--      over JSONB document fields (`jsonb_as_numeric`, `jsonb_as_boolean`,
--      `facet_money_value_as_numeric`).
--
-- Each section maps to one former migration file; the DOWN section
-- reverses the sections in dependency order.

-- UP

-- ---------------------------------------------------------------------------
-- 1. Index tracking table
-- ---------------------------------------------------------------------------

-- Track indexes on projections that are managed automatically based on
-- doctype field definitions. Each row represents one PostgreSQL partial
-- index on the projections table.
CREATE TABLE doctype_indexes (
    id              text         NOT NULL DEFAULT ulid(),
    domain          varchar(128) NOT NULL,
    doc_type        varchar(128) NOT NULL,
    field_name      text         NOT NULL,
    -- `index_type` covers all index variants the doctype indexing layer can
    -- manage. `btree_numeric` is a btree variant for `integer` / `duration`
    -- fields whose access expression is `jsonb_as_numeric(content->'field')`
    -- (numeric ordering, no text round-trip). The two `gist_*` range types
    -- exist for `period` (`gist_tstzrange`) and `dateperiod`
    -- (`gist_daterange`) fields and rely on the IMMUTABLE wrapper functions
    -- `facet_tstzrange` / `facet_daterange`. `btree_money` is a composite
    -- btree over `(facet_money_value_as_numeric(content->'field'),
    -- content#>>'{field,currency}')` for money value + currency filtering;
    -- `btree_money_currency` is a plain btree on the currency text extract,
    -- served by `content#>>'{field,currency}'`.
    index_type      text         NOT NULL CHECK (index_type IN (
        'btree', 'btree_numeric', 'btree_money', 'btree_money_currency',
        'gin_trgm', 'gin_jsonb', 'unique_btree',
        'gist_tstzrange', 'gist_daterange'
    )),
    index_name      text         NOT NULL,
    status          text         NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'active', 'error', 'dropped')),
    error_message   text,
    created_at      timestamp    NOT NULL DEFAULT now(),
    updated_at      timestamp    NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (domain, doc_type, field_name, index_type)
);

-- ---------------------------------------------------------------------------
-- 2. IMMUTABLE range-construction helpers for `period` / `dateperiod` indexes
-- ---------------------------------------------------------------------------

-- PostgreSQL's `text::timestamptz` and `text::date` casts are STABLE (not
-- IMMUTABLE) because they depend on the session's `TimeZone` / `DateStyle`
-- settings. Expression indexes require IMMUTABLE expressions, so a naive
-- `CREATE INDEX ... USING gist (tstzrange((content#>>'{start}')::timestamptz, ...))`
-- is rejected with "functions in index expression must be marked IMMUTABLE".
--
-- These wrapper functions are explicitly marked IMMUTABLE. The contract
-- they encode is: **the doctype validation layer guarantees that all
-- `period`/`dateperiod` field values are well-formed ISO-8601 strings**
-- (datetime for `period` with timezone offsets or `Z`; calendar date in
-- `YYYY-MM-DD` for `dateperiod`). Under that contract, the cast results
-- are independent of session settings — the IMMUTABLE marking truthfully
-- reflects the runtime guarantee, not a lie about the underlying cast.
--
-- If the doctype validation layer ever loosens its input checks (e.g.
-- begins accepting non-ISO date formats), these functions must be revisited.

-- Builds a `tstzrange` from two ISO-8601 timestamp strings.
-- Convention: `[)` (inclusive start, exclusive end) — `period` represents
-- a continuous timestamp interval where the end instant is not included.
CREATE OR REPLACE FUNCTION facet_tstzrange(start_text text, end_text text)
    RETURNS tstzrange
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    STRICT
    AS $$
        SELECT tstzrange(
            $1::timestamptz,
            $2::timestamptz,
            '[)'
        )
    $$;

-- Builds a `daterange` from two `YYYY-MM-DD` strings.
-- Convention: `[]` (inclusive both ends) — `dateperiod` represents a
-- calendar-day interval, which is finite and countable.
CREATE OR REPLACE FUNCTION facet_daterange(start_text text, end_text text)
    RETURNS daterange
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    STRICT
    AS $$
        SELECT daterange(
            $1::date,
            $2::date,
            '[]'
        )
    $$;

-- ---------------------------------------------------------------------------
-- 3. Type-extracting helpers for typed filter / sort / index
-- ---------------------------------------------------------------------------

-- They read a jsonb value directly (`content->'field'`, NOT the text-extract
-- `content->>'field'`) and return it as the target SQL type, or NULL when
-- the stored value's JSON type does not match (e.g. a JSON string on an
-- integer field — a defensive response to directly-mutated legacy data;
-- the validator rejects such inputs at create/update time).
--
-- Why jsonb-direct over the `->>` text round-trip:
--
-- Comparison operators (`__gt`, `__gte`, `__lt`, `__lte`, `__between`) on
-- `integer` / `money` / `boolean` fields require a typed LHS. The previous
-- strategy extracted the value as text (`content->>'field'`) and then cast
-- to the target type. The cast was chosen from the *bound value's* JSON
-- runtime type, so query-string filters (`filters[age__gt]=20`, always
-- parsed as `JSON::Any(String)`) collapsed to text comparison — numbers
-- sorted lexicographically (`"100"` between `"10"` and `"20"`).
--
-- `numeric` is arbitrary-precision and subsumes the full `bigint` range,
-- so `jsonb_as_numeric` covers both `integer` and `money` doctype fields
-- — no separate bigint helper is needed.
--
-- `jsonb_typeof(j) = 'number'` accepts any JSON numeric value (int or
-- float); the subsequent `j::numeric` cast is unambiguous.
--
-- Marked IMMUTABLE + PARALLEL SAFE so they are usable in expression indexes
-- (see the `btree_numeric` index_type in `Index::Naming.access_expression`).

CREATE OR REPLACE FUNCTION jsonb_as_numeric(j jsonb) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN jsonb_typeof(j) = 'number' THEN j::numeric END
$$;

CREATE OR REPLACE FUNCTION jsonb_as_boolean(j jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN jsonb_typeof(j) = 'boolean' THEN j::boolean END
$$;

-- ---------------------------------------------------------------------------
-- IMMUTABLE numeric extractor for `money` doctype field values.
--
-- Reads `content->'field'` (must be a JSON object), then the `value` member
-- (must be a JSON string), and casts it to `numeric` via the text input
-- parser — exact decimal, no float8 round-trip. Returns NULL for any other
-- shape so a directly-mutated / malformed stored row degrades to no-match
-- and NULLS LAST on sort instead of 500-ing the request.
--
-- The `value` text is checked against a decimal regex before the cast so a
-- blank or non-numeric `value` (reachable only via a direct snapshot
-- mutation since `MoneyType#validate` rejects these at write time) returns
-- NULL instead of raising `invalid input syntax for type numeric`. This is
-- the defensive contract the IMMUTABLE marking demands — the function must
-- not throw on any jsonb input.
--
-- IMMUTABLE marking truthfully reflects the runtime contract: `MoneyType#validate`
-- rejects any persisted `value` that is not a well-formed decimal string, so
-- the cast is deterministic for valid rows. The regex guard is belt-and-
-- braces for the bypass path. If validation ever loosens, the IMMUTABLE
-- marking stays sound (no new raise paths are introduced).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION facet_money_value_as_numeric(j jsonb) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN jsonb_typeof(j) = 'object'
         AND jsonb_typeof(j -> 'value') = 'string'
         AND (j ->> 'value') ~ '^-?[[:digit:]]+([.][[:digit:]]+)?$'
      THEN (j ->> 'value')::numeric
  END
$$;

-- DOWN

-- 3. Type-extracting helpers
DROP FUNCTION IF EXISTS facet_money_value_as_numeric(jsonb);
DROP FUNCTION IF EXISTS jsonb_as_boolean(jsonb);
DROP FUNCTION IF EXISTS jsonb_as_numeric(jsonb);

-- 2. IMMUTABLE range-construction helpers
DROP FUNCTION IF EXISTS facet_tstzrange(text, text);
DROP FUNCTION IF EXISTS facet_daterange(text, text);

-- 1. Index tracking table
DROP TABLE IF EXISTS doctype_indexes;
-- pg_trgm may be used by other features; leave extension in place on rollback.
