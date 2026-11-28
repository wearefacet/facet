# Brightwater Rentals — the Facet example

Brightwater is a fictional event-equipment rental company near Lyon: tents,
staging, sound, lighting. Six people rent out the stock. This directory holds
the complete running example used across the Facet documentation: three domain
bundles, the roles and people, and a deterministic data set.

## What is in here

| Path | What it is |
| ---- | ---------- |
| `equipment.facet-domain/` | Categories, Items (stock), MaintenanceTickets, and the `booking-drives-stock` hook |
| `clients.facet-domain/` | Companies and their Contacts, with the `my_clients` named scope |
| `rentals.facet-domain/` | Bookings and their BookingLines, with the `confirm` / `mark_returned` actions |
| `bundles/` | The three domains as `.tar.gz` bundles (definitions only) |
| `load.sh` | Creates roles, people, grants, and the demo data on a running instance |
| `seed.py` | Creates the demo data (called by `load.sh`; idempotent on its own) |
| `export.sh` | Rebuilds `bundles/` from a live instance after you edit a domain |

## Load it

Prerequisite: a running Facet instance with the admin account
(`admin@example.tld` / `admin` on a dev instance). Two ways:

**Development instance** — the domain watcher watches this directory, so the
three domains sync themselves. Then:

```sh
./load.sh
```

**Fresh instance** — import the bundles first, then load:

```sh
facet domain:import bundles/equipment.facet-domain.tar.gz,bundles/clients.facet-domain.tar.gz,bundles/rentals.facet-domain.tar.gz --merge
./load.sh
```

`load.sh` is safe to re-run: every step looks its target up first.

## People

| Person | Email | Role | Password (dev only) |
| ------ | ----- | ---- | ------------------- |
| Nadia Bertrand | `nadia@brightwater.example` | `manager` | `brightwater-nadia` |
| Tom Aaland | `tom@brightwater.example` | `sales` | `brightwater-tom` |
| Lucía Ferrer | `lucia@brightwater.example` | `warehouse` | `brightwater-lucia` |
| Ravi Menon | `ravi@brightwater.example` | `admin` | `brightwater-ravi` |

The roles show the two access rules the documentation teaches:

- **Row scope** — Tom (`sales`) sees only the companies where he is the
  account manager, through the `my_clients` named scope.
- **Field tag** — Lucía (`warehouse`) sees equipment but not
  `purchase_price`, which carries the `finance` tag; only Nadia's `manager`
  role has that tag visible.

## The data

`seed.py` builds a deterministic corpus: 6 categories, 40 items, 10
companies, 14 contacts, 15 bookings, 5 maintenance tickets. All dates sit
around the fixed **anchor date 2026-12-07** (a Monday), so the calendar and
the kanban board always look the same and screenshots stay stable.

The bookings are not written in their final state: every booking starts as a
draft, and the script confirms or returns it through the named actions. The
`booking-drives-stock` hook in the equipment domain does the rest — a
confirmed booking marks its items out, a returned booking brings them back.
Load the example and the warehouse board matches the bookings, driven by the
hook, not by the seed script.

## Try it

1. Sign in as **Tom**: the clients table shows only his five companies.
2. Sign in as **Lucía**: open an item — no purchase price on the page.
3. Sign in as **Nadia** and **confirm** a draft booking: the items on its
   lines flip to *out* on the warehouse board.
4. Put one of those items **in repair** first; the hook collects the error
   for that item and the rest of the booking still goes out.
