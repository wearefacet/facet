# Import/Export — documents (CSV/JSON)

The `ImportExport` concern moves the documents of one doctype in and out of Facet. Both sides are live end to end:

- **Export** — the pure CSV cell codec, the `Document::Export` service (rows in, file out), the `document_export` background job with its completion event and notification, and the enqueue, status, and download routes.
- **Import** — the `Document::Import` service (one transaction, all-or-nothing, upsert by manifest id), the `document_import` background job, and the enqueue route with its synchronous structural parse.

For domain-level bundles — a whole domain's definition as a zip or tarball — see [`portable-domains.md`](portable-domains.md); the two concerns share the artifact staging, caller-context rebuild, and outcome plumbing.

Source files:

- [`src/import_export/csv_serializer.cr`](../../src/import_export/csv_serializer.cr) — `Facet::ImportExport::CsvSerializer`
- [`src/import_export/export.cr`](../../src/import_export/export.cr) — `Facet::Document::Export`
- [`src/import_export/export_job.cr`](../../src/import_export/export_job.cr) — `Facet::Document::ExportJob`
- [`src/import_export/import.cr`](../../src/import_export/import.cr) — `Facet::Document::Import`
- [`src/import_export/import_job.cr`](../../src/import_export/import_job.cr) — `Facet::Document::ImportJob`
- [`src/import_export/artifacts.cr`](../../src/import_export/artifacts.cr) — `Facet::ImportExport::Artifacts`
- [`src/import_export/caller_context.cr`](../../src/import_export/caller_context.cr) — `Facet::ImportExport::CallerContext`
- [`src/import_export/staging.cr`](../../src/import_export/staging.cr) — `Facet::ImportExport::Staging` — capped body read (`read_capped_body`), import staging (`stage_import`), and the synchronous structural parse
- [`src/import_export/job_queue.cr`](../../src/import_export/job_queue.cr) — `Facet::ImportExport::JobQueue.enqueue_job` — enqueue through the jobs manager, with a direct-row fallback
- [`src/import_export/routes.cr`](../../src/import_export/routes.cr) — `Facet::ImportExport::Routes`
- specs under [`spec/import_export/`](../../spec/import_export/)

## Routes

| Method | Route | Description |
| --- | --- | --- |
| `POST` | `/Api/:domain/:doctype/export` | Query: `format=csv\|json` (required), optional `wait=true`, plus the filter grammar of the list action. Enqueues a `document_export` job. |
| `POST` | `/Api/:domain/:doctype/export_view` | Body: JSON `{columns, sort, filters, timezone}`. Exports the current table view (selected columns, user sort). Enqueues the same `document_export` job with the extended payload. |
| `POST` | `/Api/:domain/:doctype/import` | Body: the CSV or JSON file. Parses and validates the file synchronously (row numbers on a `422`), stages the file + row→id manifest as artifacts, enqueues a `document_import` job. |
| `GET` | `/Api/:domain/:doctype/import_export/:job_id` | Job status: `{"id", "status", "error", "result"}`. |
| `GET` | `/Api/:domain/:doctype/import_export/:job_id/download` | Streams the result file (succeeded exports only — an import has no result file). |

All routes authenticate through the normal JWT middleware. The POSTs require the `X-Requested-With` header (the CSRF rule, with the IAM API-key-bearer bypass). The status and download routes are **requester-scoped**: the job payload carries the requesting `account_id`, and the route answers only when it matches the caller. An unknown job, a foreign account, a mismatched doctype URL, and a pruned artifact all answer `404`, never `403`, so job ids do not leak.

The import format is an explicit `format=csv|json` query param when present, else the `Content-Type` (`text/csv` / `application/json`), else the body shape (a leading `[` parses as JSON).

### Export enqueue validation

- Unknown format → `422` with the value named.
- Missing doctype → `404`. A `member_of` child or a sidecar doctype → `422` (the flat-refusal guard).
- Filters compile once against the definition — a malformed money filter answers `422` with the param named. The raw filter hash rides the payload and compiles again at execution time.
- `sort`, `page`, `per_page`, and `items` → `422`. The keyset contract fixes the output to id order; silent acceptance would make a wrong export look correct.

Filters arrive as `filters[field__op]=value` (the list action's bracket form) or bare `field__op=value` query params. Array values ride JSON-encoded and decode through the same `HTTP::ListRequest.decode_filter_value` decoder the list action uses — `filters[sku__in]=["A","B"]` arrives as a real array (B-108); other values keep the raw string form. An unrecognised filter key answers `422` naming the key with the filterable list (`Unknown filter field 'bogus' (filterable: …)`) — the same loud contract the list filters enforce; a wrong export must not look correct.

### View export enqueue

`POST /Api/:domain/:doctype/export_view` exports what the caller's table shows: the selected columns, under the caller's filters and sort. The structured payload does not fit the flat route's query-string form, so it rides a JSON body:

```json
{
  "columns": ["name", "status", "amount"],
  "sort": ["-created_at", "id"],
  "filters": { "status__eq": "active" },
  "timezone": "Europe/Paris"
}
```

Body contract (the QUERY-method precedent): the `Content-Type` must name a JSON media type (`415` otherwise); a malformed or non-object body answers `422`. An absent body parses as an empty object, so the required-`columns` check names the real problem. `wait=true` is the only accepted query param; any other param answers `422`. The response is the same `202 {job_id, status_url}` enqueue body, and `wait=true` reuses the flat export's wait plumbing.

Validation fails loud at enqueue, never in the job:

- `columns` — required, a non-empty array of strings. Each key must be a doctype field or a system column (`id`, `created_at`, `updated_at`; `deleted_at` is out of the set — the view export is live-only). An unknown key and a duplicate key answer `422` with the key named. This is the loud contract, and its contrast with the list `select` silent drop is deliberate: a wrong export must not look correct.
- `sort` — optional array of strings, the list operation's sort grammar. A non-array body, a non-string entry, or an entry that fails `HTTP::ListRequest::SORT_FIELD_RE` answers `422` at enqueue; an unknown field, or a field whose type cannot sort, answers `422` when the job compiles the order clause (B-158 — the run must not lose a sort entry silently). Absent — or an empty array — stays `nil`, so the id-order keyset holds.
- `filters` — optional map, the list filter grammar. It compiles once against the definition (a malformed money filter → `422` with the param named).
- `timezone` — optional IANA zone name, validated with `Time::Location.load` (the settings registry's rule). Invalid → `422`. Absent → UTC RFC-3339 cells.

Doctype resolution matches the flat route: `404` missing, `422` for a `member_of` child or a sidecar doctype.

#### View-export pagination and ordering

The run orders through `Document::List.build_order_clause(sort, definition)` — the same type-aware SQL the list action uses (`jsonb_as_numeric` for integer/duration, `facet_money_value_as_numeric` for money). With a real sort, the run paginates with OFFSET inside the snapshot transaction (`ORDER BY <sort>, id ASC LIMIT n OFFSET k`); the trailing `id ASC` is the deterministic tiebreaker, and the one `REPEATABLE READ` transaction makes the snapshot stable, so pages never overlap or skip. OFFSET rescans from the start per batch, which stretches large sorted exports — accepted, because a view export walks what a table shows. The full-doctype export keeps the id-order keyset. A sort that reduces to plain `id ASC` (absent, empty, or the bare `id` entry) keeps the keyset too. A sort entry the definition cannot serve (unknown field, non-scalar type) fails the run with `422` — the job records `failed` with the error, never a silently reordered file.

A caller that requests `columns` with a non-`csv` format is a caller error: the service answers `422` (the route only ever sends `csv`). The JSON export's full-content shape stays explicit.

#### View CSV conventions

A view CSV differs from the full-doctype CSV in three ways:

- The header is exactly the requested column keys, in the requested order — keys, not the view's display labels. No leading `id` column: the export carries the visible columns only, and `id` appears only when the view config names it.
- The system timestamp cells (`created_at` / `updated_at`, and `datetime`-typed field cells) render in the requested timezone as `YYYY-MM-DD HH:MM:SS` when the caller sent a `timezone`, and stay UTC RFC-3339 when it did not. A `datetime` cell shifts from its stored UTC RFC-3339 form; a value that fails to parse stays verbatim. This file is a view, not an import source — a re-import fails `DatetimeType` validation on the zone-less cells, loud.
- An unknown column key encodes an empty cell (defensive — the route validates the keys).

### Import enqueue validation

The synchronous parse fails loud before any job row exists:

- Missing doctype → `404`. A `member_of` child or a sidecar doctype → `422` (the flat-import guard — the parent must exist first).
- A body over `artifact.max_upload_bytes` → `413`, the same artifact-error shape the upload routes answer.
- malformed CSV (bad quoting, no header, unknown header column, a cell count that does not match the header) or malformed JSON (not an array, a row that is not an object) → `422` with the row number, e.g. `row 2: has 3 cells but the header declares 2 columns`.

The structural parse is shape-only: cell-level decode (money grammar, boolean text) belongs to the job's service run, so a bad value in row 900 reports through the job result, not the enqueue response.

### Enqueue-mode and wait-mode responses

Enqueue mode answers `202` — export: `{"job_id", "status_url"}`; import: `{"job_id", "row_count", "status_url"}`.

With `wait=true` the request polls the job row every `import_export.wait_poll_ms` until the row is terminal or `import_export.wait_timeout_s` passes; the timeout falls back to the `202` enqueue body with the job still running. The wait never cancels a job.

- Terminal export success: `200` with the file itself. Terminal export failure: `500` with `{"job_id", "error"}`.
- Terminal import success: `200` with `{"job_id", "status": "succeeded", "row_count", "created", "updated", "skipped"}`. Expected import failure (a row failed): `422` with `{"job_id", "status": "failed", "error": {"row", "field", "message"}}`. Crash-class failure: `500` with the job id.

## `document_export` job

`Document::ExportJob < Jobs::Handler`, kind `document_export`, `max_attempts: 1` — a job runs once; the caller fixes the input and submits again. The row enqueues with the queue's long lease horizon (`jobs.long_lease_ttl_s`, default 1 h) so a dead worker's row recovers within the window instead of being requeued mid-run by the 60 s worker default.

The payload carries coordinates only — `{domain, doc_type, format, account_id, role_id?, app_id?, api_key_id?, filters}` — never row content. `role_id` is the enqueuer's active role as the qualified `iam.Roles` reference (`CallerContext.role_reference` — `ActiveRole#role_id` is the bare name; the execution-time rebuild resolves the strict qualified form), so the role, app, and grant projections re-read at execution time and an authorization change between enqueue and execution applies the same way it would on a list request. A role or app that no longer resolves fails the job loud.

A view export extends the payload with three optional members — `columns`, `sort`, `timezone`. Their presence marks the run as a view export: the artifact stores as `{domain}.{doctype}.view.csv` (the full export keeps `{domain}.{doctype}.csv`), the success notification reads "View export ready", and the download and wait paths derive the same `.view` marker from the payload's `columns` presence. The route validates all three before enqueue; the service re-validates the timezone (a load failure fails the job loud — the file must not silently mismatch the screen).

Each run: the `Document::Export` service streams the CSV or JSON file inside one `REPEATABLE READ, READ ONLY` transaction (one point-in-time snapshot, zero document events, `mutations` untouched, no lazy migration — export reads storage as-is), the bytes store as an artifact owned by the requesting account, the temp file is deleted, and the job result records `{artifact_id, row_count, format}`.

## `document_import` job

`Document::ImportJob < Jobs::Handler`, kind `document_import`, `max_attempts: 1`, the same long lease horizon. The payload carries coordinates and artifact ids only — `{domain, doc_type, format, account_id, file_artifact_id, manifest_artifact_id, role_id?, app_id?, api_key_id?}` — never row content. The caller's context rebuilds at execution time, shared with the export handler through `ImportExport::CallerContext`.

Each run:

1. The handler loads the stored file bytes and the manifest (`{"ids": [...], "supplied": [...]}` — one document id per data row, positionally paired, with a parallel flag per row saying whether the file row carried the id itself or the id was generated as a ULID at enqueue time).
2. `Document::Import` refuses a file above the configured row cap — `import_export.max_import_rows` (default `100000`) — as a `failed` job whose message names the limit (`row: 0`, no single row owns it), before any decode or write. The whole file applies as one transaction, so the cap bounds the write volume one import can pin.
3. `Document::Import` decodes the rows (CSV through the codec's decode rules; JSON rows carry `content`) and upserts them inside **one `Database.with_transaction`**:
   - live non-deleted id → `Document::Update.call` (the full update path — validation, Lua `update` hook, computed fields, `updated` event);
   - tombstoned id → `skipped` — import never resurrects a deleted document;
   - absent id → `Document::Create.create_from_parsed` (the full create path, with the manifest id).

   A doctype whose `identifier` block sets `genonly: true` never materializes a caller-supplied id as a new document: a supplied id that is not live fails the run with `field: "id"` and the row named (`The doctype's identifier is system-generated (genonly) …`). On doctypes without `genonly`, a supplied id still creates. Id-less rows import under the manifest-generated id (it is system-generated at enqueue), and a supplied id that names a live document takes the update path — the guard covers creation only. The portable-domain bundle apply is a separate concern and keeps its id rewriting.
4. Both write paths run with the per-row RBAC of the requesting caller and `actioner_id: "import"` — audit and Lua hooks can tell a bulk import from a hand edit. An upsert import needs create **and** update permission; the first row the caller may not write fails the file, loud and terminal.
5. The first failing row aborts the transaction — zero rows persist. The failure report is that row's `{row, field, message}` (the job result records it); the buffered row events are discarded, so a rolled-back row never publishes.
6. After the commit, one `Event::Publisher.flush` — every `created` / `updated` event of the file goes out in one burst (on the worker fiber, after the rows exist). Nothing publishes before the commit.

The success result is `{row_count, created, updated, skipped}`. A row whose content equals the stored content takes the update path and counts as `updated` — `Document::Update`'s empty-diff no-op is what makes a re-execution after a crash absorb the committed attempt (the manifest fixes every id — supplied or generated — so a re-run re-writes the same documents as no-op updates).

A crash-class failure — vanished artifacts, an unknown doctype, a database error — raises `Jobs::JobError` or propagates; the transaction's rollback already removed every row and the worker records a terminal failure.

### Completion events and notification

Every terminal outcome publishes one event on the source doctype's stream — `export_completed` / `export_failed` / `import_completed` / `import_failed`:

- Headers carry `actioner_id = <requesting account id>` and no `mutation_id` — a job is not a mutation.
- The fanout override is an explicit empty channel list: the event's id is a job id, not a document id, so no collection or per-document fanout rides the completion event. (The rows an import creates fan out like any document write — their `created` events are normal document events.)
- The content is `{"id": <job_id>, "export": {...}}` / `{"id": <job_id>, "import": {...}}` with the coordinates, the report (row count, artifact id, or the failing row), and the error on failure. No row data.

The handler also enqueues one notification to the requesting account (`kind` mirrors the event name) pointing at the doctype's own document (`core.DocType`, id `{domain}.{doc_type}`). A success notification stages the retrieval path in its `data` under the reserved `download` key — the same-origin `/Api/:domain/:doctype/import_export/:job_id/download` path, which the recipient's panel renders as a Download affordance (see [`frontend/notifications.md`](../frontend/notifications.md)). A failed import's body states the recovery: nothing was imported — fix the failing row and submit the file again. Notification failures log and drop — a lost notification must never fail a completed job.

## Account-owned artifacts

`ImportExport::Artifacts.put` stores the export result and the import's staged input file + row→id manifest. Provenance is the requesting account — an `_account` owner row (the same convention the standalone upload route uses), so the requester can read the bytes back through the artifact gateway, and an operator holding `download *.*` can too. A system requester carries no account identity, so its artifacts stay ownerless. The shrine put lands before the row inserts; a failed insert deletes the object it put. The job download route stays requester-scoped and streams `Uploader.open(path)` directly. Retention is the dangling-sweep grace window (`artifact.prune_after_days`) — account-scoped owner rows never resolve against `projections`, so the window governs exactly as before; the job result keeps the `artifact_id`, so a pruned download answers a clear `404`.

## CSV cell conventions

Scalars export as stored text. Structured types export as JSON inside the cell. This keeps every type round-trip safe, and the common scalar columns stay readable in a spreadsheet.

| Field type | CSV cell |
| --- | --- |
| `string`, `longtext`, `enum`, `phone`, `url`, `color` | Text as stored |
| `integer`, `duration` | Decimal text (decode yields a JSON number) |
| `boolean` | `true` / `false` |
| `date`, `datetime` | ISO-8601 text; `datetime` is UTC `...Z` in storage, and import accepts any offset like the API |
| `reference` | Qualified id (`crm.Company.abc`) |
| `file` | Artifact ULID (id only — bytes do not move) |
| `money` | `CURR value` as one literal string — `USD 1.0` |
| `period`, `dateperiod` | JSON `{"start":...,"end":...}` |
| `object`, `array`, `dictionary`, `child`, `any` | JSON |
| `secret` | Stage handle as text; adoption marker `{mode, version, set_at}` as JSON |
| `collection: true` (any type) | JSON — the stored value is an array |
| absent / null | Empty cell |

**Formula-injection guard.** A text cell that starts with `=`, `+`, `-`, `@`, or a tab exports with one leading `'` — a spreadsheet then shows the text and does not evaluate it as a formula. This applies to every type whose cell is stored text: `string`, `longtext`, `enum`, `phone`, `url`, `color`, `date`, `datetime`, `reference`, `file`, `secret`. RFC-4180 quoting alone does not stop a sheet from evaluating the cell, so the prefix is the guard. Numeric and JSON cells keep their forms — a JSON cell starts with `{` / `[` / `"`, and numbers are their own type set.

Two rules apply to shapes outside this table:

- A stored shape outside its type's convention encodes as JSON, so no cell can lose data.
- A `data` (computed), `read_only`, or `replicated` field stays in the header (export writes it), but decode drops it — the CSV decode skips the column and the JSON decode (`strip_server_managed`) skips the key. `Document::Validation` rejects user writes that set these fields, and `Document::Update`'s patch semantics keep them untouched when the row omits them.
- A field the caller cannot see (its tags are not in the active role's `visible_tags`) is omitted from the full-doctype CSV header, so the header agrees with the read-masked row cells. The view-export header is the caller's own column selection and is unaffected.

The JSON format rows are `{"id", "content", "meta"}` — `meta` is export-only context; import reads the manifest id and the `content` object.

## Decode rules (the import contract)

- An empty cell decodes to an explicit `null` — it clears the field on update.
- A column missing from the header leaves the field untouched — no entry in the decoded content.
- A header column that is not a declared field, a duplicate column, and a cell count that does not match the header all raise `RowError`.
- A money cell requires the currency prefix. The cell parses through the `Util::MoneyFilterValue` grammar; a bare amount, an unknown ticker, or a non-decimal amount raises `RowError` with the field named. Decode builds the structured `{"value", "currency"}` object before the row reaches `Document::Create` / `Document::Update`, and echoes the amount text verbatim.
- Decode strips one leading `'` from every text cell — it marks the formula-injection guard added on export. The trade: a stored text whose form itself starts with `'` loses that leading `'` on decode.

## Known limits

- `file` fields export the artifact id only — bytes do not move.
- Children (`member_of`) and sidecar doctypes are refused at the flat route (both directions).
- Export reads storage as-is: rows not touched since the last `schema_version` bump export in their stored, pre-migration form. JSON rows carry `meta.schema_version` so staleness is visible.
- Export artifacts prune with the unreferenced-artifact window — the download link in the notification is the retention surface. The import's staged file and manifest prune the same way.
- Matching by a business key does not exist: the `id` column (through the manifest) is the only upsert key.
- The formula-injection guard trades one character: a text cell starting with `=`, `+`, `-`, `@`, or a tab exports with a leading `'`, and a text cell that starts with `'` loses it on decode — whether the guard added it or the stored text carries it.

## Example

```crystal
definition = Doctype::DoctypeDefinition.from_json(schema)
row = Facet::ImportExport::CsvSerializer.encode_row("01HXYZ...", content, definition)
csv = CSV.build { |b| b.row(Facet::ImportExport::CsvSerializer.header(definition)); b.row(row) }

result = Facet::ImportExport::CsvSerializer.decode_row(parsed_header, parsed_row, definition)
result[:id]      # "01HXYZ..." or nil
result[:content] # {"price" => {"value" => "1.0", "currency" => "USD"}, ...}

report = Facet::Document::Import.call(db, "crm", "Company", definition,
  "csv", csv_text, manifest_ids, supplied_flags, auth_context)
# => Result(row_count: N, created: N, updated: N, skipped: N)
# or RowFailure(row: N, field: ..., message: ...) — zero rows persisted
```
