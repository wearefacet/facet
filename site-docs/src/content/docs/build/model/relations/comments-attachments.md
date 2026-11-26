---
type: how-to
title: Sidecars (comments, attachments)
description: Attach comment and attachment panels to a doctype and control who may use them.
audience: [author]
features: [DOM-06]
sidebar:
  order: 3
verified_at: fd345fe3
---

A sidecar is a panel beside a document: comments on one tab, files on another. The records live in their own doctypes in the `core` domain, and the host doctype declares which panels it carries. One declaration serves every doctype that wants the panel — you never copy the comment logic into your domain.

## When to use this

Add the `comments` panel when people discuss a record. Add the `attachments` panel when people keep files with a record. Both panels are declared on the doctype, so you can give them to any doctype in your domain.

## Before you start

- **A draft domain.** You edit the host doctype in a draft domain. See [Designing doctypes](/build/model/data/design-doctypes/).
- **Nothing to create.** The sidecar doctypes `core.Comment` and `core.Attachment` exist on every instance. You declare them on your host; you do not create them.
- **A free segment name.** A segment name (the panel's route segment, such as `comments`) cannot collide with a `children` relationship of the same name.

## Steps

### 1. Add the `sidecars` map to the host doctype

Each entry names the panel: the key is the route segment, and the value names the sidecar doctype plus the reference column that points back at the host.

```json
"sidecars": {
  "comments": { "doctype": "core.Comment", "column": "target" },
  "attachments": { "doctype": "core.Attachment", "column": "target" }
}
```

Two optional keys refine the panel: `label` changes the tab text, for example `"Notes"` instead of "Comments", and `order` sets the tab order when the default alphabetical order does not fit.

### 2. Check the rights

A nested sidecar grant follows the host path. In practice:

| Caller right | What it allows |
| --- | --- |
| read on `hr.Employee` | Read the comments and attachments. |
| create on `hr.Employee` | Write comments and attach files. |
| create on `hr.Employee.Comment` | Comment as a read-only user. |

That last line is how you let a viewer comment: keep their host rights read-only and add the explicit nested line for the action.

### 3. See the panel

Open a document. The panel stands beside the page and shows one tab per declared sidecar, with a count per tab. Comments take markdown, support replies, and notify a person when you mention them. Attachments show type, size, uploader, and time.

## Example

The definition below gives an employee record both panels, with a renamed comments tab.

```json
{
  "domain": "hr",
  "doctype": "Employee",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "job_title": { "type": "string", "required": true }
  },
  "sidecars": {
    "comments": { "doctype": "core.Comment", "column": "target", "label": "Notes" },
    "attachments": { "doctype": "core.Attachment", "column": "target" }
  }
}
```

The API creates a comment through the host path:

```sh
curl -k -X POST "https://facet.localhost:3443/Api/hr/Employee/01HQ2F5WX8K4M3PZC6NRB9TJVA/comments" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"body": "Welcome aboard"}'
```

`-k` skips the certificate check of the local development address. Facet sets the `target` from the path. A `target` key in the body answers `400`.

## Troubleshooting

### The panel does not show

The doctype carries no `sidecars` map, or the doctype was edited after the page was opened. Check the definition and reload.

### Commenting answers `403`

Your role can read the host but holds no create right on the host path and no explicit nested line. Ask the domain author for `create` on the host, or for the nested line shown in step 2.

### A flat create of `core.Comment` answers `422`

Sidecar records are created through the host document, never through the flat route. Use the nested path shown in the example.

### The comments are gone after a delete

Facet removes sidecar records when their host is deleted. The removal is separate from the host, so it is not undone when the host document itself is restored.

## Related

- [Sidecar doctypes (engineering doc)](https://github.com/wearefacet/facet/blob/main/doc/backend/sidecar.md) — the full sidecar contract.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — the two gates behind every panel action.
- [Files and artifacts in fields](/build/model/data/files/) — store files in fields, not only in the panel.
