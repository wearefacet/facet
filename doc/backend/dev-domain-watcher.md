# Dev Domain Watcher

**Files:** `src/dev/domain_watcher.cr`, `src/dev/check_report.cr` (the in-process check-report store and the `GET /Api/dev/check-report` endpoint), `src/dev/config.cr` (`Config::DevConfig` / `Config::DomainWatchConfig` / `Config::DocumentsMode`), `src/main.cr` (`CLI.run_server` boot wiring); specs in `spec/dev/domain_watcher_spec.cr`, `spec/dev/check_report_spec.cr`

The dev domain watcher watches a folder of portable-domain bundles and applies every change into the running server. A developer authors domains as files; the watcher keeps the live system equal to the folder, so the design loop does not touch the editor UI, the API, or the AI builder. It is a dev-only service — the production boot refuses to start it.

---

## Configuration

The optional `dev:` section in `config.{env}.yml`. The watcher runs only when `dev.domain_watch` is present and the environment is not production.

```yaml
dev:
  domain_watch:
    path: ./dev          # watch root (required)
    poll_ms: 500         # poll interval, >= 100
    documents: preserve  # preserve | discard
```

| Key | Type | Default | Notes |
|---|---|---|---|
| `path` | string | *(required)* | The watch root — a parent directory of bundles. Must be a readable directory at load; a missing path fails loud at boot. |
| `poll_ms` | integer | `500` | Poll interval. Lower bound 100 ms; a smaller value fails at load. |
| `documents` | `preserve` \| `discard` | `preserve` | Retention mode, global for every bundle. |

The config line is the **teardown consent**: every sync replaces the managed domains' definition surface (and, in `discard`, their data).

The checked-in `config.dev.yml` ships the section commented out — a missing path fails loud, so the default dev boot stays untouched.

## The watch root

- Every immediate child directory of the watch root that contains a readable `bundle.yml` is a managed bundle. Deeper nesting is not scanned.
- The bundle's `source_domain` is the identity and names the target domain — no prefix, no rename (`Portable::Import` runs without `--into`).
- Children are discovered on every poll, so a bundle added while the server runs is picked up without a restart. A child without `bundle.yml` is ignored.
- Two children naming the same `source_domain` are ambiguous ownership: the alphabetically first child syncs, and a warning names both directories every cycle until the duplication is removed.
- A vanished watch root warns and skips the poll — nothing is deleted (see Policy).

## Sync cycle (per changed child)

For each child whose fingerprint changed (see Change detection):

1. `Portable::Archive.read` reads the child directory. A read failure logs for this child and keeps its previous state.
2. Capture the domain's pre-sync state: the parsed definition (a corrupt definition row is skipped) and the live document count of every doctype.
3. Teardown per the documents mode, inside the sync transaction: `preserve` runs `Domain::Scratch.dispose_definitions!` (definitions only — documents, personal views, and artifact provenance survive); `discard` runs `Domain::Scratch.dispose!` (everything). When the domain does not exist, teardown is skipped.
4. Fresh `Portable::Import.call` re-applies the whole bundle into the now-absent domain, joining the same transaction (its `ignore_if_set` wrapper). The teardown and the import share ONE transaction: a failed import — a returned error or a raise — rolls the teardown back with it, so the domain keeps its previous state, and the events the import enqueued are discarded with the rollback. On success the transaction commits once. The document replay is idempotent — existing rows are skipped — so `preserve` keeps app-created documents and `discard` reseeds from the bundles' `documents/` trees.
5. Removed-doctype data tombstone: a doctype that left the bundle has its live rows tombstoned **after** the commit, in both modes — the idempotent replay would otherwise re-create rows from a stale `documents/` tree.
6. `Event::Publisher.flush` — a background task must flush itself.
7. Structure warnings (`preserve`): every doctype whose fields changed in any data-shape way (additive included) or whose derived surface (`search` paths, `display_name` template) changed, while carrying live documents, warns with the kept document count. Composition-only (`children` / `member_of`) and actions-only edits stay silent — no derived column depends on them.
8. Post-sync diagnostics: `Domain::Check.call` runs and a one-line warning names the issue count and the first message (a clean domain logs nothing). In `preserve`, every warned doctype then runs `Doctype::Reproject`, so the kept rows' derived columns (`search` / `links` / `display_name`) match the new definitions. Diagnostics never fail the cycle — a failure is logged and skipped.
9. A one-line summary names the domain and the import counters.

Every mutation the sync writes carries the `system:import` actioner id (`Portable::Import::ACTIONER_ID`), so the mutation log stays the full history of the dev loop.

### Check report endpoint

The one-line check summary truncates the diagnostics. The full report of the last completed check is stored in-process, per domain, in `Facet::Dev::CheckReport` (`src/dev/check_report.cr`) and served by:

```
GET /Api/dev/check-report?domain=<id>
```

| Aspect | Contract |
|---|---|
| Dev gate | The same `DomainWatcher.allowed?(Config.app_env)` predicate the boot guard uses. In production the route answers a bare `404` — the surface does not exist there. |
| Auth | The standard `AuthHandler` chain (the path is not a public route): an unauthenticated request answers `401`. The report is not a projection read, so no per-doctype RBAC runs behind the gate. |
| Missing parameter | Missing or empty `domain` → `422`. |
| No check yet | `404` with the standard error envelope — the watcher has not completed a check for the domain in this process, or the last check failed (a failed check drops the stored report; a stale report read as current would misdirect debugging). |

`/Api/dev/` is the dev-tooling route namespace — this endpoint sets the convention: a `dev` first path segment after `/Api/`, self-gating on the environment, mounted outside the document REST surface. The `DomainGate` does not list `dev` as a reserved segment; the static route wins over the REST catch-all, so no user domain named `dev` can collide with it.

The response body reuses the inline check endpoint's envelope (`GET /Api/core/Domain/:id/check`) plus `captured_at`:

```json
{
  "data": {
    "domain": "aorders",
    "captured_at": "2026-10-28T09:15:00Z",
    "issue_count": 4,
    "domain_issues": [{"severity": "warning", "category": "hooks", "message": "..."}],
    "doctypes": [{
      "doctype_id": "aorders.Widget",
      "issue_count": 3,
      "issues": [{"severity": "warning", "category": "reference", "field": "owner", "message": "..."}],
      "notices": [{"severity": "info", "category": "defaults", "message": "..."}]
    }]
  }
}
```

Per-issue fields: `severity` (`warning` / `info`), `category`, `message`, and `field` (omitted when `null`) — identical to the inline check issues. `issue_count` counts the warning-severity issues (domain-level plus per-doctype), the same rule the inline route uses. The report is a snapshot of the watcher's last cycle: the `captured_at` field is the one marker the live inline check does not carry. The store is process-local RAM — it dies with the process, and the watcher populates it again on the next cycle.

When a cycle fails at the import step (schema validation), the watcher logs the backend-formatted error — the summary line plus the `details` block naming the failing field, the same text the portable-domain CLI prints (`Portable::ServiceErrorFormat`) — and stores an import-failure marker in place of a report. The marker keeps the diagnostic visible for the bundle being edited, while the domain itself stays on the rolled-back (previous) state:

```json
{
  "data": {
    "kind": "import_failure",
    "domain": "aorders",
    "captured_at": "2026-11-12T09:15:00Z",
    "status": 422,
    "message": "aorders.Widget: schema validation failed",
    "doctypes": ["aorders.Widget"],
    "details": [
      {"field": "fields.name", "message": "must be a lowercase snake_case identifier", "code": "invalid_format"}
    ]
  }
}
```

`doctypes` lists the failing doctype(s) derived from the import error's message conventions; a domain-level rejection carries an empty list. `details` is the standard validation-error wire form (`field` omitted when the error is not field-scoped, `code` omitted when untagged). The next successful cycle replaces the marker with a normal check report, and a failing check (as opposed to a failed import) drops the stored entry, per the `404` row above.

### Documents modes

| Mode | Teardown scope | Kept across a cycle | Reseed |
|---|---|---|---|
| `preserve` (default) | `Scratch.dispose_definitions!` — definitions only | App-created documents, personal collection views, artifact provenance | Bundled documents fill only missing rows |
| `discard` | `Scratch.dispose!` — everything | Nothing; every cycle rebuilds from the bundle | Every bundled document replays fresh |

## Change detection

Each child has a fingerprint: the SHA-256 over the ordered `(relative_path, size, content)` tuple of every file under the child, recursed. The fingerprint is content-addressed, so a save that lands inside the same mtime tick as the previous poll (coarse filesystem clocks) still produces a new fingerprint — change detection never depends on clock granularity. A child cycles when:

- its fingerprint differs from the last attempted one (success or failure), **and**
- the same new fingerprint was observed on two consecutive polls (the debounce — editors write in bursts and save-often tooling emits several events per save).

A failed cycle still records the fingerprint: a validation error waits for the next save instead of re-firing on every poll. A file that vanished mid-scan yields a never-matching fingerprint, which forces a fresh cycle on the next poll, where the read reports the true state.

## Lifecycle

- `CLI.run_server` starts the watcher after the cron scheduler, when `DomainWatcher.allowed?(app_env)` returns true and the config section is present. `allowed?` is false for the `production` environment — the boot refusal is explicit and testable.
- The first tick runs the initial scan + sync, so bundles that exist before boot are applied once the server is ready.
- The poll fiber runs under `Util::FiberSupervisor`: a raise that escapes the loop body (a poll failure is rescued in place and counted on `facet_fiber_loop_errors_total`) restarts the watcher after a backoff.
- `at_exit` stops the watcher. The stop is idempotent; an in-flight cycle runs to completion.

## Policy and caveats

- **Dev only.** Never enable this in production; the boot code refuses the watcher there even when the section is present.
- **Nothing here deletes a live domain.** A removed bundle directory warns and keeps the domain's last synced state. Only the `discard` documents mode or `db_reset` destroys data.
- **Fault isolation is per child.** A failed cycle keeps that domain's previous state and never blocks sibling domains. The teardown and the import share one transaction, so a failed import leaves the domain live and unchanged — the next good cycle applies the new bundle.
- **Replace warning.** The first teardown of a domain this process did not create warns distinctly (restarts included). The tracking is in-memory, so a restart may re-fire the warning once. Accepted for dev mode.
- **Kept documents can hold stale fields** until the re-project pass finishes; rows that fail re-projection keep their previous derived state.
- **The sync always imports fresh.** The teardown makes the target absent, so the import takes the fresh branch — the merge branch's version gate does not apply inside the loop. A same-version destructive edit therefore never needs `$force` here; it applies outright.

## Relationship to other concerns

- [`portable-domains.md`](portable-domains.md) — the bundle format, the fresh-import mechanics, and the `system:import` actioner the sync writes under.
- [`draft-domains.md`](draft-domains.md) — `Domain::Scratch.dispose!` / `dispose_definitions!` are shared with the draft publish path (the watcher owns the dev-mode policy).
- [`doctype-system.md`](doctype-system.md) — `Doctype::Reproject` and `Doctype::Structure`, used by the preserve-mode diagnostics.
- [`config.md`](config.md) — `Facet::Config` loading; the `dev:` records and `load_dev` live in `src/dev/config.cr`.
