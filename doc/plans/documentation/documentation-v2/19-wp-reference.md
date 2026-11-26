# WP 19 — Reference

**Goal:** every exact fact — key, field, operator, command, payload, error,
term — is one search away, and every reference page tells a newcomer how to
use it.

**Depends on:** WP 11; decision D9 (limits page).
**Write scope:**

- hand-written pages under `site-docs/src/content/docs/reference/`:
  `glossary.md`, `changelog.md`, `error-responses.md`, `jinja2-context.md`,
  `permission-syntax.md`, `limits.md` (only if D9 = A);
- the **lead paragraph and title strings inside the generators** in
  `scripts/gen_docs/` (not the tables), then `make gen-docs`.

`reference/index.md` belongs to WP 20.

---

## Tasks

1. **Glossary** (`reference/glossary.md`). One entry per term in
   `01-voice-and-vibe.md` §5.1 and §5.2, plus any term a content WP reports.
   Each entry: the plain definition (one or two sentences, no other glossary
   term unless linked), "Also called" (the UI label or the code name), and a
   link to the page that explains it. Alphabetical. Every engine word says
   "Used in the technical pages".
2. **Leads of generated pages.** Each generated page gets a lead (in its
   generator) that says: what this table lists, who needs it, which L2 page
   explains the concept, and how the table is generated (so readers trust it
   is current). Keep the generators byte-stable: run `make gen-docs` twice
   and diff.
3. **Hand-written reference pages**: verify every row against the code; add
   rows the code has and the page lacks (use `surfaces.md`); keep the table
   shapes.
4. **Changelog**: moved from `changelog/index.md`; check it against
   `CHANGELOG.md` at the repo root and say on the page which one is the source.
5. **Limits** (if D9 = A): every hard limit with its value, where it is set
   (config key, setting, constant), and its source (`path:line`). Generate it
   if the values come from registries; hand-write it otherwise.

## Done when

- [ ] Glossary covers every term of `01` §5.1 and §5.2 and every term the
      content WPs reported.
- [ ] Every generated page has a lead; `make gen-docs` is byte-stable.
- [ ] Hand-written pages verified row by row (sample of 1 in 3 rows in the
      ledger, all security-related rows).
- [ ] Gates pass; report per `00-contract.md` §10.
