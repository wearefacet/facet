# WP 12 — running example — report

Date: 2026-11-26. Branch: `features/documentation-v2`.

## WP 12 — report (contract §10)

- Pages written: 0 site pages. Built the example itself:
  `site-docs/examples/brightwater/` — 3 domain bundles (7 doctypes, 8
  document views, 5 collection views, 1 event hook, 2 Lua doctype scripts,
  2 domain files), `load.sh`, `seed.py`, `export.sh`, `README.md`, 3
  definitions-only export tarballs under `bundles/`.
- Feature IDs now covered by this batch: none (WP 12 writes no task pages;
  its output is the example every later WP cites).
- Gates: no site build impact (site-docs untouched). Verified by execution:
  fresh-instance path green (db_reset → import 3 tarballs → boot → load.sh →
  seed) with 40 items / 10 companies / 14 contacts / 15 bookings / 5
  tickets; 14 items `out` after seed (hook-driven), 0 hook errors; totals
  hand-checked; Lucía sees no `purchase_price`; Tom sees exactly his 5
  companies; in-repair item refuses to book out with a collected error
  while the rest of the booking goes out; load.sh idempotent on re-run.
- Discrepancies logged: #17 (update guards cannot read pre-merge state),
  #18 (auto-filed grants narrower than hook runtime reads; import-order
  dependent).
- Not verified (and why): the browser UI surfaces (kanban board, calendar
  view, field-tag masking in the workspace) — verified at the API layer;
  screenshots are WP 14's job with this loader. The webhook sketch from the
  05 §3 table is intentionally not in the bundle (no receiver on a dev
  instance) — ledger 12 §12.
- Requests outside my scope: none. All writes stayed in the WP 12 scope:
  `site-docs/examples/brightwater/`, `doc/plans/documentation/
  documentation-v2/` (05 update, ledgers), plan README status. One config
  change outside the scope was unavoidable: `config.dev.yml` — uncommented
  the `dev.domain_watch` block (the watcher that syncs the example during
  development). Flagged here for review.
- Proposals: none new; two existing ones restated in ledger 12 §6 (roles in
  domain files) and §8 (row-scope vs unscoped-read callout).

## What a reader gets

`load.sh` takes a fresh instance (bundles imported, or the dev watcher) to
the full example: 3 roles, 4 people with known passwords, 2 grants
(widened to what the hook actually reads), and the deterministic data set.
The bookings reach their states through the named actions, so the stock
movements are driven by the example's own hook — the demo demonstrates the
feature, not the seed script.
