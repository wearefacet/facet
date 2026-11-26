---
title: A day at Brightwater
description: Follow one fictional day at an equipment rental company to see how Facet's pieces work together.
type: explanation
audience: [evaluator, user]
features: []
verified_at: eee55a2
sidebar:
  order: 3
---

Brightwater Rentals is a fictional company we use in every example. It rents
out tents, staging, sound and lighting for weddings, festivals and corporate
events. Forty-five people work there, in one office and one warehouse. This
page follows four of them through one working day. Watch what each person
sees and does — every scene links to the page that explains it.

Brightwater keeps its data in three **domains** — a domain is one business
area, with its own record types, fields and rules:

| Domain | What it holds |
| --- | --- |
| `equipment` | The stock: items, categories, repair tickets |
| `clients` | The companies that rent, and their contacts |
| `rentals` | The bookings, with their lines of equipment |

| Person | Job | What they use |
| --- | --- | --- |
| Tom Aaland | Sales | Bookings and his own clients |
| Lucía Ferrer | Warehouse lead | The warehouse board and the check-out app |
| Nadia Bertrand | Operations director | Everything, including costs, and the assistant |
| Ravi Menon | Part-time IT admin | Accounts, roles, the audit trail |

## Morning: Tom books a wedding

Tom sells to wedding planners and festival organizers. A client calls: they
need six tents, a stage and the sound set for the second weekend of December.

Tom opens his clients list and finds the planner's company. He creates a
**booking** for 12 and 13 December, with one line per piece of equipment. He
sets the booking to **Confirm**. An automation rule in the `equipment` domain
then marks every item on those lines as *out* on the warehouse board, so
nobody double-books the tents.

Two rules worked quietly in the background. Tom sees only the five companies

where he is the account manager; other salespeople's clients stay invisible

to him. And the items on his lines are marked *out* for everyone now, not

only for Tom.

<!-- screenshot: discover-a-day-booking-list -->

How the three domains relate: [Domains: where your data
lives](/discover/how-it-works/domains/). Why Tom sees only his clients:
[Roles: who sees and does what](/discover/how-it-works/roles/).

## Midday: Lucía checks out the equipment

Lucía leads the warehouse. Her tools are the warehouse board in the workspace
and a small check-out app that lists today's bookings.

The check-out app is a small web app that signs in through Facet. Lucía logs
in once, with the same account she uses everywhere. The app can list bookings
and mark items out or back in — and nothing more. An app can never do more
than its user is allowed to do.

She opens an item to log a torn tent wall. She sees its category, its status
and its repair tickets. She does not see what the item cost: purchase prices
are hidden from her role. She adds a photo of the damage to the repair ticket
and mentions Tom, who needs to know before the next rental.

<!-- screenshot: discover-a-day-warehouse-board -->

Why an app stays small, and who can build one: [Apps: built fast, replaced
freely](/discover/how-it-works/apps/). Hidden fields and row rules:
[Roles: who sees and does what](/discover/how-it-works/roles/).

## Afternoon: Nadia asks the assistant

A client calls Nadia, the operations director: can Brightwater cover a
corporate event on 12 December? Nadia asks the assistant, in her own words:
*Which tents are free on 12 December?*

The assistant answers from Brightwater's own data. It acts under Nadia's
role, so it sees costs and all bookings — the same view she has. If she asks
it to change something, the change lands in the history under her name, never
under the assistant's.

<!-- screenshot: discover-a-day-assistant -->

How the assistant gets its rights: [The assistant: AI with your
rights](/discover/how-it-works/assistant/).

## Evening: Ravi closes the day

Ravi looks after accounts, roles and sign-in. He is not part of the rental
business, and Facet shows him a different picture again.

Before he leaves, he opens the audit trail. Today it recorded Tom's booking
and its **Confirm**, Lucía's check-outs and her photo on the repair ticket,
and every sign-in in between. Each entry names the person and the app behind
it. When an auditor asks next spring who changed a booking and when, the
answer is a search away.

<!-- screenshot: discover-a-day-audit -->

The model behind the trail: [Security and
governance](/discover/security/). The day-to-day how-to: [See who did
what](/admin/history/audit/).

## What this day shows

- Each business area lives in its own domain, with its own record types and
  rules.
- Roles decide what each person sees — in the workspace, in apps, and in what
  the assistant can reach.
- Apps sign in through Facet and inherit the limits of their user.
- The assistant works under your role, and its changes carry your name.
- Every change is recorded, and the history outlives any app.

The story is invented. You can load the same example data on a test instance
and walk through the day yourself — [Your first hour](/build/first-hour/)
shows how.

## Related

- [Why Facet](/discover/why-facet/) — the problems Facet takes on.
- [The big picture](/discover/how-it-works/) — the five pieces, one page each.
- [Is Facet right for you?](/discover/is-it-right-for-you/) — the honest
  limits.
- [Your first hour](/build/first-hour/) — load the Brightwater example and
  try the day yourself.
