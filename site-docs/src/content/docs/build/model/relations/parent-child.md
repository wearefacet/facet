---
type: how-to
title: Parent/child composition
description: Model owned children that a parent document creates, locks, and deletes together.
audience: [author]
features: [DOM-05, DOC-07]
sidebar:
  order: 1
verified_at: fd345fe3
---

Some records are parts of a whole. An order holds its lines, a project holds its tasks, an employee holds their career events. Facet models this as composition: the parent owns its children, and the child cannot exist outside the parent. One declaration on the parent and one on the child set the pair up.

## When to use this

Use composition when the child belongs to exactly one parent and dies with it. Use a reference field when the target stands alone (see [References, links and backlinks](/build/model/relations/references-links/)).

## Before you start

- **Both halves.** The parent declares a `children` entry, and the child declares `member_of` back. Facet rejects a one-sided pair.
- **Same domain, short name.** A child doctype lives in the same domain as its parent, and its name is written without the domain prefix.

## Steps

### 1. Declare the parent as an aggregate root

The root is the record users create and delete. Set `aggregate_root: true` on it.

### 2. Add the `children` entry

Each entry is named after the relationship, for example `tasks`. The name becomes the route segment for nested creates.

```json
"children": {
  "tasks": { "doctype": "Task", "collection": true }
}
```

`collection: true` holds many children. A single-child relationship omits it.

### 3. Declare the child with `member_of`

```json
"member_of": "Project",
"aggregate_root": false
```

Do not add a reference field on the child that points back at the parent. Facet manages the parent link itself.

### 4. Create the parent with its children in one call

Send a compound body: `$content` for the parent fields and `$children` for the nested ones. Facet creates everything in one transaction. If one child fails validation, nothing is written.

### 5. Rely on the composition rules

| Rule | Effect |
| --- | --- |
| Cascade delete | Deleting the parent deletes its children. |
| Lock coupling | A write to a child locks the parent, so the aggregate stays consistent. |
| Flat create refused | A child created outside its parent answers `422`. Use the nested route. |
| Inherited access | A permission on the parent covers the child, because the child path extends the parent path. |
| Event fan-out | A child change notifies the parent, so parent-side computed fields update. |

## Example

The two definitions below declare a `projects.Project` root and its `projects.Task` child.

```json
{
  "domain": "projects",
  "doctype": "Project",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ name }}",
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "status": { "type": "enum", "default": "planned", "filters": ["equality"],
      "values": [ { "key": "planned", "label": "Planned" }, { "key": "active", "label": "Active" } ] }
  },
  "children": {
    "tasks": { "doctype": "Task", "collection": true }
  }
}
```

```json
{
  "domain": "projects",
  "doctype": "Task",
  "aggregate_root": false,
  "member_of": "Project",
  "schema_version": 1,
  "display_name": "{{ title }}",
  "fields": {
    "title": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "done": { "type": "boolean", "default": false }
  }
}
```

One call creates the project and its first task:

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Project" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "$content": { "name": "Apollo", "status": "active" },
    "$children": {
      "tasks": [ { "title": "Cut the keyway" } ]
    }
  }'
```

`-k` skips the certificate check of the local development address. The response carries the parent and the created children. The task takes `done: false` from its default.

## Troubleshooting

### Publish refuses the pair

One half of the composition is missing. Add the `member_of` on the child or the `children` entry on the parent, then publish again.

### A flat create of the child answers `422`

Children are created through the parent. Use the nested route on the parent document, or the compound body shown above.

### The child shows under a different parent after a copy

It cannot. A copy re-parents the child to the copied parent, never to the original one.

### Deleting a child does not delete the parent

Correct. The cascade runs downward only: a parent delete removes its children.

## Related

- [Doctype schema (reference)](/reference/doctype-schema/) — the `children` and `member_of` keys in full.
- [Documents, doctypes and projections](/build/deeper/documents-and-projections/) — how the parent link is stored.
- [Sidecars (comments, attachments)](/build/model/relations/comments-attachments/) — attach a discussion panel to the parent.
