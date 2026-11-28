---
type: reference
title: The domain file layout
description: The files the watcher reads, one by one — the same format a bundle export writes.
audience: [developer]
features: [DOM-19, DOM-15]
sidebar:
  order: 1
verified_at: eee55a2
---

A domain in files is one directory tree. The watcher reads it, a bundle
export writes it, and a bundle import consumes it — one format, three uses.
This page lists every file the format carries, with a complete example from
the Brightwater Rentals running example.

## The tree

```
{domain}.facet-domain/
├── bundle.yml                       # identity: format version, source domain, timestamps
├── domain.yml                       # the domain document: label, description, colour, hooks
├── hooks/
│   └── {i}-{hook_id}.lua            # one script file per domain hook
├── doctypes/
│   ├── {domain}.{Doctype}.yml       # one file per doctype definition
│   └── {domain}.{Doctype}.lua       # the doctype's lifecycle script, beside its definition
├── views/
│   └── {domain}.{Doctype}/
│       ├── document_views/
│       │   └── {kind}.yml           # view, form, quickView, inline, card
│       └── collection_views/
│           └── {slug}.yml           # shared list views
└── documents/                       # only when exported with --with-documents
    └── {domain}.{Doctype}/
        └── {doc_id}.yml             # one file per document
```

The watcher reads exactly this tree. `facet domain:export` writes exactly
this tree — as a directory, a `.zip`, or a `.tar.gz`. That is the key to the
round trip: build in files, export what you built, import it elsewhere.

## Every file, in order

### `bundle.yml`

Four fixed fields. The `source_domain` is the identity — the watcher and the
import both target that domain name.

```yml
format_version: 2
source_domain: equipment
exported_at: "2026-11-26T12:00:00Z"
facet_version: 0.2.2
```

| Field | Meaning |
| --- | --- |
| `format_version` | The layout version. Current: `2`. The reader still loads version `1` bundles. |
| `source_domain` | The domain name on the exporting instance — the import target. |
| `exported_at` | RFC-3339 UTC timestamp of the export. |
| `facet_version` | The Facet release that produced the bundle. Compare it with the target's release. |

### `domain.yml`

The domain document: a `content` block and a `meta` block. The label,
description and colour are what the interface shows. Domain hooks ride here
too, with their Lua externalized into `hooks/`.

```yml
content:
  color: "#0F766E"
  description: Rental equipment — items, categories, and maintenance tickets.
meta: {}
```

### `doctypes/{domain}.{Doctype}.yml`

One doctype definition per file, named by the qualified id. This is the
complete `Category` doctype of the Brightwater `equipment` domain — a small
but real definition:

```yml
content:
  icon: tags
  color: "#0d9488"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      unique: true
      filters:
        - equality
        - text_search
      description: "Category name, e.g. 'Tents', 'Sound', 'Lighting'."
  doctype: Category
  description: "A family of rental equipment."
  display_name: "{{ name }}"
  search: "{{ name }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

| Key | Meaning |
| --- | --- |
| `domain` / `doctype` | The identity. The qualified id `{domain}.{doctype}` is also the file name. |
| `schema_version` | Starts at `1`. In files mode you may rewrite it freely — the watcher applies the definition as it is. |
| `fields` | The field map. Every `reference` target is the qualified `domain.Doctype` form. |
| `display_name` / `search` | Jinja2 templates for the label and the search corpus. |
| `aggregate_root` | `true` for a standalone doctype; a child declares `member_of` instead. |
| `meta.parent_id` | The domain the doctype belongs to. |

A doctype that declares `actions`, computed fields, or lifecycle scripts
carries its Lua beside the definition, referenced with a `!read_file` tag:

```yml
  script: !read_file equipment.Item.lua
  actions:
    send_to_repair:
      args: {}
```

The reader expands `!read_file` to the file's contents on import, so the
round trip is lossless.

### `views/{domain}.{Doctype}/document_views/{kind}.yml`

One file per page kind of a doctype: `view` (the show page), `form` (the
create/edit form), `quickView` (the peek drawer), `inline` (rows inside a
parent page), `card`. The template tree binds input nodes to field names.

### `views/{domain}.{Doctype}/collection_views/{slug}.yml`

One file per shared list view: a table, kanban, or calendar configuration.
The file name is opaque to the import — an export writes a generated slug,
and a hand-written name works the same.

### `documents/{domain}.{Doctype}/{doc_id}.yml`

Present only when the bundle was exported with `--with-documents`. One file
per document, with its content and meta. The import replays them idempotently:
a row that already exists is skipped. The watcher reseeds them on every save
in `discard` mode, and fills only missing rows in `preserve` mode.

## What does not live here

A bundle carries definitions, not the instance around them:

- **Roles and accounts.** They belong to the `iam` domain and do not travel
  in domain files. Create them on the target instance through the API or the
  CLI — see [From dev to production](/build/model/dev-to-production/).
- **Grants.** Cross-domain grants are consent documents under the producer
  domain. An import files *tickets* for the edges it finds; the producer
  accepts them there.
- **Personal list views.** A list view you saved for yourself is user data.
- **History.** The change log of a domain stays on its instance.

## Start from an export, not from memory

The fastest way to start a files-mode domain is to build the first doctype
in the app and export it:

```sh
facet domain:export equipment --output equipment.facet-domain
```

Edit the exported tree, point the watcher at the parent folder, and keep
going in files. Every structural detail — the `meta` blocks, the
`!read_file` tags, the view shapes — is already right.

## Related

- [The domain watcher](/build/model/in-files/domain-watcher/) — apply this folder to a dev server.
- [Move domains with bundles](/build/model/bundles/) — the export and import commands.
- [From dev to production](/build/model/dev-to-production/) — what travels and what does not.
- Internals on GitHub: [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md).
