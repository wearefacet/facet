# Links — document-to-document back-references

**Files:** `src/document/links.cr`, `src/document/backrefs.cr`, `src/document/uri.cr`, `db/migrations/0001_document_store.sql`

Every projection row carries a `links` column: a JSON array of canonical `urn:facet:…` URN strings referencing documents that this document points to. It enables the inverse query "which documents reference document *X?*" without a scan, via a partial GIN index.

The `links` value is **precomputed in Crystal** from the post-mutation document content and handed to the PL/pgSQL mutation trigger through a transaction-local GUC. The trigger only stores the array — no URN parsing or markdown scanning happens in SQL.

---

## Sources

`Document::Links.extract_from_content(content, definition)` walks the doctype's field schema and collects URNs from two field types; everything else (`string`, `integer`, `enum`, `datetime`, `money`, `boolean`, `object` with no reference children, `child`, computed `data`) contributes nothing.

| `type_name` | Contribution |
|---|---|
| `reference` | The string value (or each string in an array, when `collection: true`) is read as a `projections.id`-style identifier and canonicalized into a URN via `DocURI.from_projection_id(domain, doctype, value)`, using the field's declared `doctype` (cross-domain form `hr.Employee` or same-domain form `Employee`). Bare ULIDs, qualified `{domain}.{Doctype}.{id}` ids, and two-segment `{domain}.{Doctype}` ids are all accepted. |
| `longtext` | The body is scanned twice: inline markdown links `[label](url)` whose URL parses as a valid `DocURI` (the dotted URL form `hr.Employee.01AAA` included), plus bare `urn:facet:` tokens anywhere in the text (autolinks, reference definitions, links with a title, labels containing `]`). Non-URN URLs (`https://…`) are silently ignored. |
| `array`, `object` (with `properties`), `dictionary` (with typed values) | Recurse into the nested schema using the same rules. |

The final array is `uniq!`-deduplicated so a reference and a markdown link pointing at the same URN appear only once.

### Longtext parser limits

Two passes cover the realistic forms:

- **Inline links** `[label](url)` — the URL is parsed as a `DocURI`, so both
  the canonical `urn:facet:…` form and the legacy dotted storage form
  (`hr.Employee.01AAA`) are recognized. The URL is the literal substring up
  to the next `)`, so a link title (`[Alice](urn:facet:… "t")`) still parses
  through the bare-token pass below.
- **Bare `urn:facet:` tokens** — every URN-shaped run of characters
  (`[A-Za-z0-9._:-]`, then an optional `?state=<alphanumeric>` q-component)
  is parsed wherever it appears: bare mentions in prose, autolinks
  (`<urn:facet:…>`), reference definitions (`[label]: urn:facet:…`), labels
  containing `]` (no bracket balancing needed), and links with a title. A
  trailing sentence `.` or `:` is trimmed before parsing — no real opaque id
  ends with either.

Not recognized: dotted-form mentions **without** a link or `urn:` prefix
(`hr.Employee.01AAA` in prose would over-match, so it is out of scope),
escaped delimiters inside the URL, and `URN:FACET:` uppercase (the scheme is
lowercase by RFC 8141 convention).

Artifact URNs (`urn:facet:artifact:<id>`) are deliberately **not** links:
`DocURI` only parses the document form — an artifact is not a document
(see `src/document/artifact_refs.cr`). A longtext that embeds one
therefore contributes to `artifact_references` (prune bookkeeping),
never to `links`. The read path for those rows is the MCP
`list_artifact_refs` tool (`Artifact::Refs`) or the operator listing
`GET /Api/Artifacts/:id/references` — see
[`artifact.md`](artifact.md) → Agent surface.

A prose text that merely *quotes* a URN counts as a reference — the accepted
design trade-off (the scanner must not depend on how the editor writes
labels).

---

## GUC contract with the trigger

```text
GUC name : harness.mutation_links
Scope    : transaction-local (set with set_config(..., true))
Value    : JSON array string, e.g. '["urn:facet:hr:Employee:01AAA"]'
Default  : '[]' when no links are present, OR when the doctype has no
           registered definition (e.g. core.Domain)
```

Three PL/pgSQL trigger functions consume the GUC: `apply_create_mutation`, `apply_update_mutation`, and `apply_snapshot_mutation`. Each does:

```sql
links_value := COALESCE(NULLIF(current_setting('harness.mutation_links', true), '')::jsonb, '[]'::jsonb);
```

…then sets `projections.links = links_value` on the upserted row. The COALESCE+NULLIF guards the fallback path: any caller forgetting to stage the GUC lands an empty array rather than crashing on `''::jsonb`.

`delete` mutations keep `projections.content`/`links`/`search` on the tombstone row until pruned (see [Tombstone content retention](mutation.md#tombstone-content-retention)). The retained `links` value is the pre-delete array, exercised by `spec/mutations/links_spec.cr` ("keeps links on delete").

---

## Call sites

Every high-level service that lands content on a projection sets `Document::Links.set_guc` from its **post-mutation content** immediately before the `Mutation::Client.*` insert, inside the same transaction. The low-level `Mutation::Client` wrappers (`create`, `update`, `snapshot_mutation`) intentionally do not set the GUC — staging it is the service's contract.

| Path | Content passed to `set_guc` | File |
|---|---|---|
| `Document::Create.call` | `final_document` (post-Lua, post-StripWriteOnly) | `src/document/create.cr:281` |
| `Document::Create` (`core.Domain` branch) | GUC set to `"[]"` (no doctype defn) | `src/document/create.cr:324` |
| `Document::Update.call` (PATCH + JsonDiff) | `merged` (post-merge, post-Lua, post-SyncPull, post-restore-explicit-nulls) | `src/document/update.cr:171` |
| `Document::Action.call` | `final_document` (post-Lua action diff applied) | `src/document/action.cr:157` |
| `Document::Migrate.call` | migrated `current_content` | `src/document/migrate.cr:111` |
| `Document::Migrate.write_migration_error_marker` | `projection.content` (preserved stale content) | `src/document/migrate.cr:189` |
| `Audit::Rollback.call` | rolled-back `content` | `src/audit/rollback.cr:213` |
| `Audit::Rollback.call` (missing-defn fallback) | GUC set to `"[]"` | `src/audit/rollback.cr:216` |

Key invariant for `Document::Update`: `links` is recomputed against `merged`, **not** against the JsonDiff. The persisted `mutations.arguments.diff` is the patch only; the link array tracks what `content` will look like after the trigger applies it.

The extraction rules live in code, so a change to the scanner only reaches stored rows when content is rewritten. After tightening the scanner (e.g. the bare-`urn:facet:` token pass), run `facet doctype:reproject` once per affected doctype so existing documents pick up the previously missed URNs.

---

## Indexing

```sql
-- db/migrations/0001_document_store.sql
CREATE INDEX IF NOT EXISTS idx_projections_links_gin
  ON projections USING gin (links jsonb_path_ops)
  WHERE deleted_at IS NULL;
```

Partial GIN with `jsonb_path_ops` (smaller index, supports only `@>` containment). The `deleted_at IS NULL` filter excludes tombstoned documents, matching the common query shape.

### Querying back-references

```sql
SELECT id FROM projections
 WHERE domain = $1 AND doc_type = $2
   AND deleted_at IS NULL
   AND links @> $3::jsonb;
```

`$3` is a JSON array containing the target URN, e.g. `'["urn:facet:hr:Employee:01AAA"]'`.

### Querying back-references over HTTP

`Document::Backrefs` (`src/document/backrefs.cr`) owns the query for every
user-facing surface. `Facet::Document::Backrefs.call(db, auth_context,
domain, doctype, doc_id, limit: 100)` returns
`{items: [Backrefs::Item], target_urn, capped}` or a `Facet::ServiceError`:

1. Target read gate first — `Document::Read.call`. A caller with no read
   grant on the target doctype at all answers `403`; a missing, tombstoned,
   or invisible target raises one non-disclosing `NotFound`.
2. Target URN via `Document::DocURI.from_projection_id`; needle =
   `["<urn>"]`.
3. Fan-out over every readable `(domain, doctype)` pair
   (`RBAC::ReadEnforcer.readable_doctypes`, all domains — backlinks cross
   domains). Per pair: the containment query above with that doctype's
   `list_where_clauses` AND-composed, so a referrer row never leaks past the
   caller's list visibility.
4. Stops at `limit`; `capped` reports honestly that the result set reached
   it. Exact-URN match: a `?state=`-pinned link is a distinct reference.
5. Pure read — no mutation, no events.

The MCP tool `get_backrefs` (`src/agent_tools/history.cr`) delegates to the
service with `mcp.max_result_rows` as the limit; the HTTP endpoint
`GET|QUERY /Api/:domain/:doctype/:id/backrefs` (also `src/document/routes.cr`)
delegates with the list-style `items` cap (server max 1000, default 100) and
answers `{ data: [stub rows], meta: { target, total, capped } }`. The
frontend's backlinks panel and delete-confirmation warning consume it through
`DocumentRef.backrefs()` — see [`../frontend/backlinks.md`](../frontend/backlinks.md).

---

## URN form

`DocURI` (defined in `src/document/uri.cr`) follows RFC 8141. Canonical form:

```
urn:facet:{domain}:{Doctype}:{opaque}[?state={mutation_ulid}]
```

Invariants:

- `domain` matches `^_?[a-z0-9][a-z0-9\-]*$` (lowercase alphanumeric with dashes, may start with `_` for drafts).
- `Doctype` matches `^[A-Z][a-zA-Z0-9]*$` (CamelCase).
- `opaque` matches `^[A-Za-z0-9._-]+$` — typically a ULID, but `core.DocType` and `core.Domain` registrations use the qualified `{domain}.{Doctype}` or the bare domain name respectively.
- Optional `?state={mutation_ulid}` q-component pins the reference to a historical state of the document. For `links` extraction the q-component is preserved verbatim if present (so a link to a historical state and a link to the current state of the same document are **distinct** URNs).

`DocURI.parse` accepts both the canonical URN form and the legacy dotted storage form (`hr.Employee.01J5X…`, `hr.Employee`), so existing reference field values that predate the URN scheme still work.

---

## Public API

`Facet::Document::Links`

| Method | Description |
|---|---|
| `extract_from_content(content : JSON::Any, definition : Doctype::DoctypeDefinition) : Array(String)` | Walks `definition.fields` recursively, returns deduplicated URN strings. Pure, no DB access. |
| `to_guc_value(urns : Array(String)) : String` | Serializes a URN array as a JSON array string suitable for the GUC. |
| `set_guc(db : DB::Connection, content : JSON::Any, definition : Doctype::DoctypeDefinition) : Nil` | Computes URNs from `content` and stages them on `harness.mutation_links` transaction-locally. Call immediately before the `Mutation::Client.*` insert, alongside `Document::Search.set_guc`. |

`Facet::Document::Backrefs` (`src/document/backrefs.cr`) — see [Querying
back-references over HTTP](#querying-back-references-over-http).

`Facet::Document::DocURI` — see `doc/backend/document.md`.
