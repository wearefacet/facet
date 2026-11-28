# WP 20 — Navigation pass

**Goal:** the site reads as one product. Every entry point routes the reader
to the right place, every page links up and down, and no page is a dead end.

**Depends on:** WP 13–19 done.
**Write scope:**

- `site-docs/src/content/docs/index.mdx` (landing, English) and the landing
  components under `site-docs/src/components/landing/` (wiring only)
- the five tab index pages: `discover/index.md` is WP 13's — **do not edit
  it**; write `use/index.md`, `build/index.md`, `admin/index.md`,
  `reference/index.md`
- `## Related` sections and "Before you start" links on **any** page (links
  only; no other prose changes). Announce the start and end of this pass so
  that no other WP writes pages at the same time.
- `doc/site-docs.md` (Landing page section; screenshot pipeline section from
  WP 14's report)

---

## Tasks

1. **Landing page.** Hero: one sentence of what Facet is (from Why Facet),
   two buttons: **Your first hour** and **How Facet works**. Then the three
   promise pillars (keep), the flow diagram (keep, labels checked), and five
   doors — one per tab, each with the question it answers (`02` §2). Keep
   all words in the `.mdx` file (`doc/site-docs.md` → Landing page rules).
2. **Tab index pages** for Use, Build, Administer, Reference: path pickers per
   `02` §5. Build's index has three cards: *Try it in an hour*, *Model your
   data* (→ Choose how you build), *Build an app*. Administer's index has
   four: *Install*, *Decide who sees what*, *See what happened*, *Keep it
   running*.
3. **R3 coverage (reachability).** For every user-facing feature ID, make sure
   its tab index or group index links (directly or through one named group)
   to the page that documents it. Produce the list by script from the
   front-matter and the index pages; fix gaps by adding links to index pages.
4. **Layer links.** For every page, check `## Related` links one layer up and
   one layer down when such pages exist (`01` §3). Script the check: each
   L2 page with a matching L1 or L3 page (same feature IDs) must link it.
5. **Prerequisites.** For every tutorial and how-to, check that every page or
   concept assumed is linked in **Before you start**. Read each page as its
   persona.
6. **Dead ends.** No page without an outgoing link to another content page.
7. **Search descriptions.** Each page's `description` contains the product
   term of its topic, so search finds a job-titled page by its feature name.

## Done when

- [ ] Landing page and four tab indexes written; landing doors point to the
      five tabs.
- [ ] R3 script passes (every user-facing ID reachable from its tab index
      within two clicks).
- [ ] Layer-link and dead-end scripts pass.
- [ ] Gates pass; report per `00-contract.md` §10, with the scripts' output.
