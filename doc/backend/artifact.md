# Artifacts

File storage for `file`-typed doctype fields and inline `urn:facet:artifact:…` links in longtext. Bytes live in object storage (S3 via shrine); metadata and access control live in PostgreSQL.

**Files covered:** `db/migrations/0003_artifacts.sql`, `src/artifact/config.cr`, `src/config.cr`, `src/doctype/field_types/file_type.cr`, `src/document/artifact_refs.cr`, `src/artifact/uploader.cr`, `src/artifact/store.cr`, `src/artifact/access.cr` (incl. `can_read_for_app?`), `src/artifact/grants.cr` (incl. `mint_ephemeral_for_app`), `src/artifact/upload_grants.cr` (signed upload capability), `src/artifact/routes.cr` (incl. the `/download` gateway; route bodies are private `handle_*` helpers, the download route `serve_*` helpers, and the shared `perform_account_upload` tail), `src/artifact/serve.cr` (`Artifact::Serve` — `stream_artifact`, `parse_range`, `stream_range`), `src/artifact/multipart.cr`, `src/artifact/owners.cr`, `src/artifact/prune.cr`.

> Scope of this document is the artifact subsystem: the data model, the two invariants, the transversal-by-design rationale, the dedup timing oracle, upload, multipart intake, access control, signed grants, and the owner-append lifecycle flows. Reference tracking (`Document::ArtifactRefs`) is implemented and documented in [`document.md`](document.md#documentartifactrefs). Prune and reconcile are documented in [`doc/backend/cli.md`](cli.md).

---

## Storage layout (env split)

Artifact bytes live in one object storage, declared under `artifact.storage` in `config.{env}.yml` (see Configuration below). The filesystem backend roots under `tmp/uploads/<env>/store`: dev writes to `tmp/uploads/dev/store`, tests write to `tmp/uploads/test/store`. The split keeps test artifacts out of the dev tree (which `make run` writes into live) and lets the spec suite sweep `tmp/uploads/test/` on teardown without touching developer data. `spec/spec_helper.cr` registers `teardown_test_uploads` on both `Spec.after_suite` and `at_exit` so the directory is removed at the end of every test run, mirroring the per-worker database teardown contract.

---

## Design invariants

Two rules govern every design decision in this subsystem. If a change would violate either, raise the concern rather than work around it.

### 1. `artifacts` holds content facts only — no domain, no owner, no publicity.

The table stores derived facts about the bytes (`filename`, `mime_type`, `size`, `signature_sha256`, `path`, timestamps). It carries nothing that could participate in an access decision. Dedup merges rows on `signature_sha256`; if anything access-bearing lived here, it would be shared between unrelated uploaders the moment their bytes collide.

Access-bearing data lives on `artifact_owners` (provenance), `artifact_grants` (signed URLs), and `artifact_references` (prune bookkeeping).

### 2. `artifact_owners` rows are append-only.

They are removed only when their document or domain is removed (via cascading FKs), or when the artifact itself is destroyed by a force delete (the `DELETE FROM artifacts` cascade — see *Force delete* below). A flow that puts an existing artifact id into a new document *appends* an owner row; it never edits or moves one. This is what makes provenance non-repudiable: the row that authorised the original upload stays on the books for the lifetime of the document it was uploaded against.

---

## Transversal-by-design and the prune consequence

`artifacts` has no `domain` column. An artifact belongs to no domain — the artifact store is its own domain, whose job is holding bytes. Domains reach into it by reference, recorded in `artifact_owners` and `artifact_references` (both domain-scoped).

Domain drop therefore cleans `artifact_owners` and `artifact_references` (both domain-scoped; `Domain::Scratch.drop` deletes them by `domain`, and `artifact_grants` cascade via `owner_id → artifact_owners`), but leaves `artifacts` rows untouched. Those rows fall out on the next **prune**, whose eligibility is join-derived:

```sql
SELECT a.id
FROM artifacts a
WHERE a.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM artifact_owners o
    JOIN <live document check> ON o.doc_id = …
    WHERE o.artifact_id = a.id
  )
  AND NOT EXISTS (
    SELECT 1 FROM artifact_references r
    WHERE r.artifact_id = a.id
      AND r.last_reference_at > now() - ($1 || ' days')::interval
  );
```

Both `NOT EXISTS` clauses are required. The owner clause needs the live-document join — an owner row pointing at a tombstoned document must not keep bytes alive forever. Checking references alone would miss artifacts that have owners but no references, and vice versa. See [`doc/backend/draft-domains.md`](draft-domains.md) for the domain drop flow.

---

## Dedup timing oracle (known accepted risk)

At upload time, the system looks up candidate rows by `signature_sha256` and reuses the first one the caller can already read, skipping the object put. A non-readable candidate prompts a second copy rather than refusing the upload or handing the caller someone else's bytes.

The consequence: **upload timing reveals whether identical bytes already exist anywhere in the system, across all domains.** A caller who uploads the same payload twice and observes a fast (reused) response knows the bytes existed under a readable provenance; a slow response (spooled to disk + put) means no readable candidate existed. This is documented and accepted — the alternative (always re-put, never dedup) would forfeit the storage savings that motivate the design. See the Upload section of the implementation plan.

The `signature_sha256` index on `artifacts` is **not `UNIQUE`** — that is by design, not an oversight. Two unrelated uploaders may legitimately store the same bytes when neither can read the other's row.

---

## Data model

| Table | Purpose | Tracked in this doc because |
|---|---|---|
| `artifacts` | Content facts (size, mime, sha256, path, timestamps). Never access-bearing. | Invariant #1. |
| `artifact_owners` | Provenance — who uploaded which bytes, against which document field. Drives the ACL. | Invariant #2. |
| `artifact_grants` | Signed capability URLs — the only path bytes reach an unauthenticated caller. | See `db/migrations/0003_artifacts.sql` for the column layout. |
| `artifact_references` | Prune bookkeeping. Projections rebuilt from the mutation log. Never participates in an access decision. | Prune consequence above. |

Column-level details are in `db/migrations/0003_artifacts.sql`. Three shape notes worth surfacing:

| Column | Note |
|---|---|
| `artifacts.path` | The shrine key, in the form `{sha256}/{ulid}`. Stable across dedup decisions — when bytes are reused, the existing row's `path` is kept. |
| `artifact_owners.field_path` | Normalized, array indices included (e.g. `avatars[0].file`). Resolves unambiguously against the doctype definition at read time. The same normalizer produces `artifact_references.resource_field`. |
| `artifact_owners.view_tag` | A snapshot of the field's `tags` (`FieldDefinition#tags`) at upload time. Tightening a field's tags takes effect immediately; loosening doesn't retroactively widen artifacts uploaded under the stricter tags. A `field_path` that no longer resolves in the doctype fails closed. |

---

## Configuration

The artifact subsystem reads four top-level YAML keys plus an `artifact:` section (which carries the required `storage` key). All live in `config.{env}.yml` and are surfaced through `Facet::Config`.

### Required keys (fail loud at config load time)

| Key | Type | Notes |
|---|---|---|
| `artifact_base_url` | `String` | The separate origin that serves artifact bytes (e.g. `https://cdn.example.tld`). Served without cookies, CORS blocked. `Facet::Config` raises when absent. |
| `artifact_grant_secret` | `String` | HMAC secret for grant signed URLs. May be supplied via the `ARTIFACT_GRANT_SECRET` env var instead of YAML (production deployments should use the env var). An empty value raises at config load. |

### Optional keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `base_url` | `String` | falls back to `host` | The API origin. Distinct from `host` so the WebSocket origin check and the API origin can diverge. |
| `artifact_grant_secret_previous` | `String?` | `nil` | Enables two-key rotation. May be supplied via the `ARTIFACT_GRANT_SECRET_PREVIOUS` env var. |

### `artifact:` section (`Facet::Artifact::Config`, `src/artifact/config.cr`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `storage` | `Storage` | — (required) | The object storage that holds artifact bytes. Required — `Facet::Config` raises at load time when the entry is absent, empty, or malformed. See the storage table below. **File-only:** the Shrine storage wires once per process, so the adapter is deployment material, not a runtime knob. |
| `prune_after_days` | `Int32` | `30` | Eligibility window for prune. An artifact whose `artifact_references` rows are all older than this is treated as unreferenced by the references clause. `0` keeps every artifact forever — the prune returns nothing. **Hot key:** resolves through `core.SystemSettings` at every prune run — see [`system-settings.md`](system-settings.md). |
| `grant_ttl_seconds` | `Int32` | `3600` | Signed-URL TTL for non-media types (documents, images). Long enough to outlive a normal "render page → click link" round-trip on human-paced browsing. **Hot key:** resolves at every ephemeral mint. |
| `grant_ttl_media_seconds` | `Int32` | `21_600` | Signed-URL TTL for `audio/*` and `video/*` — long enough that a seek mid-playback doesn't hit an expired URL. **Hot key:** resolves at every ephemeral mint. |
| `max_upload_bytes` | `Int64` | `52_428_800` (50 MiB) | Hard cap on a single upload's body size. Enforced before the request touches disk so an oversized upload returns `413` without spooling a tempfile. |
| `upload_grant_ttl_seconds` | `Int32` | `300` | TTL of a signed upload capability (`Artifact::UploadGrants`) — the one-time URL an MCP agent POSTs its multipart body to. Short by design: a mint-to-upload gap is seconds, not hours. |

`artifact.storage` fields (`Facet::Artifact::Config::Storage`):

| Field | Type | Default | Notes |
|---|---|---|---|
| `type` | `String` | `"filesystem"` | `"filesystem"` or `"s3"`. Another value raises at config load. |
| `directory` | `String` | `tmp/uploads/dev` | Filesystem: the storage root directory. S3: the key prefix inside the bucket. An empty value raises at config load. |
| `bucket` | `String?` | `nil` | S3 only. Required when `type` is `"s3"`. |
| `region` | `String?` | `nil` | S3 only. Required when `type` is `"s3"`. |
| `access_key_id` | `String?` | `nil` | S3 only. Falls back to the `S3_ACCESS_KEY_ID` env var. |
| `secret_access_key` | `String?` | `nil` | S3 only. Falls back to the `S3_SECRET_ACCESS_KEY` env var. |
| `endpoint` | `String?` | `nil` | S3 only. Falls back to the `S3_ENDPOINT` env var. Set it for S3-compatible backends (MinIO, R2, Backblaze). |
| `public` | `Bool` | `false` | Reserved for a public-read backend; the serving path always goes through signed grants. |

The storage entry is validated at config load: an `s3` storage must carry `bucket`, `region`, and both credentials (YAML or the env fallback above), or the boot stops with a message naming the missing fields. A misconfigured storage therefore cannot boot green and fail on the first upload.

### Example

```yaml
base_url: "https://Api.example.tld"
artifact_base_url: "https://cdn.example.tld"
artifact_grant_secret: "rotated-secret-…"
artifact_grant_secret_previous: "previous-secret-…"

artifact:
  prune_after_days: 30
  grant_ttl_seconds: 3600
  grant_ttl_media_seconds: 21600
  max_upload_bytes: 52428800
  upload_grant_ttl_seconds: 300
  storage:
    type: s3
    bucket: facet-artifacts
    region: eu-west-1
    directory: artifacts   # key prefix inside the bucket
    # access_key_id / secret_access_key / endpoint come from the
    # S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY / S3_ENDPOINT env vars.
```

### Publishing permanent grants (named-action convention)

Minting a permanent grant is a separate permission from reading. A grant is minted against an owner row, which is a document — so it uses the existing RBAC named-action grammar with no language extension:

```json
{"action": "publish_artifact", "on": "cms.Asset", "scope": …}
```

Doctype authors declare `publish_artifact` in the `actions` map of any doctype whose attachments may be exposed to the internet. A doctype that does not declare the action has no publishable attachments — that is the intended default. A role must declare `publish_artifact` on the leaf doctype; `read` alone is insufficient to mint a permanent grant. See [`doc/backend/rbac.md`](rbac.md) → Named-action conventions.

---

## Upload

One multipart request. No chunking, no session, no pre-flight. The uploader lives in `src/artifact/uploader.cr` (`Artifact::Uploader.upload`) and is driven by the multipart intake below.

```
1. Parse multipart, enforce max_upload_bytes → 413.        (before touching disk)
2. Spool to tempfile, compute sha256.
3. Look up candidate rows by sha256.
     → first candidate the caller can read: reuse it, skip the put.
     → none: shrine put, remember the path.
4. Transaction: insert artifacts row (if new) + artifact_owners row [+ document mutation].
5. On error: delete the object we put (ignore failures), re-raise.
6. Always: delete the tempfile.
```

Only delete an object this request uploaded — when step 3 reused an existing row, there is nothing of ours to clean up. Worst case on a crash between put and rollback is one hanging object, swept manually by `artifacts:reconcile`.

The sha256 index is not unique because of step 3: if the caller cannot read the existing row, we store a second copy rather than refusing the upload or handing them someone else's bytes.

`mime_type` comes from magic bytes, never the client's `Content-Type`. Unknown → `application/octet-stream`. Two refinements apply:

- The markup probe is ASCII case-insensitive over the first 64 bytes (`<!doctype` / `<html` in any case), so a build that opens with a lowercase `<!doctype html>` sniffs `text/html`.
- The deploy route (`POST /Api/app/:id/deploy`) decides the type from the part's file-name extension first (a static server-side table: `.html` → `text/html`, plus css, js, fonts, images, and other web-build types), with the sniffer as fallback. The type stays a pure function of (file name, bytes) — dedup still freezes `mime_type` on the `artifacts` row at first upload, and serving reads the stored row.

## Signed upload capability (`src/artifact/upload_grants.cr`)

Agent surfaces (MCP) cannot call the REST upload route: an MCP bearer carries the MCP resource `aud`, which the REST audience rule rejects. The bridge is a **one-time signed upload capability**: the `request_artifact_upload` agent tool mints it, and the agent's plain HTTP client POSTs the multipart body to it. No file content ever rides the JSON-RPC channel, so the MCP envelope caps never bound a file.

`Artifact::UploadGrants` mirrors the `OAuth::CodeStore` contract:

- **Single-use** — the consume is a read-then-delete Lua script; the first POST wins, every later POST of the same URL answers `already_used`.
- **TTL-bounded** — `artifact.upload_grant_ttl_seconds` (default 300). The Redis key (`artifact_upload:<uid>`) outlives the signed expiry by five seconds so the `exp` check, not the key's disappearance, stays the authority on the failure reason.
- **Bound to its issuance context** — the record carries the minting principal's `account_id` and the qualified `role_id`. Consume revalidates live state (account active, role still held, role projection exists — the same checks `MCP::Dispatch` and `OAuth::Refresh.call_mcp` run) before the upload runs; a mint does not freeze a stale principal.
- **Signed** — HMAC over `(uid, exp)` under `artifact_grant_secret`, base64url, constant-time compared (same secret and shape family as the download grants).

The route (`POST /A/upload/:uid`, registered in `src/artifact/routes.cr`) shares the standalone-upload tail (`perform_account_upload`): multipart gate (`415` before the consume, so a wrong content type does not burn the URL), size cap (`413` before disk), magic-byte MIME sniffing, and the `_account` owner convention with `doc_id` = the capability's account. Every failure answers `403` with a machine-readable `reason` — `invalid_signature` / `expired` / `already_used` / `stale` — the field an agent acts on (`expired` / `already_used` → re-mint; `stale` → re-mint after the account or role recovers).

The upload dedup runs under the rebuilt context (the minting role's readability), so reuse matches the MCP session's view. The resulting artifact is readable by the account until linked into a document — identical semantics to the REST standalone upload — and the re-attach flow (`Artifact::Owners.append_readable_for_document`) takes over once the agent puts the id into a document.

## Multipart intake (`src/artifact/multipart.cr`)

`POST /Api/{domain}/{doctype}` (create) and `PATCH /Api/{domain}/{doctype}/{id}` (update) accept a `multipart/form-data` body when the request `Content-Type` is `multipart/form-data`. The wire format:

- A part named `$content` carries the document JSON (the same convention `Document::CreateWithChildren` uses for compound bodies).
- One part per `file`-field, named by its **normalized field path** (`file`, `avatars[0].file`, `items[0].file`). Each part's bytes are spooled to a tempfile during parse.

`Artifact::Multipart.parse` spools the parts; `Artifact::Multipart.upload_files` runs inside the mutation transaction, resolves each part's field path to a `file` leaf (via `ArtifactRefs.resolve_field_path`), snapshots the leaf's `tags` as the owner-row `view_tag`, uploads via `Artifact::Uploader.upload`, and substitutes the returned artifact id into the document JSON at that path. The create/update service layer then sees a plain document whose `file` fields hold bare artifact ids.

The upload and the document mutation share one transaction. On any failure `upload_files` raises `Artifact::Multipart::UploadFailed` (carrying the `ServiceError`); the route rescues it *outside* the transaction so the already-written owner rows roll back with the document — a multipart create/update is atomic. The spooled tempfiles are deleted by `Artifact::Multipart.cleanup` on every exit path.

## Owner-append lifecycle (`src/artifact/owners.cr`)

Any flow that puts an existing artifact id into a new document appends an `artifact_owners` row, provided the actor can already read the artifact and can write the target. No bytes are ever copied — artifacts are transversal, so a new owner row is the whole operation.

- **`Document::Copy`** — `deep_copy` walks the copied content and appends an owner row for every referenced artifact against the target document. The actor must be able to read each artifact (system bypasses); a non-readable artifact fails loud (`403`) and the copy rolls back to a savepoint, leaving no half-copied document. See [`document.md`](document.md).
- **Cross-domain replication** — when a replicated `file` field lands on a consumer document, `Replication::Handler` appends an owner row in the consumer domain so the artifact is readable through the consumer. See [`replication.md`](replication.md).
- **JSON re-attach / longtext share** — a JSON `create` / `update` that puts an existing artifact id into a `file` field **or embeds a `urn:facet:artifact:<id>` link in a longtext field** appends an owner row via `Artifact::Owners.append_readable_for_document`, called from `Document::Create` and `Document::Update` inside their mutation transaction. The actor must already be able to read the artifact (`Artifact::Access.can_read?`; system bypasses); a user who merely knows an id gets no owner row — no self-grant. A fabricated id with no `artifacts` row is skipped (lossless — no bytes to own). A non-readable artifact is **silently skipped**, never an error: a save must not break because the document links a file its editor cannot read (the link stays a dead capsule for that actor). The multipart path already records owner rows via `Multipart.upload_files`.

  The longtext link is the deliberate-share channel: embedding a URN shares the artifact with every reader of the document. The target longtext field's `view` tag is the **share ceiling** — the appended row snapshots it, and `Artifact::Access` covers both the snapshot and the live field view at read time, so marking a longtext field `view: ["confidential"]` confines its shares to confidential-tagged roles. Two consequences of the append-only invariant: removing the URN does **not** revoke the access it granted (same as `file` fields), and every share is auditable through the owner row's `created_by` and the mutation log.
- **`Domain::Publish`** — draft domains do not copy documents on publication (structure-only), so there are no published documents to clone owner rows for. Publish therefore does not append owner rows; this is by design (see [`draft-domains.md`](draft-domains.md) → Phase 2 boundary).

`Artifact::Owners.append` is idempotent — a duplicate `(artifact_id, domain, doc_type, doc_id, field_path)` insert collapses to a no-op via `ON CONFLICT DO NOTHING` at the SQL level (`Store.insert_owner_row_idempotent`). Idempotency is deliberately not implemented by rescuing the UNIQUE violation: rescuing a PG error inside a transaction aborts the transaction in PostgreSQL, so the caller's subsequent `COMMIT` would silently roll back the whole mutation.

## Serving

| Route | Auth | Purpose |
|---|---|---|
| `POST /Api/core/artifacts` | full (non-system) | Standalone upload — minted artifact id + metadata (no grant URL; fetch via `GET /Api/core/artifacts/:id`). See *Standalone upload* below. |
| `GET /Api/core/artifacts/:id` | full | Metadata + fresh grant URL |
| `POST /Api/core/artifacts/:id/grant` | `can_read?` | Mint ephemeral grant |
| `POST /Api/core/artifacts/:id/publish` | `publish_artifact` on owner doc | Mint permanent grant |
| `GET /Api/core/artifacts/:id/download?app=APP_ID` | cookie/bearer OR app-origin | Gateway: auth + `Access.can_read?(…)` + mint + `302` to the signed serve URL. The `?app=` query param is consulted **only** when an `Origin` header is present (the app-origin path); otherwise it is ignored and the request falls through to cookie/bearer auth. When the provenance check fails, a caller holding the operator `download *.*` action (deny-only-`Denied`) mints through the operator path instead of receiving `403` — see *Download gateway* below. |
| `DELETE /Api/core/artifacts/grants/:gid` | full | Revoke — system, `publish_artifact` on the owner document, or the operator `revoke *.*` action |
| `POST /A/upload/:uid?exp=…&sig=…` | signature only | One-time signed upload capability (agent surfaces). See *Signed upload capability* below. |
| `GET /A/:gid?exp=…&sig=…` | signature only | Stream bytes (artifact origin) |

Signed grants, the serve route, and byte streaming are implemented in `src/artifact/grants.cr`, `src/artifact/routes.cr`, and `src/artifact/serve.cr` (`Artifact::Serve.stream_artifact` writes the bytes, with range support); the signature format, expiry, two-key rotation, and response hardening are documented in [`doc/backend/http-layer.md`](http-layer.md) → Artifact route.

### Download gateway (`GET /Api/core/artifacts/:id/download`)

The gateway replaces the client-side mint-on-click pattern with a server-side route that performs auth + RBAC + grant mint + `302` redirect to the signed serve URL. The frontend renders a plain `<a href="/Api/core/artifacts/:id/download">` — no JS on click, no signed URL embedded in the page DOM, no staleness when the page is held open.

The response carries `Cache-Control: no-store` so each click re-enters the gateway and re-mints a fresh grant.

Two authentication paths, dispatched on the presence of `?app=` **and** `Origin`:

| Caller | Credential | Auth |
|---|---|---|
| Browser-session user (Facet's own frontend) | session cookie (same-origin top-level nav) | `Helpers.auth_context` + `Artifact::Access.can_read?`. Returns `401` when a presented credential is invalid, `403` when the caller may not read the artifact. A request that presents **no credential** runs under the anonymous role (`iam.Roles.anonymous`): the gateway evaluates the anonymous role's read grants, so a role-granted artifact downloads publicly — see [`rbac.md`](rbac.md) → HTTP integration. |
| Anonymous app-origin request (`<img>`, `<a>` from an app origin) | `?app=APP_ID` + `Origin` header matching an `allowed_origins` entry of `app.App` | `OAuth::OriginCache.app_for_origin(origin)` resolves the app id; it MUST equal `?app=` (cross-app impersonation guard). The app's `status` is re-checked against the projection row (defense-in-depth). The read is gated by `Artifact::Access.can_read_for_app?` against the app's grant ceiling (`RBAC::AppScope`). | 

The "ignore `?app=` when `Origin` is absent" rule: a shared link opened from curl, an email client, or any browser context that sends no `Origin` falls through to the cookie/bearer path, ignoring `?app=` entirely. This lets app integrators annotate download URLs with `?app=` without breaking non-browser shares.

### Operator path (`download *.*`)

When `Access.can_read?` denies — no readable owner row, every owner document tombstoned, or the field's view tags uncovered — the gateway consults one more gate before answering `403`: the operator action **`download *.*`** (deny-only-`Denied`, the same rule the admin listing applies). A caller holding the action mints through `Grants.mint_ephemeral_for_operator`, which binds the grant to the artifact's first owner row of any kind (`_account` standalone-upload rows qualify). `created_by` carries the operator's account id, so the grants table attributes these mints like any other.

The path exists because the artifact admin page lists every row of the store to `read *.*` holders; the same operator must be able to inspect the bytes behind the listing — provenance can never cover account-scoped standalone uploads (the uploader's own provenance) or artifacts whose provenance documents are gone. The privilege is explicit and grantable-auditable: a role holds `download *.*` only when the platform operator intends it, and it deliberately does **not** ride on `read *.*` — field view tags stay meaningful inside document views.

Two failures stay failures on this path: a tombstoned artifact answers `410` (`Grants.load_live_artifact`), and an artifact with **no owner rows at all** answers `403` — a grant needs an owner row to bind against, and such rows are prune-eligible debris; the operator purges them instead of downloading.

The app-origin path writes the grant row's `created_by` audit field as `"app:<app_id>"` (free-form text — `artifact_grants.created_by` is not FK-constrained; see `db/migrations/0003_artifacts.sql`). No account id and no `AuthContext` is built: the app's grant ceiling gates the read directly, and the view-tag gate (`tags_cover?`) is **skipped** — app permissions are doc-level, and field view tags are a per-role RBAC concern.

### Owner-append linkage

The gateway reuses `Grants.mint_ephemeral` / `Grants.mint_ephemeral_for_app`, which both bind the grant to a single owner row (`pick_readable_owner` / `pick_owner_for_app`). The serve route is unchanged.

### App deployment serving (outside the grant layer)

The deploy route (`POST /Api/app/:id/deploy`, `src/app/deploy.cr`) uploads an app build through the standard multipart intake — every `files[<i>].file` part becomes an `artifacts` row plus an owner row bound to the `app.Deployment` document, inside the deploy transaction.

Serving those bytes is **not** the grant layer and never walks ACLs: a published build is public by definition, and the app pointer (`app.App.host` + `active_deployment`) is the authorization. `App::Hosting::Handler` (`src/app/hosting.cr`) streams the mapped artifact with the stored `mime_type`, `nosniff`, and one conservative cache policy. Owner rows still exist for provenance and prune eligibility; see [`app-system.md`](app-system.md) → Deployment serving.

## Admin surface (`/Api/Artifacts`)

Read-mostly operator listing of the artifact store, backed by `Artifact::Admin` (`src/artifact/admin.cr`) and driven by the artifact management page at `/Configure/platform/artifacts`. The paths are pseudo-doctype (one segment after `/Api`, like `/Api/Indexes`) because artifacts are transversal — the store spans every domain. `HTTP::DomainGate` passes the `/Api/Artifacts` prefix through unchanged.

| Route | Auth | Purpose |
|---|---|---|
| `GET` / `QUERY` `/Api/Artifacts` | `read *.*` | Artifact listing with per-row counts: owners, live grants (permanent rows, or ephemeral rows not yet expired), references. Each row also names the original uploader — `uploaded_by`, the `created_by` of the earliest `artifact_owners` row; `null` when the artifact carries no owner row (a system upload). Same list grammar as `/Api/Indexes` (`page` / `items` / `filters` / `sort`) and the platform `{ data, meta }` shape with the capped count. Filters: `id__match`, `filename__match`, `mime_type__eq` / `mime_type__match`, `deleted__eq` (`"true"` / `"false"` — absent lists live rows only). Sortable: `filename`, `mime_type`, `size`, `created_at`, `deleted_at`. The QUERY form takes the parameters from a JSON body only |
| `GET /Api/Artifacts/:id/grants` | `read *.*` | Every `artifact_grants` row for the artifact, newest first. Capped at `Artifact::Admin::SUB_LIST_CAP` (500) with `meta.more` — a metadata view or a download-gateway click mints an ephemeral grant, so a hot artifact carries thousands of rows. Answers `404` for an unknown artifact. |
| `GET /Api/Artifacts/:id/references` | `read *.*` | The `artifact_references` rows — the "where is this file used" listing — joined with the referencing document's projection for `doc_type` + `display_name`. Same cap as the grants listing. |
| `DELETE /Api/Artifacts/:id` | `purge *.*` | Force delete — see *Force delete* below. CSRF-checked (`X-Requested-With`, API-key-bearer bypass); the optional JSON body carries `{reason}`. Answers `204`, `404` (unknown id), `403` (denied action or missing CSRF header), `422` (malformed JSON body). |

Authorization mirrors the managed-index status surface and the global audit log: the caller must hold a non-denied permission for `read` on `*.*` (deny-only-`Denied` — scoped results pass, because scopes resolve against doctype definitions and artifacts are not RBAC doctype targets; the artifact ACL is provenance-based).

Revocation from the admin page goes through the shared `DELETE /Api/core/artifacts/grants/:gid` route. Its gate accepts the operator action **`revoke *.*`** in addition to the publish privilege: system bypass, `publish_artifact` on the owner document, or `revoke *.*`. The publish privilege is checked first — a grant that a publisher may revoke stays publisher-scoped — and `read` alone is still insufficient.

## Agent surface (`list_artifact_refs`)

The MCP tool `list_artifact_refs` (`src/agent_tools/artifacts.cr`) serves
the same "where is this file used" question to agents, with a different
authorization shape: no operator action, per-record filtering. It
delegates to `Artifact::Refs` (`src/artifact/refs.cr`), which reads the
`artifact_references` rows — covering both `file`-field placements and
inline `urn:facet:artifact:<id>` longtext links.

| Gate | Rule |
|---|---|
| Artifact read | `Artifact::Access.can_read?` — provenance-based, the same rule as the metadata route. Unknown, tombstoned, ownerless, and denied ids collapse into one non-disclosing `NotFound`. This is stricter than `get_artifact`, whose denial surfaces as `RbacDenied`. |
| Referrer rows | Every returned document passed its own record's visibility: referrers are grouped by `(domain, doc_type)` and each group is filtered by that doctype's list scope clauses (`RBAC::ReadEnforcer.list_where_clauses`, which emits `1=0` for a doctype the caller holds no read grant on). Unreadable groups are skipped silently — an empty result is indistinguishable from "no references", the same non-disclosure as `get_backrefs`. |
| Cardinality | No total over all references is reported — it would leak how many documents point at the artifact, including unreadable ones. `meta.total` counts returned rows only; `capped` reports the `mcp.max_result_rows` stop honestly. |

Rows carry `{id, domain, doc_type, display_name, field, last_reference_at}`; tombstoned referrers are excluded (reference rows are dropped on delete, so a survivor is a transient race that yields nothing). The operator surface above stays the unfiltered view — two audiences for one table, the same split as the document side between the per-doctype `/backrefs` endpoint and the admin listings.

`0003_artifacts.sql` carries `artifact_grants_artifact_idx` on `(artifact_id)` alongside `artifact_grants_owner_idx`; the other two child tables already led their indexes with `artifact_id` (`artifact_owners_lookup_idx`, the `artifact_references` primary key), so the per-artifact counts and sub-listings are all index-backed.

## Force delete (`DELETE /Api/Artifacts/:id`)

A **security deletion** driven by `Artifact::Purge` (`src/artifact/purge.cr`). The operator destroys one artifact now: the bytes must become unreachable immediately, and dangling references in document content are accepted — a `urn:facet:artifact:` or `file`-field value that survives in a document renders a dead link and nothing more.

The gate is the operator action **`purge *.*`** (deny-only-`Denied`, with the system bypass) — a deliberate sibling of `revoke *.*`, not a ride-on of `read *.*`: destroying bytes is not implied by reading listings. One deletion covers every destruction path:

1. `DELETE FROM artifacts` inside a transaction — the cascade removes every `artifact_owners`, `artifact_grants`, and `artifact_references` row, so every signed URL stops verifying the moment the row is gone (`Grants.verify` reads a missing row as `Invalid`). The owner-row cascade is the third legitimate removal path of invariant #2 — the artifact itself is destroyed.
2. An **`iam.ArtifactEvent`** document is written **in the same transaction**, attributed to the operator (`actioner_id`). The event snapshots the content facts (`artifact_id`, `filename`, `mime_type`, `size`, `sha256`) and the child-table counts, because the artifact row is gone when the event exists — the record must identify the destroyed bytes on its own. `details` carries the operator's optional reason from the confirm dialog. The write is **fail-closed**, the deliberate contrast with the fail-silent `iam.LoginEvent` pattern: if the audit write fails, the purge rolls back — no artifact leaves the system without a matching audit record. The event rides the mutation log, so the audit page renders it with actor and timestamp, and `mutations` retention governs its depth (`mutations.retention_overrides` can extend the window for `iam.ArtifactEvent`).
3. After commit, the storage object is deleted — best-effort (failures logged; a miss is swept by `artifacts:reconcile`).

A tombstoned artifact purges too (the row keeps `path`), so the "Deleted" filter on the admin page is the operator's queue for finishing a soft prune early.

`artifacts:prune --hard` routes through the same primitive (`Purge.destroy_system`), attributed to `system` — every hard deletion is audited identically. The default prune is still a soft delete and writes no event: the row stays on the books until a later `--hard` or force delete destroys it.

## Standalone upload (`POST /Api/core/artifacts`)

A user uploads a file before knowing which document will hold it (typically: drag-and-drop into a longtext editor, then save). The standalone upload route drives the same `Artifact::Uploader.upload` machinery as the multipart create flow, but binds the owner row to the uploading account rather than to a document. The marker values are constants on `Artifact::Store`:

| Constant | Value | Column it populates |
|---|---|---|
| `ACCOUNT_OWNER_DOMAIN` | `"core"` | `artifact_owners.domain` |
| `ACCOUNT_OWNER_DOC_TYPE` | `"_account"` | `artifact_owners.doc_type` |
| `ACCOUNT_OWNER_FIELD_PATH` | `"upload"` | `artifact_owners.field_path` |

`artifact_owners.doc_id` carries the uploader's `account_id`. These rows never resolve against a `projections` row (no doctype is `_account`), so `Access.can_read?` short-circuits them by matching `owner.doc_id` against the caller's `account_id`. The system principal is refused (`403`) — system uploads would dangling forever (system has no `account_id` to bind against).

The import/export concern reuses this convention for its job artifacts (`ImportExport::Artifacts.put`): an export result, a staged import file, and the row manifest each get an `_account` owner row for the requesting account, so the requester can read their own bytes back through the gateway. A system requester writes no owner row — those artifacts stay ownerless.

### Dangling sweep (Option D)

A standalone upload has no `artifact_references` row until it is linked into a document. The prune eligibility query adds a `created_at` floor so a freshly-uploaded, never-referenced artifact survives at least one prune window — the uploader has time to drag-and-drop the id into a longtext (or paste it into a `file` field) and save before being swept. The default window is `prune_after_days` (`30`); operators who want a tighter sweep (e.g. 24h) set `prune_after_days: 1` in the `artifact:` section of the config — or pin the same knob on the settings page, which every later prune run picks up. A window of `0` keeps every artifact forever — the prune reports the disable and touches nothing.

When the longtext saves, `Document::ArtifactRefs.extract_longtext_value` finds the `urn:facet:artifact:<id>` and writes an `artifact_references` row whose `last_reference_at` keeps the artifact past the prune window. When the link is later removed, the reference row is dropped by `reconcile` (truncate-and-rebuild on every update), so the next prune sweep takes the artifact once it passes the window. The re-attach flow (`Artifact::Owners.append_readable_for_document`) also writes a document-scoped owner row when the id lands in a `file` field or is embedded in a longtext field, so the read ACL stops depending on the uploader's account owner row.
