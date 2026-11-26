---
type: how-to
title: The domain watcher
description: Edit domain definition files on disk and let the domain watcher apply every save.
audience: [developer]
features: [DOM-19]
sidebar:
  order: 0
verified_at: eee55a2
---

The dev domain watcher watches a folder of domain files and applies every
change to a running dev server. You edit YAML in your editor and save; the
server updates the domains a moment later. No clicks in the UI, no API
calls, no restarts.

## When to use this

- You develop a domain in files under version control.
- You want reviewable changes instead of editor clicks.
- You work with AI coding agents that write domain files.

## Before you start

- **A dev server you own.** Set one up with [the dev environment](/build/dev-environment/) how-to. The watcher never runs in production; the boot
  code refuses to start it there, even when the config section is present.
- **A folder the server can read.** Add the `dev.domain_watch` section to
  your dev configuration:

```yaml
dev:
  domain_watch:
    path: ./dev
    poll_ms: 500
    documents: preserve
```

| Key | Default | Meaning |
| --- | --- | --- |
| `path` | required | The folder with one subfolder per domain. A missing path fails at boot. |
| `poll_ms` | `500` | How often the folder is polled. The lower bound is `100`. |
| `documents` | `preserve` | `preserve` keeps documents you created in the app. `discard` rebuilds everything from the files on every change. |

:::caution
The config line is the consent: every sync replaces the watched domains'
definitions, and in `discard` mode their documents too. Point `path` at a
folder you own.
:::

## The two documents modes

| | `preserve` (default) | `discard` |
| --- | --- | --- |
| What a sync replaces | The definitions only | The definitions and every document |
| What survives | Documents you created in the app, your saved list views, uploaded files | Nothing; every cycle rebuilds from the files |
| Bundled sample documents | Fill only missing rows | Replay fresh on every cycle |
| A doctype that left the bundle | Its documents are tombstoned | Its documents are tombstoned |

`discard` suits tests with fixed sample data: save, and the domain is
exactly what the files say. `preserve` suits daily work: your app-created
records stay. In both modes, a doctype that leaves the bundle takes its
documents with it — otherwise the replay would re-create rows from a stale
`documents/` tree.

## Steps

### 1. Lay out one folder per domain

Each direct subfolder of the watch path holds one domain bundle. The layout
is the same format an export writes — see [The domain file
layout](/build/model/in-files/domain-files/) for every file.

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
facet_version: 0.2.2
```

### 2. Save and let the watcher work

Save any file. Within a poll cycle or two, the server applies the folder: it
reads the bundle, replaces the definitions, and reports one line per domain
in the server log:

```text
[dev-sync] synced 'acme' from 'dev/acme.facet-domain': 1 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

A bundle added while the server runs is picked up on the next poll. The
watcher waits for quiet, so a save that lands as several file writes applies
once. A save that changes nothing (same file contents) does nothing — change
detection is content-based, not clock-based.

### 3. Read the diagnostics

After every sync, the watcher runs the same check service the Builder uses.
A clean domain logs nothing. A domain with issues logs one line, and the
full report is one endpoint away:

```text
[dev-sync] check for 'acme': 2 issue(s) — first: Reference field 'customer' … — full report: GET /Api/dev/check-report?domain=acme
```

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "http://127.0.0.1:3000/Api/dev/check-report?domain=acme"
```

The route exists only on a dev server; in production it answers `404`. See
[Check before you publish](/build/model/in-app/check-before-publish/) for
the report's shape.

In `preserve` mode, every doctype whose fields changed while it still holds
documents logs a structure warning, and the watcher re-projects the kept
rows so their labels and search text match the new definitions. A composition
edit or an actions-only edit stays silent.

## When a file is broken

A file that does not parse, or a definition that fails validation, never
takes the domain down. The teardown and the import of one sync share one
transaction, so a failed import rolls both back: the domain keeps its
previous state, and the log names the file and the field:

```text
[dev-sync] import for 'acme' (dev/acme.facet-domain) failed: 422 acme.Widget: schema validation failed — keeping previous state
  details:
    - field: fields.name
      message: must be a lowercase snake_case identifier
```

Fix the file and save again. Sibling domains are unaffected — fault
isolation is per bundle. A bundle directory you remove warns once and keeps
the domain's last synced state; nothing here deletes a live domain.

## Example

You add a priority field to the Project doctype:

```yml
    priority:
      type: string
      title: Priority
```

You save. The log line reports the acme sync with its import counters. You
open the running app, and the Project form already shows the new field.
Because the mode is `preserve`, the projects you created during testing are
still there.

## Troubleshooting

**Nothing happens when I save.**

The section may be missing from the config, the path may not exist, or the
subfolder may lack `bundle.yml`. A subfolder without that file is ignored.

**The sync fails on every save.**

Read the logged field errors; they name the file and the field. The domain
stays on its previous state, so you can fix the file with the app still
running.

**The same domain appears twice.**

Two subfolders declare the same domain name in `bundle.yml`. Keep one; the
log names both directories every cycle.

**A restart warns about replacing a domain.**

The first teardown of a domain this watcher process did not create warns
distinctly — after a restart, that includes every domain. It is a safety
net for pointing `path` at the wrong folder, not a fault.

## Related

- [The domain file layout](/build/model/in-files/domain-files/) — every file the watcher reads.
- [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/) — the agent loop on top of the watcher.
- [Check before you publish](/build/model/in-app/check-before-publish/) — the check report, in full.
- [Move domains with bundles](/build/model/bundles/) — ship the finished folder to another instance.
- Internals on GitHub: [dev-domain-watcher.md](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md).
- [Choose how you build](/build/model/)
