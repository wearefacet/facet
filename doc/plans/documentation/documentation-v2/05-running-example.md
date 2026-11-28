# 05 — The running example: Brightwater Rentals

Every example on the site uses one fictional company. A reader who follows
two pages sees the same domains, the same people and the same data, so each
page builds on the last instead of starting from zero. This is the single
biggest help for onboarding: the reader learns Facet, not a new toy example
on every page.

The company name and scenario are decision D3 in `99-decisions.md`. The
example is built: the three domains live in `site-docs/examples/brightwater/`
with a loader (`load.sh`), a deterministic data script (`seed.py`), and export
bundles (`bundles/`). That directory is the source of truth for names; this
document describes what is in it.

---

## 1. The company

**Brightwater Rentals** rents and maintains event equipment — tents, staging,
sound and lighting — for weddings, festivals and corporate events. Forty-five
people, one warehouse, one office. Before Facet, they ran on a spreadsheet of
equipment, a separate booking calendar, a CRM, and a lot of email.

Always present it as fictional: the Discover tour page says so in its first
line ("Brightwater Rentals is a fictional company we use in every example").

## 2. The people (and their roles)

| Person | Job | Facet role | Email / dev password | Uses |
|---|---|---|---|---|
| **Nadia Bertrand** | Operations director | `manager` | `nadia@brightwater.example` / `brightwater-nadia` | Everything; approves bookings; sees costs |
| **Tom Aaland** | Salesperson | `sales` | `tom@brightwater.example` / `brightwater-tom` | Clients and bookings — **only his own clients** (row scope) |
| **Lucía Ferrer** | Warehouse lead | `warehouse` | `lucia@brightwater.example` / `brightwater-lucia` | Equipment and maintenance — **cannot see purchase prices** (field tag) |
| **Ravi Menon** | Part-time IT and admin | `admin` | `ravi@brightwater.example` / `brightwater-ravi` | Accounts, roles, SSO, audit |
| **Jo** | Freelance developer | `developer` app access | — | Builds the check-out app |

Passwords are dev-only, created by `load.sh` (the bundle README lists them
too). Jo has no account in the bundle yet; the app pages (WP 17, WP 19) add
one when they need it.

Use these names consistently. Do not add new people unless a page needs one;
if it does, add them here first (in your report as a request).

## 3. The domains

The bundles in `site-docs/examples/brightwater/` are the source of truth;
`load.sh` + `seed.py` take a fresh instance to the full example. The data is
deterministic: fixed names, prices and dates around the anchor date
**2026-12-07** (a Monday), so screenshots stay stable. 6 categories, 40 items,
10 companies, 14 contacts, 15 bookings, 5 maintenance tickets.

| Domain | Doctypes (as built) | Shows off |
|---|---|---|
| `equipment` | **Item** (name, category ref, status `available` / `out` / `in_repair`, `purchase_price` money field tagged `finance`, unique `serial_number`, identifier `EQ-{year}-####`), **Category**, **MaintenanceTicket** (item, problem, status, assignee, reported_by) | Field types, identifiers (`EQ-2026-0001`), unique serial numbers, a kanban board of tickets by status, the `finance` field tag on purchase price, the named action **Send to repair**, and the `booking-drives-stock` event hook — a confirmed booking marks its items out, a returned booking brings them back; the hook refuses items in repair and keeps the rest of the booking moving |
| `clients` | **Company** (name, city, `account_manager` → iam.Account), **Contact** (child of Company: full_name, email, role) | Parent/child composition, references, the `my_clients` named scope (`account_manager = $self`), row scope for `sales` |
| `rentals` | **Booking** (client ref, `dates` dateperiod, status `draft` / `confirmed` / `returned`, notes, replicated `client_name`, computed `total`), **BookingLine** (child: item ref → equipment.Item, quantity, `price` money) | Money and the computed booking total, a calendar view, the **confirm** / **mark_returned** named actions (their events drive the hook), cross-domain replication (client name copied onto the booking) |

Two access rules the bundles prove on a real instance:

- **Row scope**: Tom's `sales` role reads `clients.Company` only through the
  `$my_clients` scope — he sees his five companies, nobody else's. Bookings
  stay readable to him (a named scope filters on the doctype's own fields,
  and a booking's manager lives on its client — not expressible today).
- **Field tag**: `purchase_price` carries the `finance` tag; only the
  `manager` role lists that tag in `visible_tags`. Lucía and Tom read items
  but never see what they cost.

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

- Load it once per working session: start the dev stack, run
  `site-docs/examples/brightwater/load.sh` (the bundle README has the two
  load paths). Sign in as the person the page is about.
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
