# 05 — The running example: Brightwater Rentals

Every example on the site uses one fictional company. A reader who follows
two pages sees the same domains, the same people and the same data, so each
page builds on the last instead of starting from zero. This is the single
biggest help for onboarding: the reader learns Facet, not a new toy example
on every page.

The company name and scenario are decision D3 in `99-decisions.md`. This file
is the proposal; if the maintainer picks another scenario, replace the names
here and keep the structure.

---

## 1. The company

**Brightwater Rentals** rents and maintains event equipment — tents, staging,
sound and lighting — for weddings, festivals and corporate events. Forty-five
people, one warehouse, one office. Before Facet, they ran on a spreadsheet of
equipment, a separate booking calendar, a CRM, and a lot of email.

Always present it as fictional: the Discover tour page says so in its first
line ("Brightwater Rentals is a fictional company we use in every example").

## 2. The people (and their roles)

| Person | Job | Facet role | Uses |
|---|---|---|---|
| **Nadia** | Operations director | `manager` | Everything; approves bookings; sees costs |
| **Tom** | Salesperson | `sales` | Clients and bookings — **only his own clients** (row scope) |
| **Lucía** | Warehouse lead | `warehouse` | Equipment and maintenance — **cannot see purchase prices** (field tag) |
| **Ravi** | Part-time IT and admin | `admin` | Accounts, roles, SSO, audit |
| **Jo** | Freelance developer | `developer` app access | Builds the check-out app |

Use these names consistently. Do not add new people unless a page needs one;
if it does, add them here first (in your report as a request).

## 3. The domains

The detailed field list is built and tested in WP 12 and lives as a bundle in
`site-docs/examples/brightwater/`. Pages must use the field names from that
bundle, not from this sketch.

| Domain | Doctypes (sketch) | Shows off |
|---|---|---|
| `equipment` | **Item** (name, category, status: available / out / in repair, purchase price, serial number), **Category**, **MaintenanceTicket** (item, problem, state, assignee) | Field types, identifiers (`EQ-0001`), unique serial numbers, a kanban board of tickets by state, field tag on purchase price, named action "Send to repair", lifecycle guard ("an item in repair cannot be booked") |
| `clients` | **Company**, **Contact** (child of Company), with `account_manager` | Parent/child, references and backlinks, named scope "my clients", row scope for `sales` |
| `rentals` | **Booking** (client, dates, state: draft / confirmed / returned), **BookingLine** (child: item, quantity, price) | Money and computed totals, a calendar view, an event hook (confirmed booking → items marked *out*), a webhook to the accounting system, cross-domain replication (client name copied onto the booking) |

Other features attach to this story:

- **Comments and attachments** on MaintenanceTicket (photos of damage).
- **Notifications and mentions**: Lucía mentions Tom on a ticket.
- **History and rollback**: Tom changes a booking date by mistake and undoes it.
- **Import**: the old equipment spreadsheet becomes Items.
- **The assistant**: "Which tents are free on 14 June?", and in the Builder,
  "Add a MaintenanceTicket doctype linked to Item".
- **The app**: the **check-out app** for the warehouse, a small web app that
  lists today's bookings and marks items out and back in. Built with an AI
  coding agent, deployed on Facet, signed in through Facet.
- **MCP**: Nadia asks Claude Desktop about this week's bookings, under the
  `manager` role.
- **SSO, MFA, API keys, retention, audit**: Ravi's pages.

## 4. Rules for using the example

- Use it wherever it fits. Do not force it into operator pages about TLS or
  metrics; use `example.com`-style placeholders there.
- Field names, IDs, labels and outputs come from the real bundle on a real
  instance (WP 12). Never invent output.
- Keep the data realistic and dull. No jokes in names (`Test McTestface`), no
  real brands, no real people.
- Money uses one currency per example (EUR); dates use ISO format in code and
  the UI's format in screenshots.
- Each page uses the smallest slice it needs. A page about unique
  constraints shows the Item serial number, not the whole domain.
