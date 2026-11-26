---
type: explanation
title: "Roles: who sees and does what"
description: See how roles decide who sees and does what, one role at a time, on every surface.
audience: [evaluator, admin]
features: [RBC-01, RBC-02, RBC-04, RBC-05]
verified_at: eee55a2
sidebar:
  order: 3
---

Who may see which clients? Who may change a price, and who may not even see one? In Facet the answer attaches to a **role**: a named bundle of rules you give to a person's account.

*A role decides the rows you may reach and the fields you may read. The checks run every time, on every surface.*

<!-- d2
direction: down
tom: "Tom · sales" {class: external}
tomrows: "His list shows only his five clients" {class: ok}
lucia: "Lucía · warehouse" {class: external}
luciafields: "She opens an item: no purchase price on the page" {class: ok}
tom -> tomrows: "row rule"
lucia -> luciafields: "field rule"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/f572c5cd-light.svg" alt="Tom · sales" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/f572c5cd-dark.svg" alt="Tom · sales" loading="lazy" />
</div>

## One role at a time

Someone can hold several roles — say, *Sales* and *Manager*. When they sign in, Facet puts them under one of them; if they hold more than one, the account menu carries **Switch Role**. Everything they see and do follows that one role until they switch.

One role at a time keeps every action easy to explain later: the history shows who did it, and as which role.

## A role decides which rows you reach

Brightwater wants each salesperson to see only the clients they manage. Tom's *Sales* role carries that rule, so his client list shows his five companies — not the other seven. The same rule shapes search, other apps, and the assistant; there is no screen where the rule stops.

A rule like "clients whose account manager is me" is a **row scope**: a saved filter a role can carry.

## A role decides which fields you read

Lucía's *Warehouse* role reads every item, because the team needs to know what is in stock. What she does not need is what each item cost. The purchase price field carries a **field tag** — a sensitivity label — and her role does not hold it. She opens an item and the field is not there: not greyed out, not "no access" — absent, on screens and in the API alike.

## Checked every time

These rules are not settings inside each app. Facet checks them on every read and write, whatever sent the request — the workspace, an app, a key, or an AI agent. An app cannot bypass the rules its users are subject to; the assistant cannot show Tom someone else's clients. One rule set, enforced in one place.

## What this means for you

- Describe access the way you describe jobs: "salespeople see their own clients", not a matrix of checkboxes.
- Sensitive fields are hidden by design, not by trust — and hidden for machines as well as people.
- When someone changes jobs, one role assignment moves them; no tool-by-tool clean-up.

## For the technical detail

- [Why you act as one role at a time](/admin/under-the-hood/one-role-at-a-time/) — the rule and its reasons.
- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — the checks, in order.
- [Show each role only its own rows](/admin/people/row-scopes/) — set up row scopes.
- [Hide a field from some roles](/admin/people/hidden-fields/) — set up field tags.

## Related

- [The big picture](/discover/how-it-works/) — where roles sit among the five ideas.
- [Documents: records with a memory](/discover/how-it-works/documents/) — what a recorded change says about the role.
- [Roles and permissions](/admin/people/roles-and-permissions/) — create roles and give them to people.
