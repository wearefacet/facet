# WP 14 — Your first hour (tutorials) and screenshots

**Goal:** one guided path takes a newcomer from nothing to Facet running, a
domain modelled, an app shipped, a colleague invited and an agent connected.
Every step works on a fresh instance, exactly as written.

**Depends on:** WP 11, WP 12; decision D5 (screenshots); for tutorial 5, an
MCP client and an LLM endpoint in the test environment.

**Write scope:**

- `site-docs/src/content/docs/build/first-hour/**`
- `site-docs/src/content/docs/build/dev-environment.md`
- `site-docs/examples/brightwater/checkout-app/` (the finished app source, tutorial 3)
- `site-docs/scripts/screens/` (capture script) and
  `site-docs/src/assets/screens/**` (all screenshots, for every tab: other WPs
  request shots, this WP's script produces them)

---

## Part A — The screenshot pipeline (do this first)

Other WPs depend on it.

1. Write a capture script with Playwright (the repo already uses it under
   `e2e/`). It starts from a fresh instance loaded with the Brightwater
   example (`site-docs/examples/brightwater/load.sh`), signs in as a named
   persona, visits a list of shots, and saves PNGs.
2. Shots are declared in one file (`site-docs/scripts/screens/shots.yml`):
   id, persona, URL or click path, viewport (1280×800), theme (light),
   optional element to crop to, optional highlight box.
3. Output goes to `site-docs/src/assets/screens/<tab>/<page>-<n>.png`.
   Pages embed them with standard markdown images so the `.md` twin keeps an
   image line with alt text.
4. Freeze the clock or seed data to the example's anchor date so the shots
   are stable across runs.
5. Document the pipeline in `doc/site-docs.md` is out of scope for this WP:
   write the section text in your report and WP 20 or the maintainer adds it.
6. Other WPs add rows to `shots.yml` through requests in their reports; you
   (or the maintainer) run the script. If WP 14 is finished before those
   requests arrive, any later WP may append rows to `shots.yml` and run the
   script — `shots.yml` is the one shared file, append only.

## Part B — The tutorials

| # | Path | Title | Persona | Result | Features |
|---|---|---|---|---|---|
| 0 | `index.md` | Your first hour | all | Knows the route, the time, the prerequisites. Card per tutorial. | — |
| 1 | `run-facet.md` | Run Facet | Marc, Sam | Containers up, first admin created, signed in, welcome tour done. | PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24 |
| 2 | `first-domain.md` | Model your first domain | Inès | The `equipment` domain built **in a draft with the domain-builder assistant**, refined in the Builder, checked, published; a kanban board of maintenance tickets. | DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03, AI-02 |
| 2b | `first-domain-in-files.md` | The same domain in files | Sam | The same domain as files under the watcher; one change saved and seen live; exported as a bundle. Optional; developers only. | DOM-19, DOM-15 |
| 3 | `first-app.md` | Ship your first app | Sam | The Brightwater check-out app: registered, scaffolded with `@facetapp/cli`, built with a coding agent (give the exact prompt), deployed, signed in through Facet as Lucía. | APP-01, APP-02, APP-05, APP-06, APP-09, APP-10 |
| 4 | `team-access.md` | Give your team access | Marc | Lucía invited; the `warehouse` role sees equipment but not purchase prices; Tom sees only his clients. | IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11 |
| 5 | `connect-an-agent.md` | Connect an AI agent | Sam, Inès | An MCP client connected under the `manager` role answers "Which tents are free on <date>?" and the call shows in the audit. | AI-05, APP-04, AI-04 |

Sidebar order (`sidebar.order`): index 0, run-facet 1, first-domain 2,
first-domain-in-files 3, first-app 4, team-access 5, connect-an-agent 6.

`dev-environment.md` (*Set up a dev environment*, how-to, developer): from
the old `start/install.md`. Who needs it (files mode, app development,
contributors), the steps, how to check it works.

### Tutorial page shape

```markdown
---
title: Model your first domain
type: tutorial
prev: /build/first-hour/run-facet/
next: /build/first-hour/first-app/
...
---

<Lead: what you will build and why it matters, 2–3 sentences.>

**You will build:** <one line>
**Time:** <n> minutes
**You need:** <list, each linked>

## 1. <Step, as an action>
<Do this.> <You should see this.> ![alt](screenshot)

## 2. …

## What you learned
- <idea> — read more in <L1 page>
- …

## Next
<One sentence and the link to the next tutorial.>
```

### Rules

- **Every step is run, on a fresh instance, at the commit in `verified_at`.**
  Paste real output; capture real screenshots.
- **The assistant step must be reproducible.** LLM output varies. Give the
  exact prompt, show one real result, then tell the reader what to check
  ("you should see a doctype named *Item* with at least these fields…") and
  what to do if the result differs (edit in the Builder; the tutorial
  continues from the Builder state). Never rely on the exact wording of the
  model's answer.
- **Tutorial 2 teaches the in-app path.** Name the files path once with a
  link to 2b. Tutorial 2b names the in-app path once with a link to 2.
- **Tutorial 3's coding-agent prompt** must work with a generic coding agent.
  Give the prompt as a copyable block. Also give the finished app source as a
  fallback: commit it under `site-docs/examples/brightwater/checkout-app/`
  (this WP owns that sub-folder) and link it from the tutorial.
- **No step depends on a page the reader has not seen.** Each tutorial links
  its prerequisites at the top.
- Keep each tutorial under 20 minutes for a careful first-time reader; split
  if longer.
- The old planned T3/T5/T6 in `doc/plans/documentation/06-tutorials-advanced.md`
  are inputs; read them, take what is still true.
- Tutorial testing in CI (old WP 16) is out of scope, but write each tutorial
  so that its commands could be scripted: no hidden steps.

## Done when

- [ ] Capture script runs from a fresh instance and produces every shot in
      `shots.yml`; a second run gives identical files (or near-identical: note
      known variance).
- [ ] All seven pages written; each tutorial executed end to end on a fresh
      instance; timings recorded in the ledger.
- [ ] `prev`/`next` chain works from 1 to 5 (2b is a side branch: its `next`
      is tutorial 3).
- [ ] Preservation checklists closed for T1, T2, T4 and `start/install.md`.
- [ ] Gates pass; report per `00-contract.md` §10, including actual time per
      tutorial.
