# WP 11 — scaffold and moves — report

Date: 2026-11-26. Branch: `features/documentation-v2`. Commits: WP 10 `8fb69df`,
tooling + five tab moves (`00b0112`, per-tab commits, `5f80fef`), scaffold
`918854b`, redirect gate `2f24dd1`.

## WP 11 — report (contract §10)

- Pages written: 0 new prose pages. Moved ~144 English pages and 138 French
  twins with `git mv` (front-matter `type` + `sidebar.order` set per map);
  16 split/merge/retire originals saved to `ledgers/originals/`; 3 pages
  retired (`concepts/index`, `operate/index`, `operate/retention-tuning`);
  23 §9 stubs created.
- Feature IDs now covered by this batch: none (WP 11 writes no task pages).
  Coverage is 158 features / 139 covered / 18 uncovered / 0 unknown. The 18
  are the 16 new IDs the stub pages will carry (WP 13–19) plus FE-08 and
  PLT-10, cited only on overview/reference pages — the expected R2 effect of
  the split until the stubs get their prose.
- Gates: build ✅ (329 pages, link validator passes), coverage 139/158 (warn
  mode, report-only by design), redirects 288/288 old URLs answer (42 direct,
  246 redirect, 0 failed), `make gen-docs` byte-stable on a second run ✅.
- Discrepancies logged: #16 (filter compiler require order).
- Not verified (and why): rendered look of the five tabs in a browser —
  verified via build + link validator + preview HTTP checks; a human eyeball
  of the tab layout is part of WP 21's review pass.
- Requests outside my scope: none. All edits stayed in the WP 11 write scope
  (site-docs config/scripts/moves, repo-root `scripts/gen_docs/`, the three
  Step 8 doc files).
- Proposals: none new — three deviations below, all taken to keep the build
  green.

## Deviations from the plan

1. **Stubs do not use `draft: true`.** The plan's stub convention (§9 of the
   page map) assumed draft pages; Starlight errors when a sidebar references
   a slug with no route, and draft pages have no route. Stubs instead publish
   one honest line ("This page is being written.") with `pagefind: false` and
   `pager: false` — out of search and pager chrome until their owner WP
   writes them. Recorded in `doc/site-docs.md` → Stubs.
2. **Three manual redirects for sitemap-only French URLs.** The old sitemap
   emitted hreflang alternates for untranslated pages, so
   `/fr/tutorials/{t1-run-facet,t2-first-domain,t4-team-access}/` appear in
   the old sitemap but never existed in git. They redirect to the English
   targets (D8 fallback: no fr twin → land on the English page), implemented
   as an `extraRedirects` list in `scripts/page-map.mjs` merged by
   `apply-page-map.mjs`.
3. **`reference/webhook-payloads.md` is hand-written, not generated.** The
   page map marks it "Generated.", but no Makefile target produces it and it
   predates the plan (release commit). Removed from the `generated` list;
   `type: reference` set by hand on the page and its fr twin.

## Pre-existing generator bugs fixed (Step 7)

All at HEAD before WP 11; none caused by the moves. Fixed in the scaffold
commit `918854b`:

- `filter_operators.cr`: missing `require "rbac/auth_context"` — the filter
  compiler only compiles via require order (`src/document/filter_compiler.cr`
  never requires it; `src/rbac/read_enforcer.cr` uses `RBAC::AuthContext`
  without requiring it). See discrepancy #16.
- `lua.cr` (×4): comment lines counted as `end` keywords; string literals
  stripped before `\bend\b` counting (`p["end"]` fooled it); `bind_date_function!`
  macro registrations missed; `local __ovl` internal aliases emitted as
  public API; hardcoded `util.` key instead of `member.ns`.
- `feature_index.mjs`: the fr twin kept the en URL for untranslated pages —
  correct behaviour, now explicit in code; all generator templates now emit
  `type: reference`.
- Generator templates carried 70 old-path links across 26 files. Every
  `make gen-docs` run re-emits its page, so a stale template link silently
  undid the link rewrite (68 fr links regressed at `918854b`). Templates now
  agree with the page map; a finder script confirms zero old-path links in
  `scripts/gen_docs/`.

## Unresolvable links

None. The link rewrite covered every internal link; the build's link
validator passes.

## Step 8 — durable rules

- `doc/documentation.md`: new **Rule 2b — Layers and onboarding** (layer
  model L1/L2/L3, page flow, vocabulary budget with the engine-word
  translation table, banned words, UI labels, titles). Sentence rule updated:
  average ~15 words, hard 25 outside tables (was a 20-word ceiling in the old
  plan's `00-conventions.md`, never in the durable doc). Rule 2a gains the
  "warmth through care" sentence. Self-contained — no links into the plan.
- `doc/site-docs.md`: Information-architecture section replaced (five tabs,
  `type` page types, `redirects.mjs` + `check-redirects.mjs`, new coverage
  checks, stub convention); front-matter contract gains `type` and points at
  the v2 contract; inventory count corrected to 158.
- `doc/plans/documentation/README.md`: superseded note at the top.
