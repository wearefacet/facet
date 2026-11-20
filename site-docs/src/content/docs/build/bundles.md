---
title: Move domains with bundles
description: Export a domain as a bundle and import it on another instance.
audience: [author, operator]
features: [DOM-15]
sidebar:
  order: 21
verified_at: fd345fe3
---

A bundle is a file that carries a domain's definition: the domain itself, its doctypes, its scripts, and its shared views. You export it from one instance and import it on another — staging to production, or a domain sold to a customer.

## When to use this

- You built a domain on staging and ship it to production.
- You keep domain definitions in a repository and load them on servers.
- You deliver a ready-made domain to another organisation.

## Before you start

- **A published domain.** A draft cannot be exported.
- **The `facet` command-line tool** on the target machine, with access to its database.
- **A decision on documents.** Definitions move by default; data only with `--with-documents`.

## Steps

### 1. Export the domain

```sh
facet domain:export crm --output crm.facet-domain
```

The output is a directory tree. End the path with `.tgz` to get a single tarball instead. The bundle holds:

| Content | Always? |
| --- | --- |
| The domain document, with its hooks as script files | Yes |
| Every doctype definition, with its Lua script beside it | Yes |
| Every document view template of each doctype | Yes |
| Every shared (general) list view | Yes |
| Every document | Only with `--with-documents` |

Personal list views never move; they belong to their owners.

:::tip
Read `bundle.yml` inside the bundle. It names the source instance's Facet version, so you can check the target runs the same release.
:::

### 2. Import on the target

```sh
facet domain:import crm.facet-domain
```

Without flags, the import creates the domain fresh and refuses an existing target. Pass `--merge` to update an existing domain, or `--into newname` to land it under another name. Both combine:

```sh
facet domain:import crm.facet-domain --into crm-prod --merge
```

The whole import runs in one transaction: a rejection leaves the target exactly as it was.

### 3. Read the merge rules

`--merge` compares each bundled doctype with the live one:

| Situation | Result |
| --- | --- |
| Doctype missing on the target | Created. |
| Same structure | Left unchanged. |
| Different structure | The bundle's version must be exactly one above the live one, with the migration for the step. |
| Shared list view | Updated by name. A view that exists only on the target is never deleted. |

### 4. Accept the cross-domain tickets

If the domain reads from other domains, the import files consent tickets with those producers. They start inactive on import; a producer administrator activates them. The command prints one line per ticket.

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

The summary counts what landed, for example `[crm] Imported domain 'crm'` with `doctypes: 4 created, 1 updated, 0 unchanged`. An updated doctype passed the version gate on staging before the export, so production accepts it in one step.

:::caution
An export is not a backup. A bundle carries definitions, not history. Use your database backup tools for recovery.
:::

## Troubleshooting

**The export refuses with a draft error.**

Publish the draft first. Bundles never carry drafts.

**The import answers: domain already exists.**

The target exists and you did not pass `--merge`. Add it, or rename with `--into`.

**The import answers a version gate error.**

The bundle's doctype is behind or ahead of the live one. Bring the bundle from a source with the matching version, or merge again after fixing the versions on the source.

**References to other domains look broken.**

A bundle does not move other domains. Import the referenced domains too; the references resolve once their targets exist.

## Related

- [Portable domains concern doc](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md) — the bundle format and every gate.
- [Domains and isolation](/concepts/domains-and-isolation/) — what one bundle carries.
- [The dev domain watcher](/build/dev-domain-watcher/) — apply the same files automatically while you develop.
