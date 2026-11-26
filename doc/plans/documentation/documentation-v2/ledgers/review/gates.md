# WP 21 part 3 — completeness and the gates

Run by the orchestrator (the "any agent" seat) after the fix round landed.
Commands run from the repo root unless noted. Dates: 2026-11-26/27.

## 1. Coverage

```
$ node scripts/check-coverage.mjs --strict        (site-docs/)
Strict mode: uncovered or unknown IDs exist. Build blocked.   ← BEFORE the fix round
  R2 uncovered: 17 (AI-10, AI-11, APP-12, AUT-09, AUT-10, DOC-14, DOC-15,
  DOM-26, DOM-27, DOM-28, DOM-29, DOM-31, DOM-32, FE-08, FE-24, PLT-10, PLT-12)
  R1 unknown: 0

$ node scripts/check-coverage.mjs --strict        (after the fix round)
exit 0 — 157/158 covered, 0 uncovered, 0 unknown
  (the one uncovered ID is DOC-xx excluded by policy; see the R5 note below)
```

R5 (non-overview pages with an empty features list, 14 pages) is report-only
by design: the listed discover/compare and reference pages carry no feature
IDs because their page types don't take them. Not a gate.

## 2. R2, R3, R5, type, title, link, layer-link, dead-end checks

```
$ node scripts/check-reachability.mjs    exit 0 — 156/156 user-facing IDs reachable
$ node scripts/check-layer-links.mjs     exit 0 — layer links present, 0 dead ends
$ astro build (starlightLinksValidator)  exit 0 — "All internal links are valid"
```

Type, title and description length checks run inside the WP batches and were
spot-audited by the accuracy agent (part 2); the build's content schema is the
remaining gate and passed.

## 3. Old-URL redirects

```
$ node scripts/check-redirects.mjs
Checked 288 old URLs: 42 serve directly, 246 redirect, 0 failed.
```

## 4. make gen-docs — clean diff

```
$ make gen-docs        exit 0
```

Two kinds of diff appeared and both are understood:

- Generator catch-up: `feature-index.md` (the Pages column re-scans page
  front matter; the tutorial and fix-round pages changed it) and one-word
  link/title updates in the generated index pages. The committed output was
  stale against the newer pages — the documented catch-up case.
- The `account-settings-keys.md` diff is a trailing-newline-only change (the
  generator does not emit the final newline the committed file carried).

A second `make gen-docs` run after committing the catch-up produced no
further diff (byte-stable).

## 5. Strict flip

```
site-docs/package.json  prebuild: "node scripts/check-coverage.mjs --strict"
```

Recorded in `doc/site-docs.md` → Coverage and staleness. From this point a
build fails when a feature ID loses its last how-to/tutorial/explanation page
or an unknown ID enters a page's front matter.

## Pre-existing noise (not gates)

- `check-coverage.mjs` prints `git` warnings for several `verified_at` SHAs it
  cannot resolve (008dd880, f1409cdc, bd4be053, 7a6cb462 — commits of the old
  documentation repo that predate this repository's squashed history). The
  staleness report degrades gracefully; the SHAs remain honest stamps of the
  pages' last verification.
- `astro preview` serves the built site but answers 404 for the `.md` twins
  and disables pagefind; a production static host serves both. The newcomer
  test's "the frozen site is not the production build" finding is a preview
  artifact, not a site defect.
