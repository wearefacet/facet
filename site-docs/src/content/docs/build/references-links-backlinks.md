---
title: References, links and backlinks
description: Connect documents with reference fields and text links, and show users who points at a document.
audience: [author]
features: [DOC-05, DOC-10]
sidebar:
  order: 4
verified_at: fd345fe3
---

Documents point at other documents. A `reference` field holds one typed link, a collection reference holds many, and a longtext field can carry links inside markdown. Facet indexes every link, so each document page can also show the reverse: which documents point here.

## When to use this

Use reference fields when one record names another record but does not own it — an employee names their manager, a task names its assignee. When the part belongs to the whole, model composition instead (see [Parent/child composition](/build/parent-child-composition/)).

## Before you start

- **A qualified target.** The target of a reference is always a qualified doctype id: `domain.Doctype`, for example `iam.Account`. A bare name is rejected, and every value of such a field fails.
- **Read access to the target.** Users need read access to a target doctype to resolve its references.

## Steps

### 1. Declare a reference field

```json
"owner": {
  "type": "reference",
  "doctype": "iam.Account",
  "filters": ["equality"]
}
```

Users submit a bare id, a qualified id, or a `urn:facet:` token. Facet stores the qualified form `iam.Account.01HQ2F5WX8K4M3PZC6NRB9TJVA` in every case.

### 2. Restrain the picker with a filter

The optional `filter` limits which documents a reference accepts. Facet checks the filter on every write.

```json
"company": {
  "type": "reference",
  "doctype": "identity.Company",
  "filter": { "status__eq": "active" }
}
```

### 3. Allow forward references

A reference normally must point at a document that exists. Set `dangling: true` when the target may not exist yet, for example a successor filled in a later step.

### 4. Point at many documents

Add `collection: true` to hold an array of references. Facet checks each element in turn.

```json
"watchers": {
  "type": "reference",
  "doctype": "iam.Account",
  "collection": true
}
```

### 5. Link inside long text

A `longtext` field accepts markdown links to documents. Both forms below produce a link on the page and count as a link in the index:

```markdown
Checked with [Marie Dubois](urn:facet:iam:Account:01JCATPMKP4N82GVG2J7K4MHZZ).

Follow-up for [Acme Corp](crm.Company.01HQ2F5WX8K4M3PZC6NRB9TJVA).
```

Both forms count: a `urn:facet:` token anywhere in the text, and a markdown link whose address is a document. A dotted address typed in plain prose, without a link, does not count.

## Example

The definition below wires an employee to an account and to a manager in the same doctype.

```json
{
  "fields": {
    "person": { "type": "reference", "doctype": "identity.Person", "required": true, "unique": true },
    "manager": { "type": "reference", "doctype": "hr.Employee", "filters": ["equality"] },
    "notes": { "type": "longtext" }
  }
}
```

On each document page, the **Referenced by** section lists the documents that point here, with the doctype as a tag. Before a delete, Facet warns: `N document(s) reference it — deleting it leaves those links dangling`. The delete is never blocked.

## Troubleshooting

### Every value of the field is rejected

The declared `doctype` must be the qualified form `domain.Doctype`. A bare name such as `"Employee"` fails, and Facet rejects every value at write time.

### A reference shows as empty or not found

The target document was deleted, or your role cannot read its doctype. Facet keeps the stored value but resolves nothing for you.

### The reference to a draft domain is refused

A live domain cannot reference a doctype that still lives in a draft. Publish the draft first.

## Related

- [Links and back-references (engineering doc)](https://github.com/wearefacet/facet/blob/main/doc/backend/links.md) — how the link index works.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — where the link index lives.
- [Parent/child composition](/build/parent-child-composition/) — model owned children instead of loose references.
