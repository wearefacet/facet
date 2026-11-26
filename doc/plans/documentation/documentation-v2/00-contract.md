# 00 — The contract (read first, every time)

Every work package (WP) in this plan follows these rules. They extend
[`doc/documentation.md`](../../documentation.md) (the loop, Rule 1 "the code
is the truth", Rule 2/2a on writing, Rule 3 on rendering). Read that file too.
When this file is stricter, this file wins.

---

## 1. What you are doing

You are rewriting the documentation of a complex product for people who have
never seen it. Two goals pull against each other, and you must hold both:

- **Approachable.** A newcomer understands what they read, in the order they
  read it. See [`01-voice-and-vibe.md`](01-voice-and-vibe.md).
- **Complete and exact.** Every feature of Facet is documented somewhere, and
  every claim matches the code at the commit you verified. See
  [`04-coverage-and-verification.md`](04-coverage-and-verification.md).

The way to hold both is **layering**, not dilution. The first page a reader
meets about a topic is simple. The full detail exists one click deeper. You
never delete a true, useful fact to make a page friendlier. You move it to the
right layer.

## 2. Hard rules

1. **The code is the truth.** Verify every claim against the source, a
   command you ran, or the running app. When a `doc/` concern file disagrees
   with the code, the code wins. Log the disagreement (see §6).
2. **Document only what exists.** No roadmap. Do not mention features that are
   planned but not in the code. Known examples that are **not shipped** at the
   time of writing, unless you find them in the code: role templates, a
   cross-domain workflow engine, a domain marketplace, a SaaS version, a
   mobile app, an assistant sandbox, artifact variants, passkeys. Files under
   `doc/plans/` describe plans, not features. Never use them as a source for a
   product claim.
3. **Never lose content.** Each existing page you move or rewrite has a
   *preservation checklist* (§5). Every fact in the old page lands in a new
   page, or is cut with a written reason ("false at <SHA>", "duplicate of
   <page>").
4. **Stay inside your write scope.** Each WP lists the paths it may create or
   edit. Two WPs never write the same file. If you need a change outside your
   scope, write it in your report as a request.
5. **Do not change product code.** Not `src/`, `frontend/`, `packages/`,
   `db/`, `spec/`. If the code has a bug or a doc in `doc/` is wrong, log it.
   The only code you may write is under `site-docs/` and `scripts/gen_docs/`,
   and only when your WP says so.
6. **Do not hand-edit generated pages.** The pages under
   `site-docs/src/content/docs/reference/` listed in §7 come from
   `scripts/gen_docs/`. Change the generator, then run `make gen-docs`.
7. **English first.** Do not edit `fr/` pages except where WP 11 (moves) or
   WP 22 (translation) says so.
8. **Ask instead of guessing.** If a decision in `99-decisions.md` is still
   open and it blocks your page, stop on that page, write what you need, and
   continue with the next page.

## 3. Paths

| What | Path |
|---|---|
| English pages | `site-docs/src/content/docs/<tab>/<group>/<page>.md` |
| French pages | `site-docs/src/content/docs/fr/<same path>` |
| Tabs | `discover`, `use`, `build`, `admin`, `reference` (see `02-information-architecture.md`) |
| Example data | `site-docs/examples/brightwater/` (WP 12) |
| Screenshots | `site-docs/src/assets/screens/<tab>/<page>-<n>.png` (WP 14 owns the capture script) |
| Ledgers | `doc/plans/documentation-v2/ledgers/<wp>-<batch>.md` |
| Discrepancy log | `doc/plans/documentation-v2/ledgers/discrepancies.md` (append only; every WP may append) |

The page map in [`03-page-map.md`](03-page-map.md) fixes the path of every
page. Do not invent new paths. If a page truly needs to exist and is not in
the map, add it to your report as a proposal, then write it only if your WP
allows "new pages at your discretion".

## 4. Front-matter

Every content page carries:

```yaml
---
title: Hide a field from some roles
description: Mark sensitive fields with a tag so that only the roles you choose can read them.
type: how-to
audience: [admin]
features: [RBC-04, AUD-03]
verified_at: 1e3f27b
sidebar:
  order: 4
---
```

| Key | Rule |
|---|---|
| `title` | Sentence case, 40 characters or fewer. Say the job or the idea in the reader's words. See `01-voice-and-vibe.md` §6. |
| `description` | One sentence, active voice, 160 characters or fewer. It appears in search results and link previews: make it say what the reader gets. |
| `type` | One of `overview`, `tutorial`, `how-to`, `explanation`, `reference`. New key; WP 11 adds it to the schema. |
| `audience` | One or more of `evaluator`, `user`, `author`, `admin`, `developer`, `operator`. |
| `features` | Inventory IDs the page *documents* (not merely mentions). Flat array, one line. |
| `verified_at` | `git rev-parse --short HEAD` at the time you verified the page. |
| `sidebar.order` | From the page map. |
| `prev` / `next` | Tutorials only: Starlight's built-in keys, to chain the steps. |

## 5. The preservation checklist

Before you rewrite or merge an existing page, create its checklist in your
ledger:

```markdown
### govern/field-visibility-tags.md → admin/people/hidden-fields.md

| Old heading / fact | Destination | Status |
|---|---|---|
| ## When to use this | admin/people/hidden-fields.md §lead | moved |
| Table: tag → effect on read | admin/people/hidden-fields.md §Explanation | moved |
| Audit redaction (AUD-03) paragraph | admin/history/audit.md §Redacted values | moved |
| "Tags apply to API keys" note | — | cut: false at 1e3f27b, see discrepancies #12 |
```

List every H2, H3, table, aside, and code block of the old page. A row is
done when its status is `moved`, `merged`, or `cut: <reason>`. Your WP is not
done while a row is open.

## 6. The ledgers

Each WP keeps one ledger file per batch: `ledgers/<wp>-<batch>.md`. It has
three parts:

1. **Preservation checklists** (§5), one per old page.
2. **Claim ledger.** For each page, the claims a reader could act on (a
   value, a limit, a label, a command, a default, a behaviour), each with
   its source: `src/…:line`, `frontend/…`, `doc/…`, a command and its
   output, or "UI, checked on the running app". A sample of 1 in 5 claims
   per page is the minimum; all numbers, defaults, limits and security
   statements must be in the ledger.
3. **Open questions.** Anything you could not verify.

The **discrepancy log** (`ledgers/discrepancies.md`) is shared and append
only. Add a numbered entry when:

- a `doc/` concern file contradicts the code,
- the code looks buggy, or the UI label differs from the docs,
- the current site states something false.

Format: `## #<n> — <short title>` then `Where`, `Docs say`, `Code does`,
`Evidence`, `Found by WP <nn>`. Never fix the code; the maintainer triages.

## 7. Generated pages (do not edit by hand)

`reference/account-settings-keys.md`, `agent-tools.md`, `cli-facet.md`,
`cli-npm.md`, `config-keys.md`, `doctype-schema.md`, `dvt-schema.md`,
`feature-index.md`, `field-types.md`, `filter-operators.md`,
`health-metrics-names.md`, `lua-api.md`, `system-settings-keys.md`,
`webhook-payloads.md`, and the OpenAPI embed behind `rest-api.mdx`. Their
generators live in `scripts/gen_docs/`; `make gen-docs` regenerates all of
them. French overlays for them come from `scripts/gen_docs/fr_overlay*`.

## 8. Gates (run all before you report)

```sh
cd site-docs
npm run build                               # compiles, renders diagrams, emits llms*.txt and .md twins
node scripts/check-coverage.mjs             # coverage + staleness report (warn mode)
```

Plus the checks WP 11 adds (see `11-wp-scaffold.md`): the internal link
validator (fails the build on a dead link), the title length check, and the
`type` front-matter check.

Then check by hand:

- `npm run preview` and open every page you touched. Sidebar entry present,
  diagrams render, screenshots load, links work.
- Your pages appear in `dist/llms-full.txt`.
- Read each page top to bottom **as the persona in its `audience`** (see
  `01-voice-and-vibe.md` §2). Could they act on it without opening another
  tab? If not, fix it or link the missing prerequisite at the top.

If two agents share one checkout, run builds one at a time: concurrent builds
collide in `dist/` and `public/diagrams/`.

## 9. Definition of done (per page)

- [ ] Path, title, `sidebar.order` and `type` match `03-page-map.md`.
- [ ] Front-matter complete (§4); `verified_at` is the SHA you checked against.
- [ ] Passes the voice checklist in `01-voice-and-vibe.md` §10.
- [ ] Every number, default, limit, label, command and security statement is
      in the claim ledger with its source.
- [ ] At least one complete, copyable example, using the running example
      where it fits (`05-running-example.md`).
- [ ] Preservation checklist closed (for moved or rewritten pages).
- [ ] `## Related` links the neighbour pages, including the page one layer
      deeper and one layer up (see `02-information-architecture.md` §3).
- [ ] All gates in §8 pass.

## 10. Report format

End every WP with a report in this shape:

```markdown
## WP <nn> batch <X> — report
- Pages written: <n> (new <n>, rewritten <n>, moved only <n>)
- Feature IDs now covered by this batch: <list>
- Gates: build ✅/❌, coverage (covered/total), links ✅/❌
- Discrepancies logged: #<n>, #<n>
- Not verified (and why): <list>
- Requests outside my scope: <list>
- Proposals (new pages, map changes): <list>
```
