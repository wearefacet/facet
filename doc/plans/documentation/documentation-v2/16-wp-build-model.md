# WP 16 — Build: model your data

**Goal:** an author can model a real business domain, in the app or in files,
understand which way fits them, and take it to production safely. Every
domain-authoring feature is documented, both ways where both exist.

**Depends on:** WP 11, WP 12 (and its files-mode friction notes).
**Audience:** Inès (author, no code) for the in-app path and the shared pages;
Sam (developer) for the files path. Pages that need Lua or Jinja2 say so in
the first lines.

**Write scope:** `site-docs/src/content/docs/build/model/**` and
`site-docs/src/content/docs/build/deeper/**`. Screenshot requests go into
`shots.yml` (append only).

**Batches** (run in order; B and C may run in parallel after A):

| Batch | Pages |
|---|---|
| A — the build modes | `build/model/index.md` (Choose how you build), `in-app/*` (4), `in-files/*` (3), `dev-to-production.md`, `bundles.md`, `change-a-live-domain.md`, `build/deeper/*` (5 incl. index) |
| B — data and relations | `data/*` (6), `relations/*` (4) |
| C — views, behaviour, automation, access | `views/*` (4), `behaviour/*` (2), `automation/*` (3), `access/named-scopes.md` |

Paths and titles: `03-page-map.md` §3, §5, §9.

---

## The two build modes (the core of this WP)

Read `02-information-architecture.md` §2.3 first. Facet has two ways to
build a domain, and the reader must meet that choice before anything else in
this group:

1. **In the app — draft, then publish.** On any instance, including staging
   and production. You open a draft (a private copy whose name starts with
   `_`), change it in the **Builder** or with the domain-builder assistant,
   run **Check**, and **Publish** in one transaction. Publish copies
   structure only, never the draft's test documents.
2. **In files — dev mode.** On a dev server only (the watcher refuses to run
   in production). You edit YAML and Lua files; the domain watcher applies
   every save to the running server. Drafting is bypassed. Version control is
   your safety net. This is the natural mode for developers and AI coding
   agents.

The bridge between them is the **bundle**: export a domain from dev, import
it on staging or production.

### Batch A — what each page must answer

**`build/model/index.md` — Choose how you build** (`overview`)

- Lead: two ways, one result; pick by *where* you work and *who* you are.
- The comparison table from `02` §2.3, every cell verified.
- Three cards: *Build in the app*, *Build in files*, *Take it to production*.
- "Can I mix them?" — answer from the code, then link `dev-to-production`.
- Then the map of shared pages (data, relations, views, behaviour,
  automation, access) with one line each: "these work the same in both modes".

**`in-app/how-drafts-work.md`** (`explanation`, from `concepts/draft-publish.md`):
the lifecycle diagram (live → draft → edit → check → publish → live; draft
dropped), what a draft allows, what publish checks, why test documents never
reach production. Names: `_` prefix, generated name, no version gate (L3
details in a "How it works" section).

**`in-app/drafts-and-publishing.md`**: open a draft (new or from a live
domain), co-editors (who can add them: verify), publish, discard. Builder
screenshots.

**`in-app/build-with-assistant.md`**: how to ask, what it can do in a draft,
what it cannot, that its changes are attributed to you, how to review.
Prompts that work, as copyable blocks. Same reproducibility rule as
tutorials (`14` Part B).

**`in-app/check-before-publish.md`**: diagnostics — what is checked, how
errors read, fix loop. **Verify whether the same diagnostics run in files mode
(watcher) and how they surface there**; document both.

**`in-files/domain-watcher.md`** (from `build/dev-domain-watcher.md`): config
(`dev.domain_watch.*`), `documents: preserve | discard` and what each does to
data, the refusal in production, the "config line is the consent" caution,
what happens on a broken file.

**`in-files/domain-files.md`** (new, `reference`): the folder layout the
watcher reads, file by file (domain, doctypes, Lua sidecars, views, hooks),
with a complete minimal example from the Brightwater bundle; how it compares to
the exported bundle layout (`doc/backend/portable-domains.md`). If the watcher
layout and the bundle layout are the same, say so plainly — it is the key to
the round trip.

**`in-files/with-a-coding-agent.md`** (new): the agent writes files, the
watcher applies, diagnostics come back; which skill docs or `doc/` files to
point the agent at (verify what exists: `src/assistant/domain_builder/skills/`,
`doc/ops/build-a-domain.md`); a copyable starting prompt; how to review the
diff. Take the domain part of the old `apps/ai-coding-agents.md`.

**`dev-to-production.md`** (new): the round trip as a diagram — files on dev
→ export bundle → import on staging → (optional) adjust in a draft → publish
→ export again for production. Answer, with evidence from the code:

- What a bundle carries (domain, doctypes, scripts, owned document views,
  general collection views) and what it does not (documents unless
  `--with-documents`, personal views, roles? grants? secrets? — verify each).
- What import does to an existing domain of the same name.
- What happens to live documents when the imported schema differs (link
  `change-a-live-domain` and `deeper/schema-evolution`).
- What happens if the same domain is edited in files on dev and in a draft on
  staging: which wins, how to avoid drift. If the product has no guard, say so
  and give a working rule ("treat files as the source of truth; re-export after
  any change made in a draft").
- Roles and seed data: how they travel (from WP 12's findings).

**`bundles.md`**: the commands (`facet domain:export`, import), flags, the
`.facet-domain` formats (directory, `.zip`, `.tar.gz`), secrets stripping
(verify), errors.

**`change-a-live-domain.md`** (from `build/evolving-schema.md`): which changes
are safe, which need care, how existing documents follow (one plain paragraph,
link `deeper/schema-evolution`), the re-projection CLI (DOM-18).

**`build/deeper/*`**: `index.md` (picker), `domain-isolation.md`,
`documents-and-projections.md`, `schema-evolution.md`,
`cross-domain-replication.md`. These are L3: full precision, engine words
allowed and defined, each with a diagram. Their L1 halves live in Discover
(WP 13); link up to them.

### Batches B and C — the shared pages

Every shared page follows the same pattern:

1. Lead with the Brightwater job ("Each item needs a serial number, and no
   two items may share one").
2. **When to use this** / **Before you start**.
3. **Steps**, with synced mode tabs:

   ````mdx
   import { Tabs, TabItem } from '@astrojs/starlight/components';

   <Tabs syncKey="build-mode">
     <TabItem label="Builder">
       1. Open the draft of **equipment** in the **Builder**.
       2. …
     </TabItem>
     <TabItem label="Files">
       ```yaml
       # equipment/doctypes/Item.yml
       …complete fragment from the example bundle…
       ```
     </TabItem>
   </Tabs>
   ````

   Pages that use tabs become `.mdx`. Check that the `.md` twin and
   `llms-full.txt` still show both tab contents (they should, as plain
   text); if they do not, report it and fall back to two H3 sections
   ("In the Builder", "In files").
4. **Example**, complete, from the Brightwater bundle.
5. **Troubleshooting** in the author's words.
6. **How it works** (optional, short) and **Related** (layer links).

Where a feature can only be set in one mode, skip the tabs and state it in
one line ("Lifecycle scripts are written in Lua; in the Builder you paste the
script into the doctype's **Script** field" — verify).

Batch-specific notes:

- **Field types** (`data/field-types.md`): a "which type for which job" table
  first (text, number, money, date, choice, reference, file, secret…), then
  the details; the full generated list stays in `reference/field-types.md`.
- **Scripts and guards**, **event hooks**: open with "You need Lua for this
  page" and a ten-line Lua primer link (`reference/lua-api.md`); show the
  smallest real script from the example.
- **Views** pages: screenshots of the result in the workspace for each view
  type.
- **Webhooks**: delivery guarantees in one plain paragraph ("in rare failures
  an event can be missed; a reconcile job repairs it" — verify), with the
  link to `admin/under-the-hood/events-and-delivery`.
- **Named scopes** is the author half of row scopes; the admin half is
  `admin/people/row-scopes.md` (WP 18). Both pages show the same Brightwater
  example ("Tom sees his clients") and link each other at the top.

## Features

This WP covers at least: DOM-01 to DOM-25 (author side), DOC-05, DOC-07,
DOC-09, DOC-10, DOC-13, AUT-02, AUT-03, AUT-06 (author side), AUT-08, PLT-03,
PLT-04 (author side), AI-02, AI-06, FE-10, FE-13 (author side). Check every
row of `surfaces.md` for doctype schema keys, DVT schema keys, Jinja2
variables, Lua functions and watcher config keys, and fill the page column.

## Done when

- [ ] Batch A: a reader can say which mode to use, why, and how to move a
      domain from dev to production — tested by doing it with the Brightwater
      bundle.
- [ ] Every shared page shows both modes where both exist, with complete
      examples that you ran.
- [ ] Every feature above has a `how-to` or `explanation` page here (R2).
- [ ] Preservation checklists closed for all old `build/*` pages and the
      concept pages this WP owns.
- [ ] Gates pass; report per `00-contract.md` §10.
