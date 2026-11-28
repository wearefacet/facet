---
title: Collection Views
description: core.CollectionView children, parent via meta.parent_id, surface/config, general vs personal owner_id, name-based discovery, fixture-derived patterns.
tags: [ui, views, collectionview]
---

# Collection Views

A `core.CollectionView` is a saved **listing surface** (tab) for a doctype's document listing — the sibling of `DocumentView` for the *listing* page instead of the single-document page. It renders above the table on a `[domain]/[doctype]` listing page.

## Structure

`core.CollectionView` is a child of `core.DocType` (`member_of: DocType`). Unlike `DocumentView`, there is **no `parent_doctype` content field** — the parent linkage is carried by the system-managed `meta.parent_id` via the children system. Storage identity: `domain="core", doc_type="CollectionView"`.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Tab label shown in the listing UI (e.g. "All", "My Pipeline"). |
| `surface` | enum | yes | Presentation layout: `table`, `calendar`, `kanban`, or `grid`. |
| `config` | object | — | Surface-specific config. For `table` and `grid`: `{ columns: [{ key, label?, width? }] }` — grid columns may add `summary` / `editable`, plus a `grid` settings object (see the `config.grid` vocabulary below). The `calendar` and `kanban` surfaces carry their own surface-named config objects. |
| `owner_id` | reference (`iam.Account`) | — | Creator account id for personal views; null for general views. |

## General vs personal

- **General** views are shared — no `owner_id`.
- **Personal** views bind `owner_id` to the creator's account.

`owner_id` is **immutable** after create. To switch a view between general and personal, create a new view and delete the old one. The Lua create hook (`data/seeds/core.CollectionView/script.lua`) forces `owner_id` based on the matched permission's scope; the assistant runs system-tier, so it supplies `owner_id` explicitly when it wants a personal view and omits it for a general view.

## Creating views

A new doctype ships with **no views** — the check reports an `:info` notice
(`No CollectionView defined for …`) until you create at least one, and the
workspace listing shows a starter screen instead of tabs. Create one table
view per doctype so it lists its records; add kanban/calendar/grid views when
the doctype's fields serve them.

Use the `create_collection_view` tool: pass `doctype` (the qualified doctype id), `name`, `surface`, and optional `config` / `owner_id`. The tool enforces that the doctype is in the draft domain and sets `meta.parent_id` for you.

`update_collection_view` takes a `doc_id` plus optional `name`/`surface`/`config` — pass only the fields you want to change. `owner_id` cannot be changed.

`delete_collection_view` soft-deletes the view.

## Fixtures and ids

Fixture doctypes ship one or more views so their listing page has tabs. Domain bundles carry them under `views/{qualified}/collection_views/{slug}.yml` — see `data/fixtures/crm.facet-domain/views/crm.Deal/collection_views/`. Each file holds the view `content` plus `meta.parent_id` pointing at the parent doctype's id. The filename is a label only.

The backend assigns runtime ids (ULIDs) at create and import — you never choose the id. The frontend discovers views through `meta.parent_id` (the children endpoint), never by id, and builds the `?view=` URL deep link from the view's `name`. So `meta.parent_id` and a human-readable `name` are the fields that matter.

## `config.columns` vocabulary

For the `table` surface, `config` is:

```yaml
config:
  columns:
    - { key: title, label: "Deal" }
    - { key: value, label: "Value", width: "120px" }
    - { key: status, label: "Status", width: "110px" }
```

- `key` — a doctype field name.
- `label` — optional column header; defaults to the field's title.
- `width` — optional CSS width.

When `config.columns` is absent, the frontend falls back to the doctype's first eight flat fields, so a view can omit `config` entirely for a default listing.

## `config.grid` vocabulary

The `grid` surface (spreadsheet-style editing) reuses the table's `config.columns` plus two
column keys and a `grid` settings object:

```yaml
config:
  columns:
    - { key: title, width: "300px" }
    - { key: value, width: "160px", summary: sum }
    - { key: won, width: "96px", editable: false }
  grid:
    frozen: 1 # leading columns pinned left
    filters: { status__ne: lost } # view-level base filter, as on kanban
    sort: ["-value"] # one entry; default ["-updated_at"]
    allow_create: true # ghost new-row line; absent = off
```

- `summary` — `count`, `sum`, `avg`, `min`, or `max` on a column. `count` works on any
  column; the others need an `integer`, `duration`, or `money` field.
- `editable` — only the `false` opt-out persists; a writable column edits by default.
  `editable: true` on a field the cell editors do not cover (containers, `data`, `file`,
  `secret`, `any`, `read_only`) fails the gate.
- `frozen` — integer from 0 to the column count.
- `filters` — keys must serve their operators, the kanban rule.
- `sort` — one entry, `-` prefixed for descending; the field must be sortable.

## How views attach to doctypes

The `parent_id` meta field on the CollectionView projection points at the parent doctype's id. Cascade delete applies: deleting a doctype also deletes its CollectionView children. On publish, views are copied with the doctype and their `parent_id` is rewritten to the target domain.