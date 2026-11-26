---
type: how-to
title: From dev to production
description: Build a domain in files on dev, ship it as a bundle, and let authors adjust it on staging and production.
audience: [author, developer]
features: [DOM-15, DOM-02, DOM-19]
sidebar:
  order: 3
verified_at: eee55a2
---

Brightwater Rentals runs three domains: `equipment`, `clients`, `rentals`.
Sam models them as files on a dev server, and the watcher applies every
save. The same three domains must run on the staging instance the authors
use, and later on production. The bridge is the **bundle**: one export
command, one import command, and a clear rule for who owns the domain after
it lands.

## The round trip

<!-- d2
direction: down
files: "Domain files on dev" {class: external}
export: "facet domain:export" {class: decision}
bundle: "Bundle: definitions, optional data" {class: store}
import: "Import on staging"
draft: "Authors adjust in a draft, publish" {class: ok}
reexport: "Export changed domains again" {class: decision}
prod: "Import on production" {class: ok}

files -> export
export -> bundle
bundle -> import
import -> draft
draft -> reexport: "publish changed the structure"
reexport -> bundle
bundle -> prod: "when staging is right"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/1d738be7-light.svg" alt="Domain files on dev" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/1d738be7-dark.svg" alt="Domain files on dev" loading="lazy" />
</div>

Files on dev are the origin. Export writes a bundle — a directory or a
tarball that carries the domain's definitions. Import creates or updates the
domain on the target. There the authors work as they always do: a draft, a
check, a publish. When their changes matter to dev, export the domain again
and commit the new files.

## Before you start

- **A dev server with the watcher on** — see [The domain
  watcher](/build/model/in-files/domain-watcher/).
- **The `facet` command-line tool** on every machine in the path, with
  access to that machine's database.
- **A named target.** Decide the domain names before you export; a bundle
  carries one domain under one name.

## Steps

### 1. Build in files on dev

Model the domain as files, as [The domain file
layout](/build/model/in-files/domain-files/) describes. The watcher syncs
each save and the check report names what to fix. Commit the files as you
go — version control is the safety net in this mode.

### 2. Export the bundle

```sh
facet domain:export equipment --output bundles/equipment.facet-domain.tar.gz
```

Three domains go in one command each, or as a batch:

```sh
facet domain:export equipment,clients,rentals --output-dir bundles/
```

The export carries definitions only, unless you pass `--with-documents`.
Seed data is a choice. Brightwater ships definitions in the tarballs and
builds its demo data with a script, because the script stays readable and
re-runs. See [Move domains with bundles](/build/model/bundles/) for every
flag.

:::caution
Keep exports out of the watcher's watch root. A `.facet-domain` directory
inside the watch root syncs as a bundle; a `.tar.gz` file is invisible to
the watcher. Brightwater writes its tarballs into `bundles/` next to the
domain folders for exactly this reason.
:::

### 3. Create the roles and accounts on the target

Roles, accounts, and personal views never travel in a bundle. A bundle
carries one domain; roles live in the separate `iam` domain. On the target:

- Create each role through the API — the Brightwater `load.sh` script does
  this in a re-runnable way.
- Create accounts with `facet accounts:create`. The command prints a
  one-time password; the first sign-in asks for a new one.
- Assign roles to accounts with `facet roles:add`.

Bundle imports also file **grant tickets** for the domain's cross-domain
edges. They start inactive; an administrator of the producer domain
activates each one. Brightwater's `load.sh` widens and activates its grants
so the demo data flows.

### 4. Import on the target

```sh
facet domain:import bundles/equipment.facet-domain.tar.gz,bundles/clients.facet-domain.tar.gz,bundles/rentals.facet-domain.tar.gz --merge
```

`--merge` updates a domain that exists and creates one that does not.
Without it, an existing target answers `409`. The whole import runs in one
transaction: a rejected bundle leaves the target exactly as it was. To land
a domain under a different name, pass `--into newname`.

If the bundle carried documents, the import skips a row whose id already
exists — re-running is safe. It never updates an existing row; refresh data
by loading it again on a clean target.

### 5. Let the authors adjust on the target

From here the target's authors own the domain. They open a draft, change
what the local team needs, run **Check**, and publish — the flow in
[Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/).
The import gate protects them. A merged doctype must arrive at exactly one
schema version above the live one, with a migration function for the step.

### 6. Bring the changes back to dev

Nothing syncs from staging back to your files. After a publish changes the
structure on the target, export that domain again and commit the files:

```sh
facet domain:export rentals --output bundles/rentals.facet-domain.tar.gz
```

The next section makes this rule precise.

## What a bundle carries

| Content | Travels? |
| --- | --- |
| The domain document, with its hooks as script files | Always |
| Every doctype definition, with its Lua script | Always |
| Every document view template of each doctype | Always |
| Every shared (general) list view | Always |
| Documents of the domain's doctypes | Only with `--with-documents` |
| Personal list views | Never — they belong to their owners |
| Roles, accounts | Never — create them on the target |
| Cross-domain consents (grants) | As inactive tickets for the producer to accept |
| Secret values | Only with the export; `--omit-secrets` empties them |

The `bundle.yml` inside the bundle names the source instance's Facet
release, so you can check the target runs the same one.

## One domain, two places

The same domain can receive edits from both sides, and no product guard
stops it. The two sides behave differently:

- **On dev, the watcher wins.** Its next sync re-applies the folder to the
  running server, so a change made in a draft there disappears on the next
  save. With `documents: discard` even the data resets to the bundles.
- **On staging or production, no watcher runs.** A draft publish changes
  the domain, and your files never hear about it.

The working rule that keeps the two sides honest: **the files are the source
of truth.** After any change made in a draft on a target, export that domain
again and commit the files. Before you export, check `git status` — an
uncommitted folder plus an export in flight is how drift starts.

## When the imported schema differs from live documents

A merge can change a doctype that already holds documents on the target.
The definitions land at once; the documents catch up on their own schedule:
each one migrates the next time a read touches it. Labels and search text
need a re-projection run after a template change. Both topics have their own
pages: [Change a live domain safely](/build/model/change-a-live-domain/) and
[How old documents follow a new schema](/build/deeper/schema-evolution/).

## Example

The full Brightwater trip, from a clean instance:

```sh
# on the target instance
facet domain:import bundles/equipment.facet-domain.tar.gz,bundles/clients.facet-domain.tar.gz,bundles/rentals.facet-domain.tar.gz --merge
./load.sh   # roles, people, grants, and the deterministic demo data
```

The import prints one summary line per domain, with created, updated, and
unchanged counts. `load.sh` is safe to re-run: every step looks its target
up first. Roles and people are not duplicated, and the seed script creates
no duplicate rows.

## Troubleshooting

**The import answers: `Domain … already exists; pass --merge to overwrite.`**

The target exists. Add `--merge`, or rename with `--into newname`.

**The import answers a version gate error.**

The bundle's doctype is not exactly one schema version above the live one.
Bring the bundle from a source that carries the matching version, or fix the
version and migration on the source and export again.

**References to other domains look broken.**

A bundle does not move other domains. Import the referenced domains too;
the references resolve once their targets exist.

**The demo data is missing on the target.**

Definitions travel by default; documents need `--with-documents` at export
time. Re-export with the flag, or load the data with a script, as
Brightwater's `load.sh` does.

**People cannot see anything after the import.**

Roles and grants never travel. Create the roles, and activate the grant
tickets the import filed — an inactive ticket blocks every cross-domain
flow it covers.

## Related

- [Move domains with bundles](/build/model/bundles/) — the export and import commands, flag by flag.
- [The domain file layout](/build/model/in-files/domain-files/) — the files the round trip starts from.
- [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/) — what authors do with the domain after it lands.
- [Change a live domain safely](/build/model/change-a-live-domain/) — what a schema change costs on live data.
- Internals on GitHub: [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md).
- [Choose how you build](/build/model/)
