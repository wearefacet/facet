---
type: how-to
title: The dashboard
description: Open the dashboard, read its cards, and reach your records in a few clicks.
audience: [user]
features: [FE-02]
sidebar:
  order: 3
verified_at: 49d7c7e5
---

The dashboard is the page Facet opens after sign-in. It greets you, shows your
active role, and gives you cards to reach every domain you may read. Each
domain has its own dashboard, with your pinned views and your recently opened
records. Start your daily work here.

## Before you start

- **An account.** You need a Facet account. See
  [Sign in, MFA, reset your password](/use/first-day/sign-in/).
- **The right cards.** Your role decides which cards you see. A domain outside
  your rights does not show. See
  [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/).

## The home page

Open `https://facet.localhost:3443/` (or your instance address) and sign in.
The home page shows, from top to bottom:

| Part | What it shows |
| --- | --- |
| Greeting | Your first name, and the role you work under, for example Administrator. |
| Key surfaces | Links to Builder, Domains, Settings, and Apps. A link your role does not allow stays hidden. |
| Applications | One card per application your organization runs; the section hides when there are none. A card your role cannot open shows a lock notice. |
| Drafts in progress | The domain drafts you or your team work on, with a check mark when they are ready to publish. |
| Domains | One card per domain you may read, for example crm or hr. |

Select a domain card to open its dashboard.

:::note
When your role may create doctypes, the Domains section shows a small plus
button on each domain card. It opens the new-doctype dialog. Draft and domain
setup live in Builder; see [Build domains](/build/).
:::

When your account can read no domain, the Domains section shows a first-run
card instead. It offers **New domain** and **Import a bundle**.

## The domain dashboard

The domain dashboard at `/{domain}` (for example `/crm`) shows:

| Section | What it shows |
| --- | --- |
| Header | The domain name, and counts of its doctypes and records. |
| Pinned views | One card per view you pinned, with the view type (table, kanban, or calendar) and the record count. Select a card to open the list. |
| Recently viewed | Chips for the records you opened last in this domain, newest first. |
| Doctypes | Every doctype with its record count, and links to its saved views. |

:::tip
Pin the views you use every day. Open a view on a list page and select the
pin control beside the tabs. The view then appears on this dashboard. See
[Lists, filters and saved views](/use/finding/lists-and-views/).
:::

## Steps

### 1. Open your daily list

Sign in, select a domain card, then select a pinned view. The list opens with
that view active. This is the shortest path to your daily work.

### 2. Return to a record you worked on

Open the domain dashboard and select a chip under **Recently viewed**. The
record opens. Each chip shows the record name and how long ago you opened it,
for example `10m` or `yest`.

### 3. Find a doctype

Open the domain dashboard and read the **Doctypes** list. It shows every
doctype with its record count. A doctype with more than 1000 records shows
`1000+`.

1. Select the type name to open its list.
2. Or select a saved view below it.

With more than six doctypes, the list shows the first six and a
**Show N more** button. Select it to see the rest.

## Example

A daily path through a sales domain:

```
/                     select the crm card
/crm                  select the Pipeline pinned view
/crm/Deal?view=pipeline   the kanban list opens
```

## Troubleshooting

### A domain card is missing

Your role does not read that domain. Ask your administrator. A draft that a
colleague still works on stays out too; a published domain always shows.

### The Pinned views section is empty

You have not pinned a view yet. The section says: **Pin a view and it will
show up here.**

1. Open a list.
2. Select a view.
3. Select the pin control.

### The Recently viewed section is empty

You have not opened records in this domain yet, or your browser cleared its
storage. The section says: **Documents you open will appear here.**

### A count shows a dash instead of a number

The count has not loaded, or your role cannot count that doctype. The count
fills in when the data arrives.

## Related

- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — how to reach the dashboard.
- [Lists, filters and saved views](/use/finding/lists-and-views/) — what a pinned view opens.
- [Viewing and editing a document](/use/documents/view-and-edit/) — what a recent chip opens.
- [Domains and isolation](/discover/how-it-works/domains/) — why each domain has its own dashboard.
- [Draft → publish](/build/model/in-app/how-drafts-work/) — what the drafts section shows.
- [Keyboard shortcuts](/use/finding/keyboard-shortcuts/) — move without the mouse.
