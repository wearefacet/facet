---
title: The dev domain watcher
description: Edit domain definition files on disk and let the dev server apply them.
audience: [author, developer]
features: [DOM-19]
sidebar:
  order: 26
verified_at: fd345fe3
---

The dev domain watcher watches a folder of domain files and applies every change to a running dev server. You edit YAML in your editor and save; the server updates the domains a moment later. No clicks in the UI, no API calls, no restarts.

## When to use this

- You develop a domain in files under version control.
- You want reviewable changes instead of editor clicks.
- You work with AI coding agents that write domain files.

## Before you start

- **A dev server you own.** The watcher never runs in production; the server refuses to start it there.
- **A folder the server can read.** Add the `dev.domain_watch` section to your dev configuration:

```yaml
dev:
  domain_watch:
    path: ./dev
    poll_ms: 500
    documents: preserve
```

| Key | Default | Meaning |
| --- | --- | --- |
| `path` | required | The folder with one subfolder per domain. |
| `poll_ms` | `500` | How often the folder is polled. |
| `documents` | `preserve` | `preserve` keeps documents you created in the app. `discard` rebuilds everything from the files on every change. |

:::caution
The config line is the consent: every sync replaces the watched domains' definitions, and in `discard` mode their documents too. Point `path` at a folder you own.
:::

## Steps

### 1. Lay out one folder per domain

Each direct subfolder of the watch path holds one domain bundle:

```
dev/
└── acme.facet-domain/
    ├── bundle.yml
    ├── domain.yml
    └── doctypes/
        └── acme.Project.yml
```

The subfolder name is free; the domain's name comes from `bundle.yml`:

```yml
format_version: 2
source_domain: acme
exported_at: "2026-11-13T09:00:00Z"
facet_version: 0.1.0
```

`domain.yml` carries the domain document — a `content` block with the label and description, and an empty `meta`. Each file in `doctypes/` is one doctype definition:

```yml
content:
  doctype: Project
  domain: acme
  schema_version: 1
  aggregate_root: true
  label: Project
  display_name: "{{ name }}"
  fields:
    name:
      type: string
      required: true
meta:
  parent_id: acme
```

### 2. Save and let the watcher work

Save any file. Within a poll cycle or two, the server applies the folder: it reads the bundle, replaces the definitions, and reports one line per domain in the server log. A bundle added while the server runs is picked up on the next poll. The watcher waits for quiet, so a save that lands as several file writes applies once.

The server runs the domain check after every sync and logs the issue count. For the full report, read the dev report route:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/dev/check-report?domain=acme"
```

A sync that fails validation logs the exact field errors, and the domain keeps its previous state until the next good save.

With `preserve`, documents you created in the app survive a sync, and bundled sample documents fill only missing rows. With `discard`, every sync rebuilds the domain from the files, which suits tests with fixed sample data.

## Example

You add a priority field to the Project doctype:

```yml
    priority:
      type: string
      title: Priority
```

You save. The log line reports the acme sync with its import counters. You open the running app, and the Project form already shows the new field. Because the mode is `preserve`, the projects you created during testing are still there.

## Troubleshooting

**Nothing happens when I save.**

The section may be missing from the config, the path may not exist, or the subfolder may lack `bundle.yml`. A subfolder without that file is ignored.

**The sync fails on every save.**

Read the logged field errors; they name the file and the field. The domain stays on its previous state, so you can fix the file with the app still running.

**The same domain appears twice.**

Two subfolders declare the same domain name. Keep one; the log names both.

## Related

- [Dev domain watcher concern doc](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md) — the full watch contract.
- [Schema evolution](/concepts/schema-evolution/) — how definitions change over time.
- [Move domains with bundles](/build/bundles/) — ship the finished folder to another instance.
