---
title: Children and Composition
description: children declaration, parent→child convention, parent_id meta, cascade delete, nested HTTP routing, sidebar visibility (nav_visible).
tags: [composition, children, navigation]
---

# Children and Composition

`children` on a doctype declares a parent→child composition relationship. Child documents live in the same domain as the parent and are linked via `meta->>'parent_id'`.

## Declaration

```json
{
  "doctype": "WorkOrder",
  "children": {
    "tasks": {
      "doctype": "Task",
      "collection": true,
      "description": "Tasks for this work order"
    }
  }
}
```

The child doctype (`Task`) must declare `member_of: "WorkOrder"` on its own definition. The parent's `children` entry and the child's `member_of` are paired — both must be set.

## Convention

- The parent references its child via the *relationship name* (`tasks`), not the doctype name.
- A child MUST NOT declare a reference field back to the parent. The linkage is implicit via `meta->>'parent_id'`.
- `children` is a routing and composition rule, not ownership by itself. For cascade-delete behaviour the child must declare `member_of`.

## `parent_id` meta field

System-managed. Set at create time via `meta.parent_id`. Named scopes can reference `$parent_id` to filter children by their parent.

## Cascade delete

When a parent is deleted, `Document::Delete` walks `children` and soft-deletes every owned child (where the child's `member_of` matches the parent's doctype). Recursively descends.

## HTTP routing

Children are accessible via nested routes:
- `POST /api/:domain/:doctype/:id/:child_name` — create a child.
- `GET /api/:domain/:doctype/:id/:child_name/:child_id` — read a child.
- `PATCH /api/:domain/:doctype/:id/:child_name/:child_id` — update a child.

Routing uses the relationship name (`tasks`), not the child's doctype name (`Task`).

## Draft

In a draft domain, you may declare `children` freely. `check_doctype` will flag a child declaration whose target doctype is not registered — expected during iteration.

## Composite views (parent + children as one object)

The `children` declaration is what lets the UI present a parent and its
children as one composite object. Two things must line up:

1. **The parent doctype ships `relation` nodes in its DocumentView templates**
   (`data/fixtures/core.DocumentView/<Parent>.yml`).
   - In the `view` kind: one tab (or section) per child collection, each
     holding a `relation` with `view: "inline"`. The child rows render via
     the child's own `inline` template (with `quickView` fallback).
   - In the `form` kind: the same `relation`, but with `editable: true`.
     Each row renders the child's `form` template; Add/Remove are exposed.

2. **Each child doctype ships its four DocumentView kinds**: `view`,
   `quickView`, `form`, and `inline`. The `inline` kind is the compact
   one-line row shown inside the parent's relation box; the `form` kind is
   re-used by the inline editor.

Persistence is **non-transactional**: on parent save, `DocumentForm` saves
the parent first, then issues per-child create / update / delete calls
against `doc(parentId).children(rel)`. Partial failures surface as
per-relation errors on the parent form.

Example wiring for `hr.Candidate` + `hr.CandidateExperience`:

```yaml
# hr.Candidate/definition.yml
children:
  experiences:
    doctype: CandidateExperience
    collection: true

# core.DocumentView/hr.Candidate.yml — inside kind: view
- type: "relation"
  label: "Work Experience"
  doctype: "hr.CandidateExperience"
  source: { kind: "children", rel: "experiences" }
  view: "inline"
  limit: 25

# core.DocumentView/hr.CandidateExperience.yml — kind: inline
- content:
    parent_doctype: "hr.CandidateExperience"
    kind: "inline"
    template:
      type: "grid"
      layout: "auto auto 1fr auto"
      children:
        - { type: "label", value: "$title" }
        - { type: "capsule", value: "$company" }
        - { type: "label", value: "$start — $end" }
```

See [`document-views.md`](document-views.md) → Composite views for the full
`editable: true` form-mode pattern and the rules.

## Sidebar visibility

A child doctype is not in the left bar. Users reach it through the parent's
relations surface, a direct URL, or the nav search. Set `nav_visible: true`
on the child's definition to give it a sidebar entry with its own listing:

```yaml
# production.Task/definition.yml
doctype: Task
domain: production
aggregate_root: false
member_of: Project
nav_visible: true
```

Rules:

- `nav_visible: true` does not bypass RBAC. The role needs a `read` grant on
  the child; without it the child stays hidden.
- The flag has no effect on aggregate roots. They always show.
- A child with a sidebar entry ships its own DocumentView set (`view`,
  `quickView`, `form`, `inline`) so the listing and the forms render — see
  Composite views above.
- When the user asks for a child "in the left bar" or "with its own form",
  set `nav_visible: true` and author the child's DocumentView kinds.
