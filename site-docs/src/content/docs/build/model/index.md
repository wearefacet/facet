---
type: overview
title: Choose how you build
description: Two ways to build a domain — in the app with drafts, or in files on a dev server — and how to pick.
audience: [author, developer]
features: [DOM-02, DOM-19]
sidebar:
  order: 0
verified_at: eee55a2
---

Facet gives you two ways to build a domain. Both produce the same thing: a
live domain with doctypes, views, and scripts. Pick by where you work and by
who you are. If you model data in the app today — Airtable bases, for
example — build in the app. If you live in a code editor, or you work with
an AI coding agent, build in files.

## The two modes at a glance

| | In the app: draft → publish | In files: dev mode |
| --- | --- | --- |
| Where | Any instance, including staging and production | A dev server you own; the watcher refuses to start in production |
| Who | Authors, often non-developers | Developers and AI coding agents |
| How you edit | The **Builder** UI or the domain-builder assistant, inside a draft (`_…`) | YAML and Lua files in your editor; the watcher applies each save |
| Safety net | The draft is isolated; **Check** runs diagnostics; publish is one transaction | Version control; drafting is bypassed |
| Test data | Scratch documents in the draft; publish copies structure only | `documents: preserve` or `discard` in the watcher config |
| Reaches production by | **Publish** | Export a bundle, import it on the target, then (optionally) adjust in a draft there |

Every cell is a choice, not a ranking. An author and a developer can work on
the same product: the author models in the app, the developer builds the
domain in files on dev and ships it to them as a bundle.

## Build in the app

You never change a live domain directly. You open a **draft** — a private
copy whose name starts with `_` — change the definitions there, run
**Check**, and **Publish** in one step when it is ready. Publish copies the
structure only, so the test documents you made while experimenting never
reach production data.

- [How drafts work](/build/model/in-app/how-drafts-work/) — the lifecycle, and what publish checks.
- [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/) — open a draft, add co-editors, publish.
- [Build with the assistant](/build/model/in-app/build-with-assistant/) — describe the domain in chat; the assistant writes the draft.
- [Check before you publish](/build/model/in-app/check-before-publish/) — read the diagnostics and clear them.

## Build in files

On a dev server, you can skip the draft loop. You edit a folder of YAML and
Lua files; the **domain watcher** applies every save to the running server.
Version control is your safety net. This mode fits developers and AI coding
agents, because everything is text with a reviewable diff.

- [The domain watcher](/build/model/in-files/domain-watcher/) — connect a folder to a dev server.
- [The domain file layout](/build/model/in-files/domain-files/) — the files the watcher reads, one by one.
- [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/) — set up the agent loop.

## Take it to production

The bridge between the modes is the **bundle**: one folder (or archive) that
carries a domain's definitions. You build in files on dev, export the bundle,
and import it on staging or production. There you can adjust it in a draft
and publish, as the authors there would.

- [From dev to production](/build/model/dev-to-production/) — the round trip, and what moves.
- [Move domains with bundles](/build/model/bundles/) — the export and import commands.
- [Change a live domain safely](/build/model/change-a-live-domain/) — what a schema change costs on live data.

## Can I mix them?

Yes — that is the normal route to production. Build in files on dev, export
the bundle, import it on the target, and let the authors there adjust it in a
draft. [From dev to production](/build/model/dev-to-production/) walks the
round trip with the Brightwater example.

One caution: a domain can receive edits from both sides. On a dev instance
the watcher replaces the definitions on its next sync, so it wins. On
staging or production no watcher runs, so a draft publish wins and the files
never hear about it. The working rule: treat the files as the source of
truth, and re-export after any change made in a draft.

## The rest of this section

The pages below cover the modelling itself. They work the same in both
modes: a field, a relation, a view, or an automation is defined the same way
in a draft and in a file.

| Group | What it covers |
| --- | --- |
| [Data](/build/model/data/design-doctypes/) | Doctypes, field types, identifiers, computed fields, secrets, files |
| [Relations](/build/model/relations/references-links/) | References, parent/child composition, cross-domain sharing, comments and attachments |
| [Views](/build/model/views/names-and-search/) | Display names, document pages, lists and boards, the schematic diagram |
| [Behaviour](/build/model/behaviour/named-actions/) | Named actions, lifecycle scripts and guards |
| [Automation](/build/model/automation/event-hooks/) | Event and schedule hooks, webhooks, notifications |
| [Access](/build/model/access/named-scopes/) | Row rules for roles |

## Related

- [Build domains](/build/) — the section this group sits in.
- [The domain watcher](/build/model/in-files/domain-watcher/) — the files mode, in full.
- [How drafts work](/build/model/in-app/how-drafts-work/) — the app mode, in full.
- [How domains stay isolated](/build/deeper/domain-isolation/) — what a domain bounds, one layer deeper.
