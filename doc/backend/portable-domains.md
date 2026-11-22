# Portable Domains

**Files:** `src/domain/portable.cr`, `src/domain/portable/archive.cr` (require root), `src/domain/portable/archive/` (`bundle.cr`, `writer.cr`, `reader.cr`, `yaml_encode.cr`), `src/domain/portable/export.cr`, `src/domain/portable/secret_stripper.cr`, `src/domain/portable/import.cr`, `src/domain/portable/cli.cr`, `src/util/yaml_json.cr`, `src/main.cr`

A portable-domain bundle is a self-contained snapshot of a domain's **definition** — the `core.Domain` document, every `core.DocType` definition in that domain, every owned `core.DocumentView`, and every **general** `core.CollectionView`. It is the interchange format for moving a domain's schema between Facet instances (e.g. staging → production, or vendoring a domain definition out of a repo).

An opt-in `--with-documents` mode additionally captures every non-deleted document of every user doctype in the source domain. Document data is opt-in by design so the default export stays a definition-only interchange; a domain bundle with documents is the interchange format the dev fixtures move under (see *Document data* below).

The bundle is a directory tree, a `.zip` archive, or a `.tar.gz`. The reader and writer auto-detect the form by the path extension and the file's magic bytes. The service layer (`Export`, `Import`, `Archive`) is DB- and filesystem-only — the CLI and the HTTP routes both sit on top of it.

Document **data** (live projections) and personal collection views are **not portable** by default — they are user data, not definition. Export accepts `with_documents: true` (CLI `--with-documents`) to opt in to carrying every non-deleted document of every user doctype in the source domain; the bundle then carries a `documents/` section. The `core` domain is never captured as documents — definition doctypes (`core.Domain`, `core.DocType`, `core.DocumentView`, `core.CollectionView`) are already carried as definition entries.

---

## Bundle layout

```
{domain}.facet-domain/
├── bundle.yml                       # format_version, source_domain, exported_at, facet_version
├── domain.yml                       # { content: …, meta: … } — core.Domain document
├── hooks/                           # only when the domain declares hooks
│   └── {i}-{hook_id}.lua            # one sidecar per hook script
├── doctypes/
│   ├── {QualifiedDoctype}.yml      # one entry per doctype in the source domain
│   └── {QualifiedDoctype}.lua      # sidecar for the doctype's lifecycle script
├── views/
│   └── {qualified-doctype}/
│       ├── document_views/
│       │   └── {kind}.yml
│       └── collection_views/
│       └── {slug}.yml
└── documents/                       # only when the bundle was exported with --with-documents
    └── {qualified-doctype}/
        └── {doc_id}.yml              # { content: …, meta: … } — one file per document
```

Every entry file is YAML. Long scalar strings (notably a doctype's embedded Lua `script`) render as YAML block scalars or escaped literals, so a doctype definition is reviewable in place rather than as a single-line JSON blob. Definition scripts are **externalized**: a doctype's lifecycle `script` is written to a co-located `doctypes/{QualifiedDoctype}.lua` sidecar and referenced with `script: !read_file {QualifiedDoctype}.lua`; each domain hook's `script` is written to a `hooks/{i}-{hook_id}.lua` sidecar and referenced with `script: !read_file hooks/{i}-{hook_id}.lua`. The reader (`Util::YamlInclude`) expands these references back to the file contents on import, so the round-trip is lossless. Document and view content stays inline — only definition scripts externalize. The `.tar.gz` form is a gzip of the directory tree; the `.zip` form carries the same tree as flat zip entries (pure stdlib — no external binary).

### `bundle.yml`

Hand-rolled YAML (deterministic field order, no `---` document markers). String scalars are quoted only when ambiguous to a YAML parser (e.g. a value that looks like a number or a boolean), so the common case reads as bare values:

```yml
format_version: 2
source_domain: crm
exported_at: "2026-08-17T14:42:50Z"
facet_version: 0.1.0
```

| Field | Type | Notes |
|---|---|---|
| `format_version` | `integer` | Currently `2`. Bumped only on a breaking change to the on-disk layout. The reader still loads `format_version = 1` bundles (see *Format history* below). |
| `source_domain` | `string` | The domain name on the exporting instance. |
| `exported_at` | `string` | RFC-3339 UTC timestamp. |
| `facet_version` | `string` | Facet release that produced the bundle, read from `shard.yml`. An operator can tell at a glance which release produced a bundle. |

### Entry file shape

Each `*.yml` entry is the YAML mapping `content: … \n meta: …` so the import can reconstruct `meta.parent_id` for child doctypes and views without re-deriving it from the doctype tree.

```yml
---
content:
  color: '#2196F3'
  description: Customer relationship management — companies, contacts, deals, and activities.
meta: {}
```

### Format history

| Version | Layout | Notes |
|---|---|---|
| `1` | Entry files written as JSON (`domain.json`, `doctypes/*.json`, `views/.../*.json`). `bundle.yml`'s string fields were double-encoded via `String#to_json`. | Read by the current reader for backward compatibility — a v1 bundle on disk still loads, but a fresh export always emits v2. |
| `2` (current) | Entry files are YAML (`*.yml`). `bundle.yml` emits scalars via the hand-rolled formatter (no document markers, minimal quoting). | The reader dispatches the entry decoder by `format_version` (YAML for v2+, JSON for v1). |

---

## CLI

Two commands — both bypass RBAC (`AuthContext.system`), like every other CLI subcommand. Multiple domains are declared comma-separated (`a,b,c`) or whitespace-separated (`a b c`); both forms may be mixed.

```
facet domain:export <domain>[,domain,...] [--output PATH | --output-dir DIR] [--with-documents] [--omit-secrets]
facet domain:import <path>[,path,...] [--into <domain>[,domain,...]] [--merge]
```

| Flag | Applies to | Default | Notes |
|---|---|---|---|
| `--output PATH` | `export` | `./{domain}.facet-domain` | Single-domain shortcut. Rejects multiple domains. A path ending in `.tar.gz` / `.tgz` produces a tarball; any other path is a directory tree. Mutually exclusive with `--output-dir`. |
| `--output-dir DIR` | `export` | current directory | Fan-out for multi-domain exports: one bundle per domain, written to `DIR/{domain}.facet-domain`. The directory is created if absent. Mutually exclusive with `--output`. |
| `--with-documents` | `export` | off | Also captures every non-deleted document of every user doctype in the source domain. Definition doctypes (`core.*`) are never captured as documents — they are already carried as definition entries. The bundle then carries a `documents/` section. Applies to every domain in the batch. |
| `--omit-secrets` | `export` | off (secrets are exported) | Nulls every `secret` marker in the captured documents (`SecretStripper`), so the bundle imports on an instance that does not hold the slots. **The secret state is lost: the fields import unset.** Without the flag a bundle that carries a set secret refuses on import (see *Secret-leaf gate on bundled documents*). Applies to every domain in the batch. |
| `--into DOMAINS` | `import` | bundle's `source_domain` | Renames each bundle during import — orthogonal to `--merge`. Single value when one path is given; comma-separated list aligned with multiple paths when several bundles are imported at once (counts must align). A single `--into` value combined with multiple paths is rejected. |
| `--merge` | `import` | off | Allows importing onto an existing domain, subject to the version gate; creates the domain when it does not exist yet (same as the default fresh-create branch). Applies to every domain in the batch. Without `--merge`, the import refuses if any target domain already exists. |

### Batch semantics

Multi-domain exports and imports run sequentially. The chain stops on the first failure — partial state for an export is acceptable (the operator deletes the half-written directory and re-runs), but a partial multi-domain import leaves the earlier domains imported and the operator must `db_reset` to retry. Each summary line is prefixed with `[domain]` so the operator can see which domain broke the chain in one stream.

Events are flushed once at the end of a multi-domain import (after every domain succeeded). The import CLI installs an `Event::InProcessManager` — a one-shot run has no subscribers, so the enqueued events are dropped and no Redis connection is needed. The post-commit display_name backfill runs per-domain inside its own `Import.call`.

The output of `facet domain:check`'s `domain:export` summary line lists doctype, document-view, and collection-view counts; the import summary lists created / updated / unchanged counts (split by branch).

---

## HTTP + jobs

The same bundle moves over the wire through background jobs. Source files: [`src/domain/portable/routes.cr`](../../src/domain/portable/routes.cr), [`src/domain/portable/export_job.cr`](../../src/domain/portable/export_job.cr), [`src/domain/portable/import_job.cr`](../../src/domain/portable/import_job.cr). The routes register before the document import/export routes, so the `/Api/core/Domain/import` and `/Api/core/Domain/import_export/:job_id` URLs belong to the domain concern, never to the document concern's flat routes for the `core.Domain` doctype.

| Method | Route | Description |
| --- | --- | --- |
| `POST` | `/Api/core/Domain/:id/export` | Query: `wait=true`. Enqueues a `domain_export` job. |
| `POST` | `/Api/core/Domain/import` | Body: the bundle (zip or tarball). Query: `into=<name>`, `merge=true`, `wait=true`. Enqueues a `domain_import` job. |
| `GET` | `/Api/core/Domain/import_export/:job_id` | Job status: `{"id", "status", "error", "result"}`. |
| `GET` | `/Api/core/Domain/import_export/:job_id/download` | Streams the export zip (succeeded exports only — an import has no result file). |

All routes authenticate through the normal JWT middleware. The POSTs require the `X-Requested-With` header (the CSRF rule, with the IAM API-key-bearer bypass). The status and download routes are **requester-scoped**: the job payload carries the requesting `account_id`, and the route answers only when it matches the caller. An unknown job, a foreign account, and a pruned artifact all answer `404`, never `403`, so job ids do not leak.

### Access control

The concern gates on the `core.Domain` document — the same gates the draft / publish / drop lifecycle routes hold:

- **Export** requires **read** on `core.Domain`. A missing domain and a denied read both answer a non-disclosing `404`. A draft domain answers `422` (scratch data is not portable).
- **Import** requires **write** on `core.Domain`: `create` for a fresh import, `update` for a merge onto an existing domain. The gate runs before the `409` conflict check, so a caller without the permission never learns whether the target exists. An invalid `into` name answers `422` with the same grammar `Domain::Publish` enforces (lowercase alphanumeric + dashes, no `_` prefix).

A fresh import to a domain name that does not exist creates a **live** domain (never a draft) in one step. The gate is the same `create core.Domain` check the draft door applies. Unlike the draft flow, the importer does not become a domain editor of the imported domain.

Both jobs rebuild the caller's authorization context at execution time (`ImportExport::CallerContext`) and re-run the same gates — an authorization change between enqueue and execution applies.

### Definition-only over HTTP

Export over HTTP captures the definition only — there is no `with_documents` equivalent. Read access to the `core.Domain` document must not widen into read access to every document row in the domain, so a bundle that carries a `documents/` section refuses at the import route **and** inside the import job (`422`). The CLI keeps `--with-documents` for operators.

### Enqueue-time validation (import)

The bundle parses synchronously before any job row exists: a body over `artifact.max_upload_bytes` answers `413` (the same cap the artifact upload routes use), a body that is not a zip or gzip answers `422`, an unreadable archive answers `422` with the `Archive::Error` message, a documents-carrying bundle answers `422`. The parsed bundle supplies `source_domain`, so the target (`into` \|\| `source_domain`) resolves and the gates run before enqueue. On success the bytes store as an artifact owned by the requesting account (`ImportExport::Artifacts.put`), the payload carries the artifact id only, and the response is `202` `{"job_id", "target_domain", "status_url"}` (export: `{"job_id", "status_url"}`). With `wait=true` the request polls until the row is terminal or `import_export.wait_timeout_s` passes; the timeout falls back to the `202` enqueue body. An expected failure answers `422` with the error; a crash-class failure answers `500`.

### `domain_export` job

`Portable::ExportJob < Jobs::Handler`, kind `domain_export`, `max_attempts: 1`, the queue's long lease horizon (`jobs.long_lease_ttl_s`). The payload carries `{domain, account_id, role_id?, app_id?, api_key_id?}` — `role_id` is the qualified `iam.Roles` reference (`CallerContext.role_reference`, the form the execution-time rebuild resolves). Each run: the read gate re-runs, `Portable::Export.call` builds the in-memory bundle (definition-only), `Archive.write` produces `{domain}.facet-domain.zip`, the bytes store as an artifact owned by the requesting account, the temp file is deleted, and the job result records `{artifact_id, doctype_count, document_view_count, collection_view_count, format: "zip"}`. Retrieval surfaces: the download URL in the notification, and the artifact gateway through the `_account` owner row (identity match; an operator holding `download *.*` binds its grant to the same row). Retention does not change — the artifact still prunes with the dangling-sweep window.

### `domain_import` job

`Portable::ImportJob < Jobs::Handler`, kind `domain_import`, `max_attempts: 1`, the same lease horizon. The payload carries `{bundle_artifact_id, source_domain, into, merge, account_id, role_id?, app_id?, api_key_id?}`. Each run: the stored bytes spool to a temp file, `Archive.read` parses the container (zip or tarball, by magic bytes), the documents-section guard and the write gate re-run, and `Portable::Import.call` applies the whole bundle in its one outer transaction. The success result is the import counters (`{domain, created, doctypes_created, …, documents_created}` — always `0` documents). Expected failures (unreadable bundle, documents section, denied gate, authoring-gate rejection, version-gate rejection, `409` conflict) return a `Failed` result carrying an `expected` marker — the wait mode maps it to `422`; a crash-class failure (vanished artifact, database error) answers `500`.

### Completion events and notification

Every terminal outcome publishes one event on the `core.Domain` stream — `domain_export_completed` / `domain_export_failed` / `domain_import_completed` / `domain_import_failed` — with the job id as the document id, the requesting account as `actioner_id`, no `mutation_id`, and an explicit empty fanout channel list (the same shape as the document import/export events; webhooks opt in by naming the event). The notification to the requesting account points at the `core.Domain` document itself (id = the domain name), not at a doctype document.

---

## Service API

All three modules are top-level singletons whose entry points return `Result | Facet::ServiceError`.

### `Domain::Portable::Export`

| Method | Returns | Notes |
|---|---|---|
| `Export.call(db, source_domain, *, with_documents = false, omit_secrets = false)` | `Export::Result \| Facet::ServiceError` | Builds the in-memory `Archive::Bundle`. Refuses a `draft = true` domain with a `422`. Returns `404` when the source domain does not exist. When `with_documents: true` is set, every non-deleted document of every user doctype in the source domain is captured into `bundle.documents`; the `core` domain is never captured as documents. When `omit_secrets: true` is also set, every `secret` marker in a captured document is replaced with `null` (`SecretStripper`) — the secret state is lost and the fields import unset. |

`Export::Result` carries the `bundle` plus the four summary counts (`doctype_count`, `document_view_count`, `collection_view_count`, `document_count`) so the CLI can print without re-querying.

### `Domain::Portable::Import`

| Method | Returns | Notes |
|---|---|---|
| `Import.call(db, bundle, *, merge = false, into = nil)` | `Import::Result \| Facet::ServiceError` | Applies the bundle to the database. The whole import runs in **one outer transaction** — any rejection rolls back every mutation produced so far. The import runs the same authoring validation the document pipeline runs on `iam.Roles`, `core.DomainGrant`, `app.App`, and `core.Domain` rows (B-277), the same battery on every bundled doctype definition (B-302 — see Authoring gate on bundled definitions), and the hard replication invariants — a row that fails one of them rejects the whole import with a `422` that names the doctype and the row. |

`Import::Result` carries the resolved `domain` name, a `created` flag (true on fresh import, false on merge), and per-type created / updated / unchanged / deleted counters (plus `documents_created` when the bundle carried documents).

### `Domain::Portable::Archive`

In-memory model + readers/writers. One file per concept under `src/domain/portable/archive/`: `bundle` (the model, the format constants, and the entry records), `writer` (directory, tarball, and zip writers, with the YAML emitter), `reader` (directory, tarball, and zip readers, with the archive IO and slug helpers), and `yaml_encode` (the YAML → JSON call point). `archive.cr` is the require root.

Auto-detects directory, zip, and tarball forms — by `File.directory?`, the path extension, and the file's magic bytes.

| Method | Returns | Notes |
|---|---|---|
| `Archive.read(path)` | `Archive::Bundle` | Raises `Archive::Error` on a missing bundle, unknown `format_version`, an unreadable archive, or an unsafe zip entry name (absolute path or `..` segment). |
| `Archive.write(bundle, path)` | `String` (absolute path written) | A path ending in `.zip` produces a zip archive (`Compress::Zip::Writer`); `.tar.gz` / `.tgz` produces a tarball via the system `tar` binary; any other path is treated as a directory and created if absent. Refuses to clobber a non-empty directory that does not look like a bundle (no `bundle.yml`). |
| `Archive.tarball?(path)` | `Bool` | True for paths ending in `.tar.gz` or `.tgz`. |
| `Archive.zip?(path)` | `Bool` | True for paths ending in `.zip`, or any file whose first four bytes carry one of the `PK` magic signatures. |
| `Archive.collection_view_slug(id, name)` | `String` | Sanitised slug for a `core.CollectionView` on disk. Opaque to import. |
| `Archive::FORMAT_VERSION` | `Int32` | Bundle format version the writer emits. Currently `2`. The reader also accepts `1` (see *Format history* above). |

Entry parsing goes through `Util::YamlInclude` (the `!read_file` tag driver), then converts the parsed YAML value to `JSON::Any` with `Util::YamlJson.to_json_any` (`src/util/yaml_json.cr`). The converter is generic; the archive keeps a private call point for it in `archive/yaml_encode.cr`.

### Container handling

**Zip** — produced and consumed by the stdlib `Compress::Zip` (no external binary, no new shard). The writer builds the directory tree in a tempdir, adds every file as a flat entry under its relative path, then removes the tempdir. The reader extracts into a tempdir and validates every entry name before any byte lands on disk: a name that is empty, absolute, or carries a `..` segment aborts the whole read — an archive arriving over HTTP is untrusted input. The reader locates the `bundle.yml` (one or two levels deep — a single top-level wrapper directory is supported), then delegates to the directory reader. CRC32 checksums verify on extraction.

**Tarball** — produced and consumed by shelling out to the system `tar` binary (`Process.run("tar", ["-czf", …])` for write, `tar -xzf` for read). Facet assumes a Unix-like environment — no shard is added for tarball support. The writer builds the directory tree in a tempdir (`File.tempname` under `Dir.tempdir`), invokes `tar -czf` from that directory so archive entries are relative, then removes the tempdir. The reader extracts into a tempdir, locates the `bundle.yml`, then delegates to the directory reader.

The HTTP surface produces and accepts zip; the import route also accepts tarballs (detected by magic bytes). The CLI keeps writing tarballs and directories; the fixture bundles are directories.

---

## What the bundle contains

| Source row | Captured? | Notes |
|---|---|---|
| `core.Domain` | yes | The single document for the source domain. The `draft` flag is rewritten to `false` on import — a bundle never resurrects a draft. Any declared hook scripts are externalized to `hooks/{i}-{hook_id}.lua` sidecars. |
| `core.DocType` (every non-deleted doctype whose `content.domain` equals the source domain) | yes | Qualified id (`{domain}.{doctype}`) is the file basename. The lifecycle `script` is externalized to a co-located `doctypes/{Qualified}.lua` sidecar. |
| `core.DocumentView` (every non-deleted child of each doctype, joined via `meta.parent_id`) | yes | Keyed by qualified doctype, enumerated by `kind`. Children are always definition-owned — there is no personal DocumentView. |
| `core.CollectionView` — **general** (owner-less) | yes | Personal views (`owner_id` present) are excluded — they are user data. See [`doc/backend/collection-view.md`](collection-view.md) → General vs Personal. |
| `core.CollectionView` — personal | no | User data; never exported, never deleted by merge. |
| Document data (any user doctype's live documents) | **opt-in** (`--with-documents`) | Default off. When enabled, every non-deleted document of every user doctype in the source domain is carried under `documents/{qualified}/{doc_id}.yml`. The `core` domain is never captured as documents — those rows are already carried as definition entries. |

---

## Import behaviour

### Atomicity

`Import.call` wraps every mutation in **one outer transaction** (`Database.with_transaction(db, ignore_if_set: true)`). Any `ImportError` raised inside aborts the transaction; no partial state remains. The caller receives a `ServiceError` (422 or 409) with the rejection reason.

### Unique constraints on bundled documents

A bundled document lands through `Mutation::Client.create` — the full `Document::Create` validation does not run — but the `unique: true` field constraints do: every document row the import creates is checked with `Document::UniqueConstraint` against the target's live rows (and earlier rows of the same batch) inside the import transaction. A violation aborts the import with a `422` naming the bundle file (`documents/<qualified>/<doc_id>.yml`) and the field; no colliding row lands. A non-colliding merge still succeeds.

### Authoring gate on bundled definitions

Before the import persists a bundled definition it runs the authoring battery the REST door runs on a `Doctype::Create` save (B-302): `Doctype::Validation.validate`, `ScriptValidator.validate`, `DraftTargetCheck.validate`, and `RBAC::Validator.validate_named_scopes_for`. The gate covers both persist paths — the fresh branch and the merge branch's missing-doctype create. On the merge branch's version-gated update the schema and script checks already ran inside `validate_version_gate!`; the draft-target and named-scope checks run there too. A bundled definition the authoring API would refuse therefore never lands: the first violation aborts the import with a `422` naming the qualified doctype id, and the transaction rolls back. Imported domains are never drafts (a draft bundle is rejected before any write), so the strict validators run unconditionally.

An empty `script` is "no script": the direct `ScriptValidator` pass only runs when the script is non-empty, mirroring `Doctype::Validation`'s empty-script branch. A definition that declares `actions` or `migrations` with an empty script is still refused — `Doctype::Validation.validate` rejects it with "actions are declared but no script is defined".

### Secret-leaf gate on bundled documents

A bundled document row bypasses the document pipeline, so the secret gate the write door runs never saw it. The import now runs the same gate on every bundled row (B-370): `SecretType#validate` for the leaf shape (a plaintext string or a malformed marker answers `422` naming the field), then `Secrets::Adoption.call` for handle/marker semantics. A bundle carries no secret material: a stage handle has no staging row on the importing instance, and a shape-valid marker with no matching slot row is a forged state — both refuse with `422`, and the transaction rolls back, so no mutation row persists. The payload is never redacted or rewritten (`mutations` is the replay source). A bundle whose `secret` leaves are absent or `null` imports unchanged. To move a domain that carries set secrets, export it with `--omit-secrets`: every marker becomes `null`, so the bundle imports and the fields land unset (the secret state is lost).

### Replication invariant gate

After every bundled definition lands (fresh and `--merge`), the import runs `Replication::Validator.validate_invariants` over each one — the same hard gate `Doctype::Create` and `Doctype::Update` run before persist. The first violation aborts the import with a `422` naming the doctype, and the transaction rolls back, so no partial bundle remains. The check runs after the whole doctype loop, not per doctype: a bundle may order the consumer before its producer, and a per-doctype check would silently skip a source that has not landed yet. The bundled `$force` flag does not relax the gate.

### Grant tickets for cross-domain edges

After the bundled doctypes land (fresh and `--merge` both), the import runs the same `Grants::PublishTickets` scan the publish flow runs over the landed definitions and the target domain's hooks: every outbound cross-domain edge files or merges a `core.DomainGrant` ticket in the producer's subtree (see [`domain-grants.md`](domain-grants.md) → Import flow). The import is a system actor, so tickets file **inactive** — the producer's acceptance stays explicit. `Import::Result.grant_tickets` carries the report; the CLI prints one line per ticket. An imported replicate edge is therefore never silently inert: the ticket exists, waiting for the producer's activation.

### Reader errors name the file

Every unreadable entry aborts the read with an `Archive::Error` naming the path — a YAML syntax error (`<file>: line N: …`), a missing entry file (`<file>: file does not exist`), or a missing `!read_file` sidecar. The CLI renders one clean line; no Crystal backtrace reaches the operator.

### Branches

| Target domain state | `--merge` | Behaviour |
|---|---|---|
| Does not exist | off (default) | Fresh import — creates the domain, every doctype, every view. No version gate (the bundle is the initial state), but the authoring gate on bundled definitions still runs. The bundle's composition graph must close: every `children:` entry reciprocated by a `member_of` on its target and vice versa (`Doctype::Composition.validate`, hard `422` on a one-sided edge). |
| Exists | off | Rejected with `409 "Domain … already exists; pass --merge to overwrite."` |
| Exists | on | Merge — every bundled doctype goes through the version gate, DocumentViews are reconciled to match the bundle (created / updated / deleted), general CollectionViews are upserted (created / updated; **never** deleted — see below). |
| Does not exist | on | Fresh import — identical to the default branch: the domain, every doctype and every view are created. No version gate. `--merge` never fails on the target's existence. |

### `--into` rename

`--into targetname` remaps the bundle's `source_domain` to `targetname` before applying. Every qualified doctype id (`{source}.{doctype}` → `{target}.{doctype}`), every doctype `content.domain`, every same-domain reference target declared inside doctype definitions (`fields[*].doctype`, including `items` / `properties` / dictionary `values` sub-schemas — the same relink publish uses, see [`draft-domains.md`](draft-domains.md) → Reference-target relink), every `core.DocumentView` `parent_doctype`, every child `meta.parent_id`, every document id, every reference token inside document content, and every document `meta.parent_id` is rewritten to the target identity. The bundle's `core.Domain` content has its `id` and `draft` fields rewritten too.

When multiple bundles are imported in one batch, `--into` accepts a comma-separated list aligned with the positionals (`a.facet-domain,b.facet-domain --into x,y`); each value renames its own bundle. A single `--into` value combined with multiple paths is rejected. `--into` is orthogonal to `--merge` — a bundle can be cloned into a fresh target under a new name, or merged onto an existing target under a new name.

### Version gate (merge branch)

Mirrors `Doctype::Update`'s gate. Each bundled doctype is upserted against the target's live projection. Rejections surface as `422` with the specific reason (messages are prefixed with the bundled doctype's qualified id):

| Condition | Rejection |
|---|---|
| Doctype identity (`doctype` field) changed | `"doctype identity cannot change (old → new)"` |
| `domain` field does not match the target | `"domain field 'X' does not match target 'Y'"` |
| `schema_version` decreased | `"schema_version cannot decrease (current: N, got: M)"` |
| `schema_version` jumped more than +1 | `"schema_version must be exactly N+1 (got: M) for a breaking change"` |
| Same version with `migrations` | `"same-version edit must not include migrations (use schema_version + 1)"` — never relaxed by `$force` |
| Same version, field removed without `$force` | `"same-version edit cannot remove fields: … Use schema_version bump with a migration, or pass $force: true."` |
| Same version, field type change without `$force` | `"same-version edit cannot change type of field 'name' (old → new). Use schema_version bump with a migration, or pass $force: true."` |
| Same version, any other non-additive data-shape change without `$force` (nested sub-schema edits, `collection` flips, constraints, enum key removal/reorder, reference surface, `children`, `member_of`) | `"<qualified>: same-version edit cannot change the doctype's data shape: <a; b>. Use schema_version bump with a migration, or pass $force: true."` — additive edits (new field key, new enum key, new nested property key, new `children` entry) stay legal; see [`doctype-system.md`](doctype-system.md) → Version gate |
| Version bump whose migration function is missing | `"script validation failed"` — the script-validation detail names the missing function (`"Migration from vN expects function 'f' in script, but it was not found"`) |

The bundled doctype's `$force: true` flag (set on the source definition root) is honoured — it relaxes the same-version data-shape rejections (field removal, field type change, and every other non-additive data-shape change listed in the table above), as an editor-driven `Doctype::Update` with `$force` does. It does **not** relax the same-version `migrations` guard, and the version rules (no decrease, no jump past +1) stay enforced. The flag is stripped before persist, so the stored row and a re-exported bundle never carry it.

### Document-view reconciliation (merge branch)

For each doctype in the bundle, the target's live DocumentViews are compared by `kind`:

- Bundle carries no views for the doctype → the target's views stay untouched. The bundle states nothing about views: a bundle may re-declare a doctype without owning its views (for example, the `iam` fixture bundle re-declares the seed doctypes whose views the core seed owns). Same rule as the collection-view reconciliation below.
- Bundled kind absent from target → created.
- Bundled kind present and content differs → updated via `Mutation::Client.update` (JsonDiff).
- Bundled kind present and content identical → unchanged.
- Target-only kind (not in bundle) → soft-deleted via `Mutation::Client.delete`. This applies only when the bundle carries at least one view for the doctype — a merge import cannot delete every view of a doctype; delete views explicitly instead.

### Collection-view reconciliation (merge branch)

General `core.CollectionView` rows are matched by `content.name`. Bundled views not on the target are created; existing views with differing content are updated. **Target-only general views are never deleted** — general views are live-authored (mirrors the publish action: CollectionView rows are out of scope for the domain definition) and may carry user customisations the bundle does not know about. The operator must delete unwanted views explicitly.

### Side effects

Every mutation runs the same side effects as `Domain::Copy.upsert_doctype_definition` and `Document::Copy.deep_copy`:

- `Event::Publisher.enqueue` (event: `created` / `updated` / `registered`)
- `Index::Manager.sync` for new and updated doctype definitions
- `Doctype::DefinitionStore.invalidate` after each doctype upsert

The doctype and view-child writes are raw mutations, so they stage the projection GUCs themselves (`Document::ProjectionGucs.set_all` — from the stored `core.DocType` definition for `core.DocType` rows, never from the bundled definition being written; the create branch shares `Domain::Copy.upsert_doctype_definition` with publish, and the merge branch stages from `DefinitionStore.fetch(txn, "core.DocType")` — from the target view doctype's stored definition for `core.DocumentView` / `core.CollectionView` rows; the no-definition branch stages empty GUCs). An unstaged GUC stores NULL derived columns and the row then matches nothing on `filters[search]`.

`Index::Manager.sync` runs synchronously in the CLI (`Facet::Index::Manager.synchronous = true` at the top of `CLI.run_export` / `run_import`).

All import-authored mutations use the actioner id `"system:import"` so they are distinguishable from `system:publish` and `system:migration` in the audit log.

---

## Document data

When the bundle was exported with `--with-documents`, every document of every user doctype in the source domain is replayed on the target as a `Mutation::Client.create`. The `core` domain is never captured as documents — its definition rows (`core.Domain`, `core.DocType`, `core.DocumentView`, `core.CollectionView`) are already carried as definition entries.

### Document write path

For each bundled document the import:

1. Splits the qualified doctype id (`{domain}.{doctype}`) into its `domain` / `doc_type` segments.
2. Stages the projection GUCs (`Document::ProjectionGucs.set_all`) by fetching the doctype definition from `DefinitionStore` — same code path as `Document::Create`. Falls back to `ProjectionGucs.clear_all` when the definition is unparseable (e.g. `core.Domain` grants with `type: any`).
3. Writes the row via `Mutation::Client.create` with `actioner_id: "system:import"`.

Before step 2 the import calls `Replication::SyncPull.call` on the staged content when the definition declares replicate fields — same semantics as `Document::Create` — so bundled rows land with their replica values already pulled. The pull is best-effort within the import transaction: a source document that has not landed yet (e.g. a cross-bundle reference resolved later in the batch) leaves the replica null, mirroring the create path on a missing source.

The doctype definitions are created **before** the documents so every `DefinitionStore.fetch` in step 2 resolves within the import transaction.

### Rewrite rules under `--into`

When the bundle's source domain is renamed to `target` during import, every `{source}.`-prefixed value is rewritten to `{target}.`. This applies to:

- The document id (e.g. `crm.Company.1` → `target.Company.1`).
- Every string scalar inside `content` that starts with `{source}.` — most importantly cross-doctype `reference` tokens (e.g. `owner_id: "iam.Account.acc_admin"` on an `hr` bundle imported `--into hr2`).
- The `meta.parent_id` link to a parent document when it carries the qualified id.

The rewrite is by **domain segment**, not by string prefix: the leading segment is matched against the source domain exactly (so a value like `crm.crm` is never turned into `target.crm`). Free-form ids (`exp_a1`, `cand_01HZX9Q2`) that do not start with `{source}.` are left untouched.

References to doctypes outside the bundle (e.g. an `iam.*` reference inside an `hr` bundle imported `--into hr2`) are NOT rewritten — the reference target did not move. Cross-domain reference integrity is never enforced (see *Cross-domain references* below).

### Post-commit display_name and search backfill

A doctype whose `display_name` template contains at least one `$<field>` token naming a `reference` field may have stored the type-label fallback at write time if the referenced doctype was created later in the same transaction. After a successful document import, the import recomputes `display_name` for every such doctype and UPDATEs rows whose stored value drifted — `Domain::Portable::Import#refresh_reference_display_names` mirrors the post-commit backfill `Document::Create` would have run if every reference target already existed. When the doctype declares no `search` template, the same UPDATE also refreshes the `search` corpus from the new label — the fallback corpus is the folded `display_name` (see [`search.md`](search.md) → The searchability flag). A doctype with a `search` template keeps its stored corpus; the import does not re-render templated corpora on this path. Only runs when at least one document was created; a definition-only import never enters this branch.

### Idempotency

Document creation on import is idempotent: a row whose `(domain, doc_type, id)` already exists on the target (non-deleted) is skipped. Re-importing an identical bundle with `--merge` produces no new mutations. Document updates on merge are **out of scope** — the operator should `db_reset` and re-import to refresh data.

---

## Cross-domain references

**Cross-domain reference integrity is never enforced.** A bundled doctype's `references` array may target a doctype that does not exist on the importing instance (e.g. an `iam` reference on a freshly-cloned `crm` bundle before `iam` itself is imported). This is by design — Facet documents may reference objects that do not exist; the resolver surfaces them as unresolved links at read time. The import does not validate `references` targets and does not block a bundle that references a missing doctype.

---

## Defence in depth

- `Export.call` refuses a `draft = true` domain at export time (422).
- `Import.call` re-checks the bundled `core.Domain` content's `draft` field at import time (422), so a hand-crafted bundle cannot resurrect a draft.
- The bundle format version is checked on read. An unknown future version is rejected with `Archive::Error` rather than silently loaded.

---

## Relationship to other concerns

- [`draft-domains.md`](draft-domains.md) — Drafts (`draft = true`) are throwaway by design and never portable. Publish a draft to a live domain first, then export the live domain.
- [`collection-view.md`](collection-view.md) — General vs Personal CollectionView distinction drives what the bundle captures.
- [`doctype-system.md`](doctype-system.md) — The version gate and `$force` semantics mirror `Doctype::Update`'s behaviour.
- [`cli.md`](cli.md) — `domain:export` and `domain:import` CLI entry points.
- [`shared/fixtures.md`](../shared/fixtures.md) — The `data/fixtures/` directory IS this bundle format; `scripts/import-fixtures` runs `domain:import` across every fixture bundle in dependency order (`production` before `iam` — the import authoring gate validates bundled role scopes against registered doctypes).
