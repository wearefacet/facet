---
type: how-to
title: Build domains with a coding agent
description: Let an AI coding agent write the domain files while the watcher applies every save and reports the errors back.
audience: [developer]
features: [DOM-19, AI-06]
sidebar:
  order: 2
verified_at: eee55a2
---

You are a developer who builds with an AI coding agent, and the domain you
are modelling belongs in version control, not in editor clicks. Give the
agent the file folder, let the watcher apply every save, and let the check
report tell the agent what to fix. The loop runs without a browser.

## The loop

<!-- d2
agent: "Coding agent edits files"
watcher: "Watcher applies the bundle"
check: "Check runs, log line written"
report: "Agent reads the check report"
fix: "Agent fixes the files" {class: ok}

agent -> watcher: save
watcher -> check
check -> report
report -> fix: issues
report -> agent: clean {class: ok}
fix -> agent
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/fed7ea85-light.svg" alt="Coding agent edits files" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/fed7ea85-dark.svg" alt="Coding agent edits files" loading="lazy" />
</div>

## When to use this

- You model a domain in files, and an agent does the typing.
- You want the domain's history as commits, with reviewable diffs.
- You build a domain and an app together, in one repository.

## Before you start

- **A dev server with the watcher on** — see [The domain
  watcher](/build/model/in-files/domain-watcher/). Keep `documents:
  preserve` while an agent works; `discard` wipes app-created rows on every
  save.
- **A folder per domain under version control**, laid out as [The domain
  file layout](/build/model/in-files/domain-files/) describes.
- **Access to the check report endpoint**, so the agent can read its own
  errors.

## What to point the agent at

An agent works from text. Give it these, in this order:

1. **The site docs.** `npm run build` in `site-docs/` emits `llms-full.txt`
   and a `.md` twin for every page — one file an agent can ingest.
2. **The generated doctype schema** at
   `reference/doctype-schema/` — the definition keys and their types.
3. **`doc/ops/build-a-domain.md`** in the repository — the API recipe for
   the draft loop and the direct path, with status codes.
4. **`doc/backend/portable-domains.md`** in the repository — the bundle
   format, the validation rules, and every error the import can answer.

One corpus an agent cannot reach: the builder assistant's internal skill
files. They are mounted only inside the in-app assistant, never through a
route an external agent could call. The site docs cover the same ground.

## A starting prompt that works

````text
You are extending a Facet domain in files. The folder
site-docs/examples/brightwater/equipment.facet-domain holds the running
example; its layout is the Facet bundle format.

Read these first:
- site-docs/src/content/docs/build/model/in-files/domain-files.md (the layout)
- site-docs/src/content/docs/build/model/data/design-doctypes.md (definitions)

Then: add a Supplier doctype to the equipment domain. Fields: name
(string, required), city (string), lead_time_days (integer). Give it a
display_name template and add a reference field `supplier` to
equipment.Item. Keep every file valid YAML; reference targets use the
qualified equipment.Supplier form.

After each save, read the watcher's log line and
GET /Api/dev/check-report?domain=equipment (Authorization header from
`facet-cli apikey`). Fix every issue before you finish. Commit with a message
that says what you modelled.
````

The loop that follows is mechanical: the agent saves, the watcher syncs, the
report names what broke, the agent fixes it. A clean report is the finish
line — the same report the Builder shows a human author.

## How to review the diff

The safety net is git, and the diff reads like any code review:

- **One save, one commit.** Ask the agent to commit after each working
  step, so a bad edit reverts alone.
- **The log lines are the test run.** `[dev-sync] synced 'equipment' …`
  counts what landed; the check line counts what is wrong. No green line, no
  merge.
- **Read the report, not only the count.** `GET /Api/dev/check-report`
  returns every issue with its field and message — the same shape the
  publish dialog shows.
- **Data edits are not reviewable this way.** `preserve` mode keeps
  app-created rows, but a bundled `documents/` tree edits data through
  files. Review those diffs like data migrations.

## Troubleshooting

**The agent edits files outside a bundle.**

A file outside a `{name}.facet-domain/` folder is invisible to the watcher.
Point the prompt at the exact folder, and keep scratch files elsewhere.

**Two domains with one name.**

Two folders declaring the same `source_domain` conflict; only the
alphabetically first syncs, and the log warns on every cycle. One folder per
domain.

**The agent chases a version gate error.**

There is none in files mode. The watcher imports fresh every time, so a
destructive edit applies outright — no `schema_version` bump, no migration.
That is why version control is the safety net, and why a questionable
destructive edit deserves its own commit you can revert.

**The agent cannot read the check report.**

The endpoint needs authentication and a dev server. In production it answers
`404` — point the agent at the dev instance.

## Related

- [The domain watcher](/build/model/in-files/domain-watcher/) — the sync the agent's saves trigger.
- [The domain file layout](/build/model/in-files/domain-files/) — the files the agent edits.
- [Check before you publish](/build/model/in-app/check-before-publish/) — the report the agent reads.
- [Build apps with a coding agent](/build/apps/agents/coding-agents/) — the app half of the story.
- Internals on GitHub: [dev-domain-watcher.md](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md).
- [Choose how you build](/build/model/)
