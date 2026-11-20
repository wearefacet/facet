# WP 02 — Feature inventory, coverage check, staleness report

Phase 0 (warn mode) → Phase 2 (strict) · Depends on: WP 01 (schema keys) · Write scope: `site-docs/inventory.yml`, `site-docs/coverage-exclude.yml`, `site-docs/scripts/check-coverage.mjs`, `site-docs/package.json` (one script line), `doc/site-docs.md` (one section).

Source: [`whole-doc.md`](whole-doc.md) §1 goal 4, §5, §6 item 7.

## Goal

A feature ID (`DOM-03`, `PLT-12`, ...) can not ship undocumented. A build-time check compares the IDs in page front-matter against the inventory. The build fails on an uncovered ID (whole-doc §5). Today the inventory does not exist in the repo — whole-doc says it was "pinned to `envelope@c2f1427e` (138 features, 10 areas)".

## Deliverables

### 1. The inventory: `site-docs/inventory.yml`

One entry per feature ID:

```yaml
# area: PLT (platform) — 12 features
- id: PLT-01
  name: Configuration files
  area: PLT
```

The ten areas seen in whole-doc: `AUT`, `AUD`, `APP`, `AI`, `DOC`, `DOM`, `FE`, `IAM`, `PLT`, `RBC`.

Sourcing — see `99-decisions.md` D9:

- **Option A (preferred):** the user supplies the original inventory export. Convert it to the YAML above.
- **Option B (fallback):** re-derive the inventory. Sweep `doc/` concern docs and source, assign one ID per discrete user-visible feature, one area prefix per area. Validate the result with the user before committing. This is a large sweep — do it as its own dispatch, not inside a content WP.

`name` is one line, human-readable, plain English.

### 2. The checker: `site-docs/scripts/check-coverage.mjs`

Behaviour:

1. Scan `src/content/docs/**/*.md` and `.mdx` (English tree only — `fr/` pages share IDs with their English source).
2. Parse front-matter, read `features`. The format is a flat YAML array on one line — a small parser is enough. Add a dependency (`js-yaml`) only if the simple parser gets fragile.
3. Expand wildcards: `IAM-*` on a page expands to every `IAM-*` ID in the inventory. Record the expansion, not the wildcard, as coverage.
4. Collect: `covered` (inventory IDs on at least one page), `uncovered` (inventory IDs on no page and not excluded), `unknown` (page IDs not in the inventory and not a valid wildcard).
5. Load exclusions from `site-docs/coverage-exclude.yml` (list of IDs with a one-line reason; whole-doc §5 names DOC-08 as the example).
6. Print a table: per area — total, covered, uncovered. Then the uncovered and unknown ID lists.
7. Exit code: `0` always in warn mode; in strict mode, non-zero when `uncovered` or `unknown` is not empty.
8. Staleness report (same script, or a sibling): parse `verified_at` per page, print pages whose marker is older than N days (N in the script config, default 90). Whole-doc §5 says "more than N releases old"; releases do not map to commits yet, so days are the honest unit. Switch to release-based when release tags exist — note this in the script.

### 3. Wire into the build

`site-docs/package.json`:

```json
"prebuild": "node scripts/check-coverage.mjs"
```

Warn mode first. Flip to strict when the sections are complete (Phase 2): add `"coverage": "node scripts/check-coverage.mjs --strict"` and make `prebuild` call the strict variant, or gate strict on an env var. Record the flip in the status table in `README.md`.

### 4. Document it

One section in `doc/site-docs.md`: the check, the two YAML files, warn/strict, the staleness report.

## Definition of done

- [ ] `inventory.yml` lists 138 IDs (or the validated count from D9) across the ten areas.
- [ ] `node scripts/check-coverage.mjs` runs clean and prints the per-area table.
- [ ] `npm run build` runs the checker first.
- [ ] Unknown IDs (typo test) get reported.
- [ ] `doc/site-docs.md` documents the check.
