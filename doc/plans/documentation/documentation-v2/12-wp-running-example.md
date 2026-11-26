# WP 12 — Build the running example

**Goal:** Brightwater Rentals (`05-running-example.md`) exists as real,
tested Facet domains with seed data, so every page can show real field names,
real screens and real outputs.

**Depends on:** WP 11; decision D3 (scenario); a running dev instance
(`./scripts/dev`, see `build/dev-environment.md` source: the old
`start/install.md`).
**Blocks:** WP 14–18 (they use the example). WP 13 and 19 can start without it.

**Write scope:**

- `site-docs/examples/brightwater/` (new), except `checkout-app/`, which WP 14 owns
- `doc/plans/documentation-v2/05-running-example.md` (update the sketch to
  match what you built)
- `doc/plans/documentation-v2/ledgers/12.md`

---

## What to build

1. **Domains as files**, in the folder layout the dev domain watcher reads
   (verify the layout in `doc/backend/dev-domain-watcher.md` and the code):
   `equipment`, `clients`, `rentals`, with the doctypes and features listed in
   `05` §3. Build them **in files mode, under the watcher**. This is also the
   first real test of the files workflow that WP 14 and WP 16 will document:
   record every friction point in your ledger.
2. **Views:** a kanban of MaintenanceTicket by state, a calendar of Booking
   by dates, a table of Items, and a document page template for Booking.
3. **Behaviour:** the named action, the lifecycle guard, the event hook, the
   computed booking total, the identifiers, the unique serial number, the
   cross-domain replicated client name, the named scope "my clients".
4. **Roles:** `manager`, `sales`, `warehouse`, `admin`, with the row scope and
   field tag of `05` §2. If roles cannot live in the domain files, write them
   as a seed script that uses the CLI or API, and document the gap in the
   ledger (it is a finding for WP 16's "From dev to production" page).
5. **Seed data:** about 40 Items in 6 categories, 10 Companies with 2–3
   Contacts each, 15 Bookings spread over the next two months, 5 open
   MaintenanceTickets. Deterministic (fixed names and dates relative to a
   fixed anchor date, documented in the README), so screenshots are stable.
6. **Exported bundles:** export each domain with `facet domain:export` and
   commit the bundles under `site-docs/examples/brightwater/bundles/`. Import
   them into a fresh instance and confirm they load: this tests the
   "From dev to production" path.
7. **A loader script** (`site-docs/examples/brightwater/load.sh` or similar)
   that takes a fresh instance to the full example: domains, roles, people
   (Nadia, Tom, Lucía, Ravi with known dev passwords), seed data. WP 14 uses
   it for screenshots; WP 21 uses it for review.
8. **README** in `site-docs/examples/brightwater/`: what it is, how to load
   it, the anchor date, the accounts.

## Rules

- Use only features that exist at `HEAD`. If a feature from `05` §3 does not
  work as expected, log a discrepancy and drop it from the example; do not
  work around product bugs.
- No real people, brands or addresses.
- Keep the example small enough that a reader can understand it in the
  Discover tour page.

## Done when

- [ ] A fresh instance plus `load.sh` gives the full example with no manual step.
- [ ] Bundles import cleanly on a second fresh instance.
- [ ] Every feature named in `05` §3 is present, or its removal is logged.
- [ ] `05-running-example.md` updated with the real doctype and field names.
- [ ] Ledger lists files-mode friction points for WP 16.
- [ ] Report per `00-contract.md` §10.
