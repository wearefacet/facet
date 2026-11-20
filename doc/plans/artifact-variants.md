# Plan — Artifact variants (derived renditions)

Status: **draft — awaiting review.** No code written. This plan was verified
against the tree on 2026-11-17 (schema `db/migrations/0003_artifacts.sql`,
`src/artifact/`).

Decisions already taken by the user (§8 records them):

- **D1 — flat schema.** Variants live in the `artifacts` table, distinguished
  by a column. No link table.
- **D2 — backend-generated.** The backend produces the variant bytes at upload
  time from a fixed preset set. Callers never upload a rendition.
- **D3 — ImageMagick.** Renditions are produced by the ImageMagick CLI.
  Video (ffmpeg) is out of scope.
- **D4 — skip on failure.** A preset that fails is logged and omitted. The
  upload still succeeds.

---

## 1. Summary

A **variant** is a second set of bytes derived from an uploaded artifact — a
resized, re-encoded image. It is stored as an ordinary `artifacts` row carrying
three extra columns, and it lives and dies with its source:

1. **Flat storage.** `artifacts.variant` (the label, `NULL` for sources),
   `artifacts.source_id` (the parent artifact id), `artifacts.variant_kind`
   (the preset that produced the bytes). One table, so "bytes used by this
   artifact set" is a `GROUP BY`, not a join.
2. **Swept with the source.** Purging a source deletes its variants in the same
   transaction. Pruning a source sweeps its variants in a second pass. A
   variant is never eligible on its own.
3. **Access derives from the source.** Variants carry no `artifact_owners`
   rows. `Artifact::Access.can_read?` resolves `source_id` and evaluates the
   source's provenance.
4. **Generated on upload.** `Artifact::Uploader.upload` runs the preset set
   over a generatable image and persists the source row and its variant rows in
   one transaction. A failed preset is logged and skipped (D4).

The schema work is small. The cost sits in the generation step: a new native
dependency, a process spawn per preset, a decode-amplification guard, and a
new failure surface inside the upload path (§4).

---

## 2. Current state (verified against the code)

### 2.1 `artifacts` is content facts only

`db/migrations/0003_artifacts.sql` defines `artifacts(id, filename, mime_type,
size, signature_sha256, path, deleted_at, created_at)`. Invariant #1
(`doc/backend/artifact.md`) says it carries nothing that could participate in
an access decision. A derivation column respects that: "this row came from row
X" is a fact about the bytes, not about who may read them.

The dedup index is `artifacts_dedup_idx ON artifacts (signature_sha256) WHERE
deleted_at IS NULL` — deliberately not unique.

### 2.2 The upload flow

`Artifact::Uploader.upload` (`src/artifact/uploader.cr`) runs:

```text
spool → sha256 → sniff mime → find_candidates_by_sha256
      → reuse (skip put) OR shrine put `{sha256}/{ulid}`
      → Store.persist_uploaded (one transaction: artifacts row + owner row)
      → on error: delete the object we put, re-raise
```

Two facts that shape the plan:

- **`persist_uploaded` is the only row-insert point** for uploads, and it runs
  inside the caller's transaction. Variant rows join it in the same
  transaction.
- **The dedup reuse path skips the put.** A reused source already has its
  variants from its first upload; nothing is generated.

Three callers reach `upload`: the standalone route
(`Routes.perform_account_upload`), the multipart document intake
(`Artifact::Multipart.upload_files`), and the app deploy route
(`src/app/deploy.cr`, `mime_from_extension: true`). A fourth writer,
`ImportExport::Artifacts`, calls `Store.insert_artifact` directly.

### 2.3 Prune and purge

`Artifact::Prune.eligible_ids` (`src/artifact/prune.cr`) has three clauses: not
tombstoned, no live-document owner row, no recent reference row, plus a
`created_at` floor. `Artifact::Purge.destroy_unchecked` (`src/artifact/purge.cr`)
runs `DELETE FROM artifacts WHERE id = $1` and writes one `iam.ArtifactEvent`
in the same transaction, then deletes the storage object after commit.

### 2.4 Serving and access

`Artifact::Grants.mint_ephemeral` gates on `Access.can_read?`, loads the
artifact row, picks a readable owner row, and signs a grant bound to
`(grant_id, artifact_id, epoch)`. `Artifact::Serve.stream_artifact` reads
`artifact.path` and `artifact.mime_type`. `Access.can_read?`
(`src/artifact/access.cr`) walks `artifact_owners` and the view-tag gate.

`Store.find_candidates_by_sha256` feeds dedup. `Document::ArtifactRefs` writes
`artifact_references` rows for every ULID it finds in `file` fields and
longtext URNs; those rows drive prune clause 3.

### 2.5 No image tooling in the stack

`shard.yml` has no image dependency. The host has ImageMagick 7
(`magick`, `identify`) and libvips (`vipsthumbnail`). The IM7 `convert` binary
prints a deprecation warning; the plan uses **`magick`** (§4.1).

---

## 3. Design

### 3.1 Schema (migration `0015_artifact_variants.sql`)

```sql
-- UP
ALTER TABLE artifacts
    ADD COLUMN variant       text NULL,   -- label; NULL = source artifact
    ADD COLUMN source_id     text NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    ADD COLUMN variant_kind  text NULL;   -- preset that produced the bytes

-- "the variants of X" — the serving lookup and the admin count.
CREATE INDEX artifacts_variant_source_idx
    ON artifacts (source_id) WHERE source_id IS NOT NULL;

-- One row per label per source.
CREATE UNIQUE INDEX artifacts_variant_label_idx
    ON artifacts (source_id, variant) WHERE source_id IS NOT NULL;

-- A variant row must name its source; a source must not.
ALTER TABLE artifacts ADD CONSTRAINT artifacts_variant_shape_chk
    CHECK ((variant IS NULL) = (source_id IS NULL));

-- DOWN
DROP INDEX IF EXISTS artifacts_variant_label_idx;
DROP INDEX IF EXISTS artifacts_variant_source_idx;
ALTER TABLE artifacts
    DROP CONSTRAINT IF EXISTS artifacts_variant_shape_chk,
    DROP COLUMN IF EXISTS variant_kind,
    DROP COLUMN IF EXISTS source_id,
    DROP COLUMN IF EXISTS variant;
```

Why three columns, not one:

| Column | Role |
|---|---|
| `variant` | Caller-facing label (`thumb`). The discriminator (`NULL` = source). |
| `source_id` | The edge. Answers "all variants of X" with one index. Also the purge cascade. |
| `variant_kind` | The preset that produced the bytes (`thumb_128_webp`). A snapshot, like `artifact_owners.view_tag`: changing the preset later does not rewrite history. |

`path` is **not** reused as the discriminator. It is the shrine key
(`{sha256}/{ulid}`) and `Artifact::Reconcile` compares it against storage keys;
overloading it would break reconcile and the dedup lookup.

The flat table gives the set-level totals the user asked for:

```sql
SELECT COUNT(v.id) AS variant_count, COALESCE(SUM(v.size), 0) AS variant_bytes
FROM artifacts v WHERE v.source_id = $1;
```

### 3.2 Access: derive, never duplicate

Variants have **no `artifact_owners` rows**. The invariant stays: an access
decision is made by provenance, and a variant's provenance is its source's.

```text
Access.can_read?(db, ctx, id):
  row = Store.find_artifact(db, id)
  return false if row.nil? || row.deleted_at
  return can_read?(db, ctx, row.source_id) if row.source_id
  ...existing owner-row walk...
```

- **Depth is 1 by construction.** The write path refuses to create a variant
  of a variant (§4.4). No recursion bound is needed; the single hop is
  documented.
- **Grants bind to the source's owner row.** `Grants.mint_ephemeral` resolves
  the source id before picking the owner, so `created_by`, revocation, and the
  operator path (`mint_ephemeral_for_operator`) are unchanged.
- **`can_read_for_app?` gets the same hop**, for the same reason.
- **Serving is unchanged.** `Serve.stream_artifact` reads the variant row's own
  `path` and `mime_type`.

### 3.3 Sweep

**Purge** — `Purge.destroy_unchecked` gains one statement before the delete:

```sql
DELETE FROM artifacts WHERE source_id = $1;
```

Both deletes and the audit write share the existing transaction, so the
fail-closed property holds. The `ON DELETE CASCADE` on `source_id` is the
backstop for any future caller that forgets.

**Audit shape (R5, decided here).** The existing event snapshots one artifact.
The purge event gains a `variants` array — one entry per destroyed variant
(`id`, `variant`, `size`, `sha256`) — on the source's event. One event,
fail-closed, and every destroyed byte set is still identified on its own. A
variant purge (a variant id passed to `DELETE /Api/Artifacts/:id`) answers `422`
with a reason naming the source: variants are destroyed with their source.

**Prune** — `eligible_ids` gains `AND a.source_id IS NULL`, so variant rows are
never evaluated on their own. After the sweep, a second pass tombstones the
variants of every swept source:

```sql
UPDATE artifacts SET deleted_at = now()
WHERE source_id = ANY($1) AND deleted_at IS NULL;
```

Sources first, variants second, never the reverse. Without the
`source_id IS NULL` guard a variant would fail clause 2 (no owner row) and
clause 3 (no reference row) and be swept on the first run while its source is
alive — the trap this plan exists to avoid.

`PruneCLI --hard` routes through `Purge.destroy_system`, so the variant delete
comes for free.

**Reconcile** is unchanged: variants are `artifacts` rows with their own `path`.

**Domain drop** is unchanged: `Domain::Scratch.dispose!` deletes owner and
reference rows by domain and leaves `artifacts` rows to prune; variants have no
owner rows and follow their source through prune.

### 3.4 Generation

New module `Artifact::Variants` (`src/artifact/variants.cr`).

```text
Variants.generate(db, source_tempfile, source_mime) : Array(VariantPayload)
  return [] unless image_mime?(source_mime)
  return [] unless guard_pixels_ok?(source_tempfile)      # header only, before decode
  config.artifact.variants.compact_map do |preset|
    out = run_magick(preset, source_tempfile)             # tempfile, webp
    next nil unless out                                 # skip on failure (D4)
    spool + sha256 + mime sniff of the produced bytes
    VariantPayload.new(label: preset.label, kind: preset.kind, ...)
  end
```

The steps:

1. **Gate on the sniffed MIME**, never the client `Content-Type`. Images only
   (`image/jpeg`, `image/png`, `image/webp`, `image/gif`, `image/avif`).
2. **Pixel guard before decode** (§4.3) — from `identify -format '%w %h'` on
   the header.
3. **One `magick` process per preset**, output to a tempfile:
   `magick <src> -auto-orient -strip -resize '<N>x<N>>' -quality <Q> <out>.webp`.
   The `>` flag means "shrink only" — an image already smaller than the preset
   is not upscaled. `-auto-orient` bakes EXIF rotation in and `-strip` drops
   the metadata (GPS, camera) from the rendition.
4. **The produced bytes are treated like an upload**: spool, sha256, sniff the
   MIME from the bytes (never trust the file extension), size from the
   tempfile. The dedup lookup does **not** run on variants — a rendition's
   identity is `(source_id, variant)`, not its sha256.

Each variant gets a shrine key of its own: `{sha256}/{ulid}`, the same shape as
a source. `variant_kind` records the preset.

**Persistence** — `Store.persist_uploaded` gains a variant list. The source row
and every variant row are inserted in the caller's transaction, and the owner
row is written **only for the source**.

**Cleanup** — every object put in the request (source and variants) is deleted
best-effort if the transaction rolls back, mirroring the current rule. A miss is
swept by `artifacts:reconcile`.

**Where it hooks in** — between the MIME sniff and the dedup lookup, because a
reused source needs no generation. On the fresh-put path:

```text
spool → sha256 → sniff mime
  → dedup hit?  yes → persist source + owner row only (no generation)
                no  → shrine put source
                    → Variants.generate(...)
                    → shrine put each variant
                    → persist source row + variant rows + owner row (one txn)
```

### 3.5 Preset set (config)

`Facet::Artifact::Config` gains `variants : Array(VariantPreset)`, read from the
`artifact.variants` list and validated at config load (fail loud, like
`artifact.storage`):

```yaml
artifact:
  variants:
    - label: thumb
      max_edge: 128
      format: webp
      quality: 80
    - label: preview
      max_edge: 1024
      format: webp
      quality: 82
```

| Field | Rule |
|---|---|
| `label` | Lowercase identifier, unique within the list. |
| `max_edge` | Longest side in pixels; the shorter side follows the aspect ratio. Not a fixed `WxH`, so a portrait image is not letterboxed. |
| `format` | `webp` only in v1. An unknown value fails loud at load. |
| `quality` | 1–100; applies to the lossy encoder. |

An empty list disables generation entirely — the supported way to run without
ImageMagick installed.

Also required: `artifact.variants_binary` (default `magick`) — the executable
path, so a deployment can pin a specific binary or run generation off a
different install. Validated as non-empty at load; a missing binary surfaces as
a logged skip (§4.4), never a crash.

### 3.6 API surface

| Surface | Change |
|---|---|
| `GET /Api/core/artifacts/:id` | Payload gains `variants: [{label, id, mime_type, size}]`. Empty array for a source without variants or for a variant id. |
| `GET /Api/core/artifacts/:id/download?variant=<label>` | The gateway resolves the label to the variant id, mints against the **source's** owner row, `302`s to the variant's serve URL. Unknown label → `404`. Absent `variant` → today's behaviour. |
| `POST /Api/core/artifacts` | Contract unchanged; the `201` payload may echo `variants`. |
| `urn:facet:artifact:<id>` / `file` fields | Sources only. `Document::ArtifactRefs` resolves a variant id to its `source_id` before writing the reference row; a `file` field holding a variant id is rejected at validation (§3.7). |
| Admin `GET /Api/Artifacts` | Defaults to sources only (`source_id IS NULL`). Rows gain `variant_count` / `variant_bytes`. A `variant__eq` filter lists a source's variants. |
| `DELETE /Api/Artifacts/:id` | A variant id answers `422` naming its source. |
| Agent tools | `get_artifact` returns `variants`; `list_artifact_refs` resolves a variant id to its source. |
| SDK / frontend | `variantUrl(id, label)` helper; `show` payload typed with `variants`. |

The frontend already renders a URN as
`/Api/core/artifacts/:id/download` (`resolveArtifactUrl`). Selecting a variant
is one query parameter — no new component.

### 3.7 References

`artifact_references` drives prune clause 3. If a document embeds a variant id,
that reference must keep the **source** alive, not the variant — otherwise the
variant outlives its source, which contradicts the sweep rule. Two gates:

- `Document::ArtifactRefs` resolves `source_id` before inserting a reference
  row.
- `FileType.validate` accepts a variant id shape (it is a ULID) but the
  re-attach flow (`Artifact::Owners.append_readable_for_document`) skips a
  variant id: a `file` field holds a source.

### 3.8 Dedup

`Store.find_candidates_by_sha256` gains `AND source_id IS NULL`. Without it, a
user uploading the same resized bytes reuses a variant row, which then dies
with its source.

---

## 4. Generation cost and risk

### 4.1 The ImageMagick dependency

ImageMagick 7 ships two binaries. `convert` is **deprecated** and prints a
warning to stderr on every run; `magick` is the forward-compatible entry point.
The plan uses `magick`, with `artifact.variants_binary` to override.

Invocation contract (verified on ImageMagick 7.1.2):

```text
magick <src> -auto-orient -strip -resize '128x128>' -quality 80 <out>.webp
```

`-resize '128x128>'` produced a 128×96 WebP from a 400×300 source — longest
edge bounded, aspect preserved, no upscale.

**Security note.** ImageMagick decodes untrusted input in-process, and its
delegate system has a history of parser exploits. Two mitigations, both cheap:
pin the policy (`policy.xml`) to the image coders the preset set needs, and
never pass user-controlled strings into the argument list — the source is a
tempfile path we created, the output is a tempfile path we created, and every
other argument comes from validated config.

**Deployment.** The container image (`ops/container-images.md`, `docker/`) gains
`imagemagick`. A deployment that does not install it still runs: the preset
list is empty or the binary is absent, and every preset is skipped with one log
line per upload (§4.4). No upload is ever refused for a missing tool.

### 4.2 Synchronous work in the request

Generation runs inside the upload request. A 50 MiB source at two presets is
two process spawns plus two decodes — seconds on a large image. That is
acceptable for the current one-shot upload contract, but it is stated in the
docs, and the size cap keeps the worst case bounded.

### 4.3 Decode amplification (must not be skipped)

`max_upload_bytes` bounds the compressed input. An 8000×8000 PNG can expand to
hundreds of MB in memory before the resize. A pixel guard runs **before**
decode, from the header only:

```text
identify -format '%w %h' <src>   → w * h <= artifact.max_pixels (default 100_000_000)
```

A source over the pixel budget gets no variants — logged and skipped like a
failed preset, never a failed upload (D4). `max_pixels` is a new config key.

### 4.4 Failure policy — skip, do not fail (D4)

Every failure inside `Variants.generate` is caught, logged at WARN with the
preset label and the process exit status, and skipped:

| Failure | Result |
|---|---|
| Binary missing | All presets skipped, one WARN per upload |
| Non-zero exit (corrupt image, unsupported coder) | That preset skipped |
| Timeout (`artifact.variants_timeout_seconds`, default 30) | That preset skipped, process killed |
| Pixel budget exceeded | No generation |
| Output larger than `max_upload_bytes` | That preset skipped |

The source upload always succeeds when the source bytes are valid. The cost:
the variant set depends on runtime luck, so a source can carry `thumb` and miss
`preview`. That is accepted (D4). Two consequences to document:

- `GET .../download?variant=preview` answers `404` for that artifact — the
  caller must treat a missing variant as "use the source".
- An operator who wants a complete set re-uploads the source; the dedup path
  then finds the existing row and **generates nothing**. So a re-upload does not
  repair a partial set. The remedy is the backfill CLI (§5, phase 6), which is
  also the answer for a preset set changed after the fact.

---

## 5. Phases

| Phase | Work | Gate |
|---|---|---|
| **1. Schema** | Migration `0015_artifact_variants.sql`; `Store::Artifact` record gains the three fields; every `SELECT` in `store.cr` and `admin.cr` updated. | `spec/artifact/schema_config_spec.cr` extended; migration round-trips `migrate:down` |
| **2. Config** | `Config::VariantPreset`; `variants`, `variants_binary`, `variants_timeout_seconds`, `max_pixels` keys; load-time validation; `config.{dev,test,production}.yml` entries. | Config spec: absent list → empty, unknown `format` → raises, empty binary → raises |
| **3. Generation** | `Artifact::Variants` — MIME gate, pixel guard, `magick` runner, output sniffing; wired into `Uploader.upload` and `Store.persist_uploaded`. | `spec/artifact/variants_spec.cr`: real `magick` on a generated fixture; missing binary → skip; corrupt bytes → skip; pixel budget → skip |
| **4. Access and sweep** | `Access.can_read?` source hop; `Grants.mint_ephemeral` resolves the source; `Purge` variant delete + audit `variants` array; `Prune` guard + second pass; `find_candidates_by_sha256` exclusion; `Refs` resolution. | `access_spec.cr`, `purge_spec.cr`, `prune_spec.cr`, `uploader_spec.cr` additions |
| **5. Serving** | Metadata route `variants` array; download gateway `?variant=`; admin listing sources-only + counts + filter; purge `422` for a variant id. | `routes_spec.cr`, `admin_spec.cr` |
| **6. Backfill CLI** | `facet artifacts:variants --backfill [--dry-run]` — generate missing presets for existing images. | `variants_spec.cr` CLI cases |
| **7. Clients** | SDK `variantUrl` + `variants` typing; frontend `artifactDownloadUrl(id, label)`; agent tools. | SDK `artifacts.test.ts`; frontend `artifacts.spec.ts` |
| **8. Docs** | `doc/backend/artifact.md` → new "Variants" section (schema, sweep, access, generation, failure policy); `doc/backend/config.md`; `doc/backend/cli.md`; `doc/project-structure.md`; `doc/packages/sdk.md`; `doc/frontend/platform.md`. | Docs read against the code |

Phase order is a dependency chain: 1 → 2 → 3, with 4 depending on 1 and 3, and
5 on 4. Phases 6–8 can run after 5 in any order.

---

## 6. Verification gates

- `make check` after every phase (fast compile gate).
- Isolated specs per phase while working:
  `crystal spec spec/artifact/<file>_spec.cr` (database up: `make test_db_up`).
- `bin/ameba` clean.
- `make test` once at the end (the full suite, 10+ minutes) — the final gate.
- Frontend: `pnpm --dir frontend check` and the Vitest project for
  `artifacts.spec.ts`.
- Manual: upload a JPEG through `POST /Api/core/artifacts`, confirm two variant
  rows and their WebP bytes; delete the source, confirm every object and row
  is gone; confirm a role that can read the source can download
  `?variant=thumb` and a role that cannot read the source gets `403`.

---

## 7. What this plan will not do

- **No video.** ffmpeg is out of scope (D3). The schema does not change for
  video later — only the preset set and the generator branch.
- **No client-supplied renditions.** Callers cannot upload a variant (D2).
- **No async generation.** No job queue, no background worker. Generation is
  synchronous in the upload request.
- **No automatic regeneration** when a preset changes or a preset failed. The
  backfill CLI is the only repair path.
- **No variant-of-variant.** The write path refuses it; depth stays 1.
- **No new access surface.** Variants add no owner rows, no grants table, and
  no permission.

---

## 8. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Flat schema: `variant`, `source_id`, `variant_kind` on `artifacts`. | One table; set-level byte totals are a `GROUP BY`; sweep is a `WHERE`. |
| D2 | Backend generates from a fixed preset set on upload. | Normalized output; callers never produce renditions. |
| D3 | ImageMagick (`magick`) for images; ffmpeg out of scope. | One dependency now; video is a separate cost class. |
| D4 | A failed preset is logged and skipped; the upload succeeds. | A broken resizer must not reject a valid upload. Cost: a partial variant set is possible, and `?variant=` must answer `404` honestly. |
| D5 | Variants carry no owner rows; access derives from the source. | Preserves invariant #1 and keeps the ACL in one place. |
| D6 | Purge deletes variants in the same transaction; the audit event carries a `variants` array. | Fail-closed audit, one event per destruction. |
| D7 | Prune skips variant rows and sweeps them in a second pass. | A variant is never eligible on its own. |
| D8 | The dedup lookup excludes variant rows. | A rendition must not be reused as a standalone artifact. |
| D9 | `variant_kind` snapshots the preset. | A later preset change must not rewrite the history of how bytes were made. |

Open for the implementer to confirm during phase 2: the default preset list.
This plan proposes `thumb` (128 px) and `preview` (1024 px), both WebP.

---

## 9. Relationship to other docs

- [`../backend/artifact.md`](../backend/artifact.md) — the subsystem this
  extends; phase 8 adds the Variants section.
- [`../backend/config.md`](../backend/config.md) — the `artifact:` section
  gains the variant keys.
- [`../backend/cli.md`](../backend/cli.md) — the `artifacts:variants` backfill
  command.
- [`domain-restore.md`](domain-restore.md) — §2.3 covers artifact prune
  interplay; variant sweep follows the same rules.
- [`container-release.md`](container-release.md) — the backend image gains
  ImageMagick.
