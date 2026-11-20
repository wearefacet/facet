# WP 99 — Decisions register

Open questions from [`whole-doc.md`](whole-doc.md) §6 that block or shape content WPs. Answer by writing `Decision:` under the item, then dispatch the affected WP.

## D1 — Backup and restore

Whole-doc §6 item 1. Not in the feature inventory, but evaluators and operators ask first.

- Option A: document the read-replica + periodic backup + S3 restore approach as a product feature.
- Option B: name backup and restore the operator's responsibility, with PostgreSQL tooling pointers.

Blocks: WP 12 batch B (`operate/backup-restore.md`).

Decision:

## D2 — Upgrade path and versioning policy

Whole-doc §6 item 2. How releases, migrations and breaking changes are communicated.

- Option A: one policy page in `/operate/` (semver, migration discipline, breaking-change notes in the changelog).
- Option B: policy spread across `/operate/upgrades-shutdown/` and `/changelog/`.

Affects: WP 12 (upgrades), WP 01 (changelog page).

Decision:

## D3 — OpenAPI coverage label

Whole-doc §6 item 3. OpenAPI covers only a subset (PLT-12).

- Option A: widen the OpenAPI file before beta.
- Option B: label the generated reference as partial, fill the gaps by hand.

A backend task if A; a wording choice if B. Affects: WP 13 part 1 (`reference/rest-api.md`).

Decision: Option B. The generated REST API reference labels itself partial: it names the route groups the OpenAPI file covers and links the hand-written `/apps/` pages for the rest. Widening the OpenAPI file (option A) stays open as a backend task before beta.

## D4 — Licensing page

Whole-doc §6 item 4. BSL 1.1 + Additional Use Grant in plain words: what you can and cannot do.

- Option A: one page under `/start/` (evaluator audience).
- Option B: one page under a new `/about/` section (more moving parts).

Affects: a small addendum to WP 04 or a standalone page; also WP 14 claims.

Decision:

## D5 — Data location and compliance

Whole-doc §6 item 5. Hosting region options, GDPR posture, ISO 27001 mapping.

- Option A: a section on `start/security-governance.md` now, a full page when the audit mapping exists.
- Option B: full page now, with placeholders? No — pages must document what exists. If the mapping does not exist, take option A.

Affects: WP 04 (security overview).

Decision:

## D6 — Limits and quotas page

Whole-doc §6 item 6. One page collecting: aggregate `count` cap of 1000, import staging caps, rate limits, history limits.

- Option A: `reference/limits.md`, generated where registries expose the numbers, hand-written otherwise.
- Option B: limits inline in each how-to page only (scattered; hard to audit).

Affects: WP 13 (add `reference/limits.md` if A). Values must come from source, not from memory.

Decision:

## D7 — Internal-only features

Whole-doc §6 item 7. DOC-08 stays out of user docs (it is the coverage-exclusion example); parts of DOM-19 (dev domain watcher) may be internal.

- Option A: DOC-08 and DOM-19 internals go to `coverage-exclude.yml` / WP 09 writes the user-facing part only.
- Option B: document both fully.

Affects: WP 02 (exclusions), WP 09 (dev-domain-watcher page).

Decision:

## D8 — Support and services links

Whole-doc §6 item 8. Free tier is "docs + tutorials, no SLA"; Administration and Design & Development offers get a docs-footer link.

- Option A: footer links only (site chrome change — small, assign to WP 01 or WP 14).
- Option B: footer links + a "Support" page describing the offers.

Affects: WP 01 or WP 14; needs the offer URLs.

Decision:

## D9 — Feature inventory source

WP 02 needs the inventory (138 features, 10 areas). Whole-doc says it was "pinned to `envelope@c2f1427e`"; the repo holds no inventory file.

- Option A: you supply the original export (fastest, faithful to the plan).
- Option B: re-derive it by a documented sweep over `doc/` and source, validated by you.

Blocks: WP 02 deliverable 1, and `reference/feature-index.md` (WP 13 part 3).

Decision:

## D10 — IA realignment of existing directories

WP 01 renames `domains/` → `build/` and `deploy/` → `operate/` to match whole-doc §3. The site is not public, so no legacy URLs exist.

- Option A (recommended): rename now.
- Option B: keep current paths and remap labels in the sidebar only (diverges from whole-doc §3 URLs).

Affects: WP 01.

Decision: Option A is assumed by every WP; say so now if you disagree.

## D11 — Release-based staleness

Whole-doc §5 wants a staleness flag for pages "more than N releases old". Release tags do not map to commits yet.

- Option A (recommended): days-based staleness (default 90) until release tags exist, then switch to release-based.
- Option B: wait for tags; ship no staleness report until then.

Affects: WP 02 deliverable 2.

Decision:
