---
type: explanation
title: Why Facet
description: See the problems Facet solves and the one idea behind it — apps are disposable, your data is not.
audience: [evaluator]
features: []
verified_at: eee55a2
sidebar:
  order: 1
---

*Apps come and go. The records, the rules, and the history stay.*

```d2
direction: down
app: "The app of the month" {class: external}
next: "The next app" {class: external}
home: "Facet" {class: accent}
records: "Your records" {class: store}
rules: "Who may see and change them" {class: store}
history: "Every change, remembered" {class: store}
app -> home
next -> home: "replaces it"
home -> records
home -> rules
home -> history
```

## The everyday problem

At Brightwater, the equipment list lives in a spreadsheet, bookings in a calendar, clients in a CRM. Each tool makes sense alone. Together they cost the company in five ways:

- **The data is scattered.** One client exists three times under three spellings. Nobody knows which copy is right.
- **Nobody can say who sees what.** The spreadsheet has no rule that says a salesperson may see only their own clients. Trust fills the gap, until it cannot.
- **The bridges break.** The booking calendar mails the warehouse a list every morning. When someone renames a sheet, the mail is wrong and nobody notices.
- **IT says no, for good reasons.** A home-made tool needs hosting, accounts, backups, and an audit trail. That is a month of work before the first useful screen, so the queue grows.
- **Prices rise with no way out.** The tools rent your own data back to you, per seat, per month, forever.

## The idea

Facet is one governed home for your business data, plus the apps that run on it. The home holds the records, the rules about who may see and change them, and the memory of every change. An app is only a face on top — a screen, a mobile tool, a chat window.

An app never touches the database and never runs inside Facet. It signs in, like a person does, and gets no more rights than it was given. Delete the app and nothing of yours is lost: the records, the rules, and the history stay. **Apps are disposable; your data is not.**

That is the whole bet. Tools wear out; your clients, your stock, and your bookings do not.

## What every app gets for free

Because the home carries the hard parts, each app stays small:

| You get | What it means |
|---|---|
| Accounts | Sign-in, passwords, MFA, single sign-on, managed in one place |
| Rights | Rules about rows and fields, checked on every read and write |
| Memory | Every change recorded: who, when, and through what; undo included |
| Hosting | Facet serves the app's screens and signs in its users |

## Three ways to build

- **Describe it.** Tell a coding agent what the team needs. It writes the app and connects to Facet's front door. The platform checks every call, exactly as it checks a person.
- **Ask the assistant.** In the workspace, the assistant drafts record kinds and screens from a sentence, and you adjust.
- **Write it by hand.** A typed SDK and a CLI cover the calls; Facet hosts the result.

## What Facet is not

- **Not a public app platform.** Accounts come from invitations; there is no self-service sign-up for your customers.
- **Not an analytics tool.** Lists and filters serve daily work, not company-wide statistics.
- **Not for heavy data loads.** Every write is checked and recorded, which costs a little per row.
- **Not for several companies at once.** One installation serves one organization.
- **Not a hosted service.** You run it on your servers, and the data stays in your PostgreSQL.

The limits page puts numbers and workarounds on each line: [Is Facet right for you?](/discover/is-it-right-for-you/).

## For the technical detail

- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — the exact checks behind "who may see and change what".
- [The change log, in detail](/admin/under-the-hood/change-log/) — how the memory is stored and for how long.
- [How domains stay isolated](/build/deeper/domain-isolation/) — the boundary, line by line.

## Related

- [The big picture](/discover/how-it-works/) — one diagram and the five ideas behind it.
- [Security and governance](/discover/security/) — the same story, told for an audit.
- [Compare](/discover/compare/) — Facet next to the tools you know.
