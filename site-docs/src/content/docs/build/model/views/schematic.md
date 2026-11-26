---
type: how-to
title: The schematic view
description: Read and arrange a domain's doctypes as a boxes-and-arrows diagram.
audience: [author]
features: [DOM-20]
sidebar:
  order: 3
verified_at: fd345fe3
---

The schematic view draws a domain as boxes and arrows. Each box is a doctype. Each arrow is a relation between two doctypes. You read the shape of the domain at a glance, and you drag boxes to arrange the picture for your team.

## When to use this

- You joined a domain and want its structure in one picture.
- You plan a new doctype and check where it attaches.
- You present the model to a customer or a new colleague.

## Before you start

- **Where to find it.** Open **Configure**, pick the domain, and open the **Doctypes** tab. The Builder shows the same picture for a draft.
- **Read-only structure.** The picture is read-only for structure. You change relations by editing doctypes, not by editing the picture.

## Steps

### 1. Read the boxes

Each box shows the doctype's name and its color. A doctype with a declared color keeps it. A doctype without one gets a stable generated color, so the same doctype always looks the same.

### 2. Read the arrows

| Arrow | Meaning |
| --- | --- |
| Solid line with a filled diamond | Composition: the diamond sits on the parent, and the child cannot live without it. |
| Dashed line with an open arrow | Reference: one doctype points at another and stays independent. |

Boxes start in two columns: aggregate roots on the left, their children grouped on the right. A root with many children pulls its group downward.

### 3. Move the boxes

Drag a box anywhere. The arrows follow. When you drop it, Facet saves the position for the whole domain: every viewer of this domain sees your arrangement.

:::caution
The layout is shared, not personal. Two people arranging at the same time overwrite each other; the last save wins.
:::

### 4. Open a doctype

Select a box. Facet highlights it and opens the doctype's page, where you edit its fields and relations. Add a doctype through the doctype editor; the picture picks it up on the next view.

## Example

A domain `helpdesk` carries two aggregate roots. `Ticket` has a `Comment` child and a reference to `Account`. `Account` stands alone. The picture reads:

<!-- d2
ticket: Ticket
comment: Comment
account: Account

ticket -> comment: child
ticket -> account: reference {style: {stroke-dash: 3}}
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/bcce1090-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/bcce1090-dark.svg" alt="Diagram" loading="lazy" />
</div>

The solid arrow to `Comment` carries the filled diamond on `Ticket`: the comment is part of the ticket, and deleting the ticket removes its comments. The dashed arrow to `Account` carries the open arrow: the ticket points at the account, and both survive alone.

## Troubleshooting

**A box is missing.**

Only doctypes of this domain appear. A doctype in another domain shows as a reference target, not as a box.

**My arrangement is gone.**

A colleague saved a new layout, or the domain was re-published. Arrange again; the save is quick.

**A relation has no arrow.**

Only composition and same-domain references draw. A reference to a doctype in another domain, or an unregistered target, draws nothing.

**The picture does not match my definitions.**

Reload the tab. The picture reads the stored definitions, so unsaved editor changes stay invisible.

## Related

- [Schematic concern doc](https://github.com/wearefacet/facet/blob/main/doc/frontend/schematic.md) — the renderer and the layout store.
- [Domains and isolation](/discover/how-it-works/domains/) — what a domain groups.
- [Designing doctypes](/build/model/data/design-doctypes/) — add the doctype the picture is missing.
