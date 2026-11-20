---
title: Iteration Workflow
description: The create → check → update → re-check loop, how to read error details, when to use $force (never in draft — it's implicit).
tags: [workflow, iteration]
---

# Iteration Workflow

The domain builder is a tight create → check → update → re-check loop. Follow these steps religiously.

## Loop

1. **Inspect reference patterns** — call `list_domains`, `list_doctypes`, `get_doctype` to see how existing live doctypes are shaped.
2. **Design the first doctype** — read the relevant skills if unsure (e.g. `field-types`, `named-scopes`).
3. **`create_doctype`** — submit the full definition. The `definition.domain` field must match the draft domain.
4. **`check_doctype` immediately** — never assume the create was clean. Check returns:
   ```json
   {"ok": true, "data": {"doctype_id": "hr.Employee", "issues": [
     {"severity":"warning","category":"reference","field":"person","message":"..."}
   ]}}
   ```
5. **If issues are returned** — read the relevant skill (category → skill), fix with `update_doctype`, re-check.
6. **When there are no issues** — add document view templates if the user wants UI surfaces. Follow the fixture convention: one `view` + one `quickView` + one `form` + one `inline` + one `card` per doctype, each with its `kind` set (the frontend matches templates by `kind`, not by id). See read_skill("document-views"). Then run `check_doctype` once more to confirm the view templates pass validation and no standard kind is missing.
7. **Add collection views** (listing tabs) when the user wants a saved listing surface — `core.CollectionView` children with `surface: table` and a `config.columns` array. See read_skill("collection-views") and the "Collection views" section below.
8. **Smoke-test** — `create_document` with realistic content, then `get_document` to confirm acceptance. Fix validation errors via `update_doctype`.
9. **Summarize** — describe the doctypes, fields, and views you created for the user.

## Collection views

A `core.CollectionView` is a saved listing surface (tab) for a doctype's document listing — the sibling of `DocumentView` for the *listing* page instead of the single-document page. Storage: `domain="core", doc_type="CollectionView"`, child of `core.DocType` (link via `meta.parent_id`; there is no `parent_doctype` content field).

| Field | Type | Description |
|---|---|---|
| `name` | string | Tab label (e.g. "All Deals", "Open"). |
| `surface` | enum | `table`, `calendar`, or `kanban`. |
| `config` | object | `{columns: [{key, label?, width?}]}` for `table`. |
| `owner_id` | reference | Absent for general (shared) views; set for personal views. |

General views have no `owner_id`; personal views bind `owner_id` to the creator. The backend assigns runtime ids (ULIDs) — you never choose the id. The frontend finds views through `meta.parent_id` and builds the `?view=` URL slug from the view's `name`; give each view a human-readable `name`. See `data/fixtures/crm.facet-domain/views/crm.Deal/collection_views/` for the pattern.

## Reading error details

Tool errors come back as:
```json
{"ok": false, "error": "Doctype validation failed", "details": ["...","..."]}
```

- **draft-domain guard errors** — "Domain 'X' is not the conversation's draft domain '...'" — you passed a `definition.domain` that doesn't match. Fix the definition.
- **validation errors** — the details array lists each schema-level problem. Fix them all.
- **service errors** — the message describes the failure; usually a malformed JSON or a reserved action name.

## When to use `$force`

Never in draft — it's implicit. `Doctype::Update` detects draft mode via `draft_domain?` and skips the same-version guards (field removal, type changes) automatically. You can freely rewrite doctypes.

## Smoke-test guidance

- Use `create_document` with realistic content before declaring the doctype "done". A doctype with a `create(ctx)` Lua hook may reject content the schema validator allowed.
- If `create_document` fails with "Script validation failed", read the `details` array — `ctx.error(msg)` strings appear verbatim there.

## Common error patterns

| Pattern | Fix |
|---|---|
| `Doctype 'X' not found` on `update_doctype` | The doctype was never created successfully, or was deleted. Check via `list_doctypes`. |
| `Domain 'X' is not the conversation's draft domain` | You passed the wrong `definition.domain`. It must equal the draft domain name exactly. |
| `Non-breaking update cannot remove fields` | This is a live-domain guard — it shouldn't fire in draft. If it does, the draft flag was lost mid-conversation (publish happened?). Treat the conversation as stale. |
| `Reference field 'X' targets doctype 'Y' which is not a registered doctype` | `check_doctype` warning. Create `Y` first, or accept it as a forward reference (will resolve at publish time). |
| `:composition` warning (member_of reciprocity) | A child declares `member_of` but the parent has no matching `children:` entry — or a `reference` field targets a doctype declared as an owned child. Fix the pairing, or model the relation as `children` instead of a reference field. |
