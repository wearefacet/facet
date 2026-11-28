# WP 10 — Inventory refresh and content audit

**Goal:** know exactly what the product does at `HEAD`, and what the current
site gets right and wrong, before anything moves.

**Depends on:** nothing. **Blocks:** WP 11 and every content WP.

**Write scope:**

- `site-docs/inventory.yml`
- `site-docs/coverage-exclude.yml`
- `doc/plans/documentation/feature-list.md` (keep it in sync with the inventory)
- `doc/plans/documentation-v2/ledgers/surfaces.md` (new)
- `doc/plans/documentation-v2/ledgers/audit.md` (new)
- `doc/plans/documentation-v2/ledgers/discrepancies.md` (new; append only afterwards)

No site page changes.

---

## Deliverable 1 — Inventory refresh

The inventory is pinned to `c2f1427e`. Bring it to `HEAD`.

1. Record `git rev-parse --short HEAD` as the new pin at the top of
   `inventory.yml` and `feature-list.md`.
2. For each area, walk the sources listed in the `Docs / source` column of
   `feature-list.md`. For each ID, confirm the feature still exists and still
   does what the row says. Update the row when it changed.
3. Sweep for features the inventory misses:
   - every concern doc under `doc/backend/`, `doc/frontend/`,
     `doc/packages/`, `doc/ops/` (start from `doc/project-structure.md`);
   - every route under `frontend/src/routes/`;
   - every route registration in `src/`;
   - every CLI command (`facet --help` and the CLI registry);
   - every `@facetapp/*` package under `packages/`;
   - `CHANGELOG.md` entries since the pin.
4. Add new IDs at the end of their area (never renumber). Mark removed
   features `removed: <SHA>` instead of deleting the row, so old pages that
   cite them show up as unknown IDs.
5. Mark IDs whose only sensible documentation is a generated table with
   `reference-only: true` and a one-line reason (rule R2 in `04`).
6. Review `coverage-exclude.yml`. Each exclusion needs a reason that still
   holds.

Not features (do not add IDs for these): test helpers, engineering
workflow docs (`doc/backend/workflow.md`, `specs.md`, `test-database.md`),
pure utilities with no user surface (`util-*`), frontend component internals
(`bits-ui.md`, pickers) — unless they show a user-facing behaviour that no
other ID covers.

## Deliverable 2 — The surface ledger

Build `ledgers/surfaces.md` as specified in `04-coverage-and-verification.md`
§2: one table per surface kind, each row with surface, feature ID, and the
current page that explains it (old path). Leave the new-page column empty;
the content WPs fill it.

Prefer extraction by script over hand-listing (routes, CLI registry, config
keys, settings keys, agent tools, Lua bindings, cron tasks). Keep the scripts
you wrote under `doc/plans/documentation-v2/ledgers/scripts/` so WP 21 can
re-run them.

## Deliverable 3 — Content audit

For every current English page, add a row to `ledgers/audit.md`:

| Page | Words | Type (guess) | Layer | Engine words in lead | Accuracy spot-check | Notes |
|---|---|---|---|---|---|---|

- **Accuracy spot-check:** verify three claims per page against the code
  (prefer numbers, labels and security statements). Write ✅, or ❌ with a
  discrepancy number.
- **Engine words in lead:** count the words from `01-voice-and-vibe.md` §5.2
  that appear in the first paragraph. This shows WP 13–19 where the voice work
  is heaviest.
- **Notes:** duplicated content (name the other page), missing prerequisites,
  dead ends.

Then write a summary at the top of `audit.md`: the ten worst pages for a
newcomer, the duplicated topics, and the discrepancy count by area.

## Done when

- [ ] `inventory.yml` pinned to `HEAD`; every row confirmed or changed; new
      IDs added; removed IDs marked.
- [ ] `feature-list.md` matches `inventory.yml` one to one.
- [ ] `surfaces.md` lists every surface kind of `04` §2, each with a feature ID.
- [ ] `audit.md` has a row per page and the summary.
- [ ] `node scripts/check-coverage.mjs` runs; its output is pasted in the report.
- [ ] Report per `00-contract.md` §10, plus: IDs added, changed, removed.
