---
type: how-to
title: Move domains with bundles
description: Export a domain as a bundle and import it on another instance, with the flags for documents, secrets, and renames.
audience: [author, operator]
features: [DOM-15]
sidebar:
  order: 4
verified_at: eee55a2
---

A bundle is a file that carries a domain's definition: the domain itself, its
doctypes, its scripts, and its shared views. You export it from one instance
and import it on another — staging to production, or a domain sold to a
customer. For the full trip and what to do about roles and people, see
[From dev to production](/build/model/dev-to-production/).

## When to use this

- You built a domain on staging and ship it to production.
- You keep domain definitions in a repository and load them on servers.
- You deliver a ready-made domain to another organisation.

## Before you start

- **A published domain.** A draft cannot be exported — the command answers
  `422`.
- **The `facet` command-line tool** on the machine, with access to its
  database.
- **A decision on documents.** Definitions move by default; data only with
  `--with-documents`.

## Steps

### 1. Export the domain

```sh
facet domain:export crm --output crm.facet-domain
```

The output is a directory tree. End the path with `.tar.gz` or `.tgz` to get
a single tarball instead. Several domains export in one run with an output
directory:

```sh
facet domain:export crm,billing --output-dir out/
```

That writes one bundle per domain — `out/crm.facet-domain`,
`out/billing.facet-domain`. `--output` refuses multiple domains; use
`--output-dir` for a batch. The bundle holds:

| Content | Always? |
| --- | --- |
| The domain document, with its hooks as script files | Yes |
| Every doctype definition, with its Lua script beside it | Yes |
| Every document view template of each doctype | Yes |
| Every shared (general) list view | Yes |
| Every document | Only with `--with-documents` |

Personal list views never move; they belong to their owners.

:::tip
Read `bundle.yml` inside the bundle. It names the source instance's Facet
release (`facet_version`), the source domain, and the export time, so you
can check the target runs the same release.
:::

### 2. Import on the target

```sh
facet domain:import crm.facet-domain
```

Without flags, the import creates the domain fresh and refuses an existing
target. Pass `--merge` to update an existing domain, or `--into newname` to
land it under another name. Both combine:

```sh
facet domain:import crm.facet-domain --into crm-prod --merge
```

The whole import runs in one transaction: a rejection leaves the target
exactly as it was. Each imported domain prints a summary line prefixed with
its name, with created, updated, and unchanged counts. One stream therefore
shows which domain broke a batch.

A batch runs domain by domain and stops at the first failure. An export
batch can leave a partial directory — delete it and re-run. An import batch
leaves the earlier domains imported; clean the targets before you retry.

### 3. Read the merge rules

`--merge` compares each bundled doctype with the live one:

| Situation | Result |
| --- | --- |
| Doctype missing on the target | Created. |
| Same structure | Left unchanged. |
| Different structure | The bundle's version must be exactly one above the live one, with the migration for the step. |
| Document view template | Matched by kind: created, updated, or deleted to match the bundle. |
| Shared list view | Matched by name: created or updated. A view that exists only on the target is never deleted. |

Two safety rules sit inside the merge. Views: the bundle deletes a target's
document views only when the bundle carries at least one view for that
doctype. A partial bundle cannot strip a doctype's views. Data: the
import checks every bundled document against the target's unique
constraints, and a collision aborts the whole import.

### 4. Accept the cross-domain tickets

If the domain reads from other domains, the import files consent tickets
with those producers. They start inactive on import; a producer
administrator activates them. The command prints one line per ticket.

### Move a bundle over HTTP

The API carries the same bundle. `POST /Api/core/Domain/:id/export` returns
a job that produces a zip; `POST /Api/core/Domain/import` accepts a zip or
tarball body with `into` and `merge` parameters. Both answer `202` with a
status URL, and the export needs read access to the domain, the import
write access. The HTTP export carries definitions only — documents stay a
command-line choice.

## Secrets

A set secret field exports as a state marker, never as a value. The import
refuses a marker whose secret does not exist on the target, so a bundle
with secrets imports only where the secrets live. To move the domain
elsewhere, export with `--omit-secrets`: every marker becomes empty, the
bundle imports, and the fields land unset. Re-enter the values on the
target.

## Example

A staging build of `crm` ships to production:

```sh
facet domain:export crm --output crm.facet-domain
tar -czf crm.facet-domain.tgz crm.facet-domain
scp crm.facet-domain.tgz ops@prod.example.com:
```

On the production host:

```sh
facet domain:import crm.facet-domain.tgz --merge
```

An updated doctype passed the version gate on staging before the export, so
production accepts it in one step.

:::caution
An export is not a backup. A bundle carries definitions, not history. Use
your database backup tools for recovery.
:::

## Troubleshooting

**The export refuses with a draft error.**

Publish the draft first. Bundles never carry drafts.

**The import answers: domain already exists.**

The target exists and you did not pass `--merge`. Add it, or rename with
`--into`.

**The import answers a version gate error.**

The bundle's doctype is behind or ahead of the live one. Bring the bundle
from a source with the matching version, or merge again after fixing the
versions on the source.

**The import answers a version error that names `$force`.**

A same-version edit removed or retyped a field. The product allows it only
with an explicit `$force: true` on the bundled definition. The flag relaxes
shape rejections only. The version must still be exactly one above the live
one, and a same-version edit that carries migrations is always refused.

**The import refuses a bundled document over a unique field.**

The target already holds a row with that value. Clean the target, or import
without the colliding documents.

**The import refuses a secret marker.**

The secret does not exist on the target. Re-enter the values there, or
export again with `--omit-secrets` and accept unset fields.

**The reader prints a file name and a line number.**

A file inside the bundle does not parse. The message names the file and the
line — fix the YAML in the bundle, or export again from the source.

**References to other domains look broken.**

A bundle does not move other domains. Import the referenced domains too;
the references resolve once their targets exist.

## Related

- [From dev to production](/build/model/dev-to-production/) — the round trip, roles and people included.
- [Change a live domain safely](/build/model/change-a-live-domain/) — the version gate the merge enforces.
- [The domain watcher](/build/model/in-files/domain-watcher/) — apply the same files automatically while you develop.
- Internals on GitHub: [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md) — the bundle format and every gate.
