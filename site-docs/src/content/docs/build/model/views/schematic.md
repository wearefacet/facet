---
type: how-to
title: See your domain as a diagram
description: Read and arrange a domain's doctypes as a schematic boxes-and-arrows diagram.
audience: [author]
features: [DOM-20]
sidebar:
  order: 3
verified_at: eee55a2
---

You inherit a domain with nine doctypes, and a new colleague asks how they
fit together. The schematic view draws the domain as boxes and arrows: each
box is a doctype, each arrow a relation between two doctypes. You read the
shape of the model at a glance, and you drag boxes to arrange the picture
for your team.

## When to use this

- You joined a domain and want its structure in one picture.
- You plan a new doctype and check where it attaches.
- You present the model to a customer or a new colleague.

## Before you start

- **Where to find it.** Open **Configure**, pick the domain, and open the
  **Doctypes** tab. The Builder shows the same picture for a draft.
- **Read-only structure.** The picture is read-only for structure. You
  change relations by editing doctypes, not by editing the picture.

## Read the picture

Each box shows the doctype's name and its color. A doctype with a declared
color keeps it. A doctype without one gets a stable generated color, so the
same doctype always looks the same.

| Arrow | Meaning |
| --- | --- |
| Solid line with a filled diamond | Composition: the diamond sits on the parent, and the child cannot live without it. |
| Dashed line with an open arrow | Reference: one doctype points at another and stays independent. |

Boxes start in two columns: aggregate roots on the left, their children
grouped on the right. A root with many children pulls its group downward.

## Arrange the picture

Drag a box anywhere. The arrows follow. When you drop it, Facet saves the
position for the whole domain: every viewer of this domain sees your
arrangement.

:::caution
The layout is shared, not personal. Two people arranging at the same time
overwrite each other; the last save wins.
:::

Select a box. Facet highlights it and opens the doctype's page, where you
edit its fields and relations. Add a doctype through the doctype editor;
the picture picks it up on the next view.

## Example

The Brightwater `equipment` domain has three aggregate roots, linked by
two references between same-domain doctypes. The picture reads:

*The equipment domain: three aggregate roots, linked by two references.*

<!-- d2
item: equipment.Item
ticket: equipment.MaintenanceTicket
category: equipment.Category

item -> category: reference {style: {stroke-dash: 3}}
ticket -> item: reference {style: {stroke-dash: 3}}
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/b6b44e05-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/b6b44e05-dark.svg" alt="Diagram" loading="lazy" />
</div>

All three doctypes are aggregate roots, so every arrow is dashed and carries
the open arrow: a reference points at another doctype, and both survive
alone. If the domain owned a child — say a doctype of repair logs declared
with `member_of: MaintenanceTicket` — the arrow to it would be solid and
carry the filled diamond on the parent.

## Troubleshooting

**A box is missing.**

Only doctypes of this domain appear. A doctype in another domain shows as a
reference target, not as a box.

**My arrangement is gone.**

A colleague saved a new layout, or the domain was re-published. Arrange
again; the save is quick.

**A relation has no arrow.**

Only composition and same-domain references draw. A reference to a doctype
in another domain, or an unregistered target, draws nothing.

**The picture does not match my definitions.**

Reload the tab. The picture reads the stored definitions, so unsaved editor
changes stay invisible.

## Related

- [Design a doctype](/build/model/data/design-doctypes/) — add the doctype the picture is missing.
- [How domains isolate data](/build/deeper/domain-isolation/) — what a domain groups and owns.
- Internals on GitHub: [schematic.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/schematic.md).
