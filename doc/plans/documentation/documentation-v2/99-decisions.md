# 99 — Decisions

Questions for the maintainer. Answer by writing `Decision:` under each item.
Blocking decisions must be answered before the WP they block is dispatched.
Open items from the old register (`../documentation/99-decisions.md`) that
still matter are carried over and say so.

| # | Topic | Blocks | Recommended |
|---|---|---|---|
| D1 | Tabs mechanism | WP 11 | A |
| D2 | Tab URL slugs | WP 11 | A |
| D3 | Running example scenario | WP 12 | A |
| D4 | Voice rules in `doc/documentation.md` | WP 11 | A |
| D5 | Screenshots | WP 14 | A |
| D6 | "Open source" wording | WP 13 | B |
| D7 | Backup and restore (old D1) | WP 18 batch B, one page | — |
| D8 | French during the transition | WP 11, 22 | A |
| D9 | Limits page (old D6) | WP 19, one page | A |
| D10 | Support and services links (old D8) | WP 13, one page | — |
| D11 | Upgrade and versioning policy (old D2) | WP 18 batch B | — |
| D12 | Data location and compliance (old D5) | WP 13 security page | A |

---

## D1 — Tabs mechanism

- **A (recommended):** the `starlight-sidebar-topics` plugin: five topics
  listed above the sidebar, one sidebar each. WP 11 first confirms it supports Starlight 0.42.
- **B (fallback):** no plugin. Five top-level sidebar groups, collapsed except
  the current one. Less clear, no dependency.

If A is chosen and the plugin turns out to be incompatible, WP 11 uses B and
reports it.

Decision: A (2026-11-26). WP 11 confirmed compatibility before install:
`starlight-sidebar-topics` 0.9.0 declares `@astrojs/starlight >=0.42.0` and
`astro ^7.2.10`; the site runs Starlight 0.42.10 on Astro 7.3.6.

## D2 — Tab URL slugs

- **A (recommended):** `/discover/`, `/use/`, `/build/`, `/admin/`, `/reference/`.
- **B:** `/administer/` instead of `/admin/` (matches the tab label; longer).
- **C:** other names (write them).

Decision: A (2026-11-26) — `/discover/`, `/use/`, `/build/`, `/admin/`,
`/reference/`.

## D3 — Running example scenario

`05-running-example.md` proposes **Brightwater Rentals**, a fictional
45-person event-equipment rental company, with domains `equipment`,
`clients`, `rentals`, people Nadia, Tom, Lucía, Ravi, Jo, and a warehouse
check-out app.

- **A (recommended):** use it as proposed.
- **B:** use it with changes (write them).
- **C:** another scenario. It must exercise: parent/child, references, money
  and computed totals, row scope, field tag, kanban, calendar, a hook, a
  webhook, replication across domains, an app, MCP.

Decision: A (2026-11-26) — Brightwater Rentals as proposed in
`05-running-example.md`.

## D4 — Voice rules in `doc/documentation.md`

v2 relaxes the 20-word sentence ceiling to an average of ~15 and a hard
limit of 25, makes "warmth through care" a requirement, and adds the layer
model and the jargon budget (`01-voice-and-vibe.md` §11).

- **A (recommended):** WP 11 writes these into `doc/documentation.md`
  (durable).
- **B:** keep them only in this plan while it runs.

Decision: A (2026-11-26) — WP 11 writes them into `doc/documentation.md`
(new Rule 2b, updated sentence-length rule). The rules must stand on their
own after the plan retires.

## D5 — Screenshots

The current site has none. Newcomers need to see where things are.

- **A (recommended):** yes, captured by a Playwright script from the
  Brightwater example (WP 14), regenerated when the UI changes.
- **B:** yes, captured by hand (faster now, goes stale silently).
- **C:** no screenshots; text only.

Decision: A (2026-11-26) — Playwright script from the Brightwater example
(WP 14), light theme, 1280 px, regenerated when the UI changes.

## D6 — "Open source" wording

Facet ships under BSL 1.1 with an Additional Use Grant, converting to Apache
2.0 four years after each release. The README and talks may call it open
source. Strict readers (Marc, developers) know that the OSI definition does
not cover the BSL, and a mismatch costs trust.

- **A:** say "open source" everywhere, with the licence named.
- **B (recommended):** in the docs, say "source-available under the BSL 1.1;
  each release becomes Apache 2.0 after four years", and explain the
  Additional Use Grant in plain words. Marketing pages can keep their own
  phrasing.
- **C:** other wording (write it).

Decision: B (2026-11-26) — the docs say "source-available under the BSL 1.1;
each release becomes Apache 2.0 after four years", and explain the
Additional Use Grant in plain words. Marketing pages keep their own phrasing.

## D7 — Backup and restore (carried from old D1)

- **A:** document a product-supported approach (for example a PostgreSQL read
  replica plus periodic backups, and the file store on S3) — only the parts
  that exist in the product or the shipped container setup.
- **B:** state that backup is the operator's job, and list exactly what must
  be backed up and how to test a restore.

Decision: B (2026-11-26, maintainer delegated). No product backup feature
exists in the code, so the page states that backup is the operator's job:
what to back up (PostgreSQL, the file store, config and secrets), what the
shipped container setup provides, and how to test a restore. No product
claims beyond what the code and the compose files show.

## D8 — French during the transition

- **A (recommended):** WP 11 moves French pages with their English twins;
  their text stays old until WP 22. Starlight shows French readers the old
  French text at the new URL. Acceptable while the site is in beta.
- **B:** WP 11 deletes the French pages; French readers see English with the
  "untranslated" banner until WP 22. Cleaner, but French readers lose content
  for a while.

Decision: A (2026-11-26). WP 11 moves French pages with their English twins;
the text stays old until WP 22. Topic labels carry French strings so the
sidebar reads correctly for French readers.

## D9 — Limits page (carried from old D6)

- **A (recommended):** `reference/limits.md`, one table of every hard limit
  with its source, generated where possible.
- **B:** limits only inline on each how-to page.

Decision: A (2026-11-26) — `reference/limits.md`, one table of every hard
limit with its source, generated where possible.

## D10 — Support and services links (carried from old D8)

Where should the docs send people who want help, managed hosting, or domain
design? Give the URLs and the wording you want.

- **A:** a short section at the end of `discover/licensing-and-services.md`
  plus a footer link.
- **B:** a footer link only.

Decision: A, with a scope note (2026-11-26, maintainer delegated). A short
section at the end of `discover/licensing-and-services.md`. At `8fb69df` the
repository contains no support or services URLs (checked by grep), so the
section names only what the repo proves: source and issues at
`github.com/wearefacet/facet`, the licence files, the trademark notes.
Managed-hosting and domain-design offers stay out until the maintainer
supplies wording and links — the WP 10 audit flagged those claims as
unsourceable (audit batch E).

## D11 — Upgrade and versioning policy (carried from old D2)

What do you commit to about releases: version numbers (semver?), migration
safety, how breaking changes are announced? WP 18's upgrade page states only
what you decide here plus what the code does.

Decision (2026-11-26, maintainer delegated): the upgrade page states the
current, code-backed practice and nothing more. Releases so far
(0.2.0-beta, 0.2.1, 0.2.2) follow MAJOR.MINOR.PATCH with 0.x treated as
beta; release notes live in `CHANGELOG.md`. Database migrations are
append-only, carry tested `-- DOWN` sections, and revert through
`facet migrate:down` (`doc/backend/migrations.md`). WP 18 verifies each
claim against `CHANGELOG.md` at write time and states no stronger policy.

## D12 — Data location and compliance (carried from old D5)

- **A (recommended):** the Discover security page says where data lives
  (wherever you run it: your PostgreSQL, your file store) and what the product
  does (audit, access control, MFA, SSO, retention), with no compliance or
  certification claim the product does not hold.
- **B:** add a mapping to a framework (GDPR articles, ISO 27001 controls).
  Only if the mapping exists and you will maintain it.

Decision: A (2026-11-26) — the Discover security page says where data lives
(your PostgreSQL, your file store, wherever you run Facet) and which controls
the product ships (audit, access control, MFA, SSO, retention). No compliance
or certification claim the product does not hold.
