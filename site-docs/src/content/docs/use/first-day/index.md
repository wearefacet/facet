---
type: tutorial
title: A tour of the workspace
description: Walk one screen from top to bottom — the sidebar, your lists, a document, search, the assistant, notifications, and your account menu.
audience: [user]
features: [FE-19, FE-02, FE-07]
sidebar:
  order: 1
next: /use/first-day/sign-in/
verified_at: eee55a2
---

You have a Facet account and the address of your organization's workspace.
This page walks the screen once, from top to bottom. Each stop gets one
screenshot, so you can compare what you see with what this page shows. After
the tour, you know where your records live and where every daily action
sits.

The examples use Brightwater Rentals, a fictional event-equipment company
that the documentation follows everywhere. Nadia manages the business, Tom
sells, and Lucía runs the warehouse.

## If a welcome tour opens

When an organization starts Facet, the very first administrator account sees
a short introduction the first time it signs in. It has seven cards: what
Facet is for, what a **domain** is, how records take shape without code, who
may read and change what, how every change stays on record, how Facet
connects to other tools, and a last card that points to the first domain.

![The welcome tour's first card, titled "A governance layer", with the Next button.](/screens/build/run-facet-2.png)

Everyday users do not see this popup. If it opens for you, it means your
account holds the administrator role. Click **Next** to read the cards, or
click **Done** to close the tour. The checkbox **Don't show again** keeps it
closed from then on. You can open it again in **My settings** under
**Welcome tour**.

## The home page

Sign in, and Facet opens the home page. It greets you by first name and
names the role you work under. Everything below answers one question: what
can I reach?

![Nadia's home page: the greeting "Hello Nadia, connected as Manager", links to key surfaces, and cards for applications, drafts and domains.](/screens/use/first-day-tour-1.png)

From top to bottom:

| Part | What you see |
| --- | --- |
| Greeting | Your first name, and the role you work under, for example *Manager*. |
| Key surfaces | Shortcuts to the areas your role allows, such as **Builder**. A link your role does not allow does not show. |
| Applications | One card per application your organization runs. The section hides when there are none. |
| Drafts in progress | Domains your team still builds, with a check mark when they are ready to publish. |
| Domains | One card per domain you may read. Select a card to open that domain's dashboard. |

A domain holds one business area — for Brightwater, *Equipment*, *Clients*
and *Rentals*. Your role decides which domains show. If your account may
read none, the page shows a **No domains available** card and asks you to
contact your administrator.

## The sidebar

The dark strip on the left stays in place on every page. It lists the
domain you currently work in and the record types inside it.

![Lucía's workspace: the sidebar shows the Equipment domain, the Item, Category and MaintenanceTicket types with record counts, and her account at the bottom.](/screens/use/first-day-tour-2.png)

From top to bottom:

- **The brand mark.** Select it to return to the home page from anywhere.
- **The domain selector.** Shows the active domain with its colour dot.
  Select it to pick another domain — the page then shows that domain's
  dashboard.
- **The record types.** Each row carries an icon, the type name, and a count
  of its records. Select a row to open its list. The pin control keeps your
  most-used types at the top.
- **Configure**, for roles that manage the workspace. Most users do not see
  this row.
- **Your account**, at the bottom — the last stop of this tour.

A small search control sits above the list. It finds record types by name in
the active domain.

## A list

Select a record type, and its list opens. A list is a table of records; the
domain's author decides the shape — a table, a board of cards, or a calendar.

![Tom's Booking list: the toolbar on top, the table of bookings, and the sidebar on the left.](/screens/use/first-day-tour-3.png)

The toolbar on top carries the daily actions: a **New** button for a new
record, search over this list, and **Export** or **Import** where your role
allows them. Select a row to preview the record without leaving the list.

Lists, filters and saved views have their own page:
[Lists, boards and calendars](/use/finding/lists-and-views/).

## A document

Select a row, and the record opens on its own page. One record is one
**document** — one booking, one item, one client.

![Tom's booking BK-2026-0001: the header with the version pill and the action buttons, the fields below, and the comments panel on the right.](/screens/use/first-day-tour-4.png)

The header carries the actions you need most:

- **Share** copies the page address to send to a colleague.
- **History** shows every recorded change to this document.
- **Edit** opens the form to change the fields. It shows only when your
  role may change this record type.
- **Actions** holds the record type's one-click steps, such as confirming a
  booking, and the **Delete** step behind a confirmation.

The page shows the fields the domain's author laid out. A record type
without a designed page shows a simple list instead: one field per line,
label and value.

## Search

The search control sits at the top right of every page. Select it, or press
`Ctrl+K` (`⌘K` on a Mac), and the **command palette** opens. It searches
records across your domains and offers jumps to pages and actions.

![The top bar with the search control highlighted.](/screens/use/first-day-tour-5.png)

The palette never offers a page your role cannot open. Type part of a name,
select the record, and its page opens. See
[Search and the command palette](/use/finding/search/).

## The assistant

The sparkles control beside the search opens the assistant, a chat window
that answers questions about your data and makes changes when you ask it to.

![The top bar with the assistant control highlighted.](/screens/use/first-day-tour-6.png)

Three facts matter on day one:

- The assistant works under **your** role. It sees what you see and changes
  what you may change — nothing more.
- Your organization decides whether the assistant is on. If your role does
  not include it, the control does not show.
- If the window says *"This project has no AI assistant configured"*, an
  administrator has not connected a language model yet.

The assistant keeps every conversation, so you can reopen yesterday's
questions. Ask it in your own words — *"Which bookings arrive next
week?"*, *"Mark booking BK-2026-0003 as returned"*.

## Notifications

The bell at the top right collects your notifications: a mention in a
comment, a finished export, an event your organization sends you.

![The top bar with the notifications bell highlighted, showing its unread badge.](/screens/use/first-day-tour-7.png)

A number on the bell counts what you have not read. Select the bell to open
the panel; select an entry to go to the record behind it. When all is read,
the panel says *"You're all caught up"*.

## The account menu

At the bottom of the sidebar sits your account: your initials, your name,
and your active role.

![The bottom of the sidebar with Lucía's account highlighted: her name and the Warehouse role.](/screens/use/first-day-tour-8.png)

Select your name to open the menu:

- **My settings** — your language, timezone, and notification preferences.
- **API keys** and **Webhooks**, when your role allows them.
- **Switch Role**, when your account holds two or more roles.
- **Logout**.

Your role decides what the menu lists. See
[Your settings and API keys](/use/account/).

## Troubleshooting

### I don't see a domain or a record type that my colleague sees

Your role decides what you reach. Facet hides what the role does not allow,
everywhere — lists, search, the assistant. Ask your administrator to check
your role. See [Roles: who sees and does what](/discover/how-it-works/roles/).

### The assistant control is missing

Your role does not include the assistant. An administrator can add it to
your role.

### The assistant says no AI assistant is configured

Your organization has not connected a language model. An administrator adds
one in **System settings**. Nothing is wrong with your account.

### A record count shows a dash instead of a number

The count has not loaded yet, or your role cannot count that record type.
The dash fills in when the data arrives. If it stays, ask your
administrator.

### The record I opened yesterday is gone from the dashboard

The **Recently viewed** chips live in your browser, so they follow the
browser you used — and a cleared browser history empties them. The record
itself is not lost: find it again through search or its list.

## Related

- [Sign in and secure your account](/use/first-day/sign-in/) — passwords,
  MFA, and sign-out.
- [The dashboard](/use/first-day/dashboard/) — the home and domain pages in
  depth.
- [Lists, boards and calendars](/use/finding/lists-and-views/) — the list
  surface and its views.
- [Open and edit a document](/use/documents/view-and-edit/) — the record
  page and the edit form.
- [Your settings and API keys](/use/account/) — what the account menu opens.
