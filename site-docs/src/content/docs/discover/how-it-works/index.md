---
type: explanation
title: The big picture
description: One picture, five ideas — what Facet does every time your team reads or changes a record.
audience: [evaluator]
features: []
verified_at: eee55a2
sidebar:
  order: 0
---

Before the details, one picture. Here is what happens every time someone at Brightwater looks at, or changes, a record.

*One door. One set of checks. One memory.*

<!-- d2
direction: down
people: "People" {class: external}
apps: "Apps" {class: external}
agents: "AI agents" {class: external}
door: "Sign in once. Facet knows who you are and which role you act as" {class: decision}
checks: "Every read and write passes the role's checks"
domains: "Domains: equipment, clients, rentals" {class: store}
history: "Every change, remembered" {class: store}
people -> door
apps -> door
agents -> door
door -> checks
checks -> domains
checks -> history
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/b4865c1b-light.svg" alt="People" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/b4865c1b-dark.svg" alt="People" loading="lazy" />
</div>

## Five ideas, five short pages

**Your records live in domains.** A domain is one business area — for Brightwater: *equipment*, *clients*, *rentals*. Each stays separate; nothing crosses the line unless someone agrees to it. Read [Domains: where your data lives](/discover/how-it-works/domains/).

**Each record is a document with a memory.** Create a booking, change it, regret it — every step is recorded, with who and when, and you can undo. Read [Documents: records with a memory](/discover/how-it-works/documents/).

**A role decides who sees and does what.** Tom sees only his own clients; Lucía never sees purchase prices. The checks run on every read and write, in every app, for every agent. Read [Roles: who sees and does what](/discover/how-it-works/roles/).

**Apps connect from outside.** The warehouse check-out app signs in through Facet and reaches only what it was given. Facet can host it; your data outlives it. Read [Apps: built fast, replaced freely](/discover/how-it-works/apps/).

**The assistant answers in your words.** You ask in plain words; it reads records for you, and changes them when you say so — under your rights, with your name in the history. Read [The assistant: AI with your rights](/discover/how-it-works/assistant/).

## What this means for you

- You describe the business; Facet holds it. The data model matches your departments, not a vendor's modules.
- Nobody configures security inside each tool. The rules sit in one place and apply everywhere.
- Replacing an app is a Tuesday task, not a migration project.
- You can hand an AI agent real work, because its rights are as bounded as anyone's.

## For the technical detail

- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — how every channel resolves to one identity and one role.
- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — where the checks sit, and their order.
- [The change log, in detail](/admin/under-the-hood/change-log/) — the memory, row by row.
- [Events and delivery](/admin/under-the-hood/events-and-delivery/) — how reactions to a change are delivered.

## Related

- [Why Facet](/discover/why-facet/) — the problems behind the picture.
- [Security and governance](/discover/security/) — the same checks, for an audit.
- The glossary collects every product term: [Glossary](/reference/glossary/).
