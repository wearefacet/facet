---
title: Files and artifacts in fields
description: Store files in fields through the artifact store and control which file types a field accepts.
audience: [author]
features: [PLT-04]
sidebar:
  order: 8
verified_at: fd345fe3
---

A `file` field holds a file, not a string of characters. The field stores the id of an artifact, and the artifact store keeps the bytes outside the document. This keeps documents small and lets two documents share one file without copying it.

## When to use this

Use a `file` field when the file is part of the record: a signed contract on a deal, a resume on a candidate, a photo on an item. For discussion files that belong to no field, use the attachments panel instead (see [Sidecars (comments, attachments)](/build/sidecars/)).

## Before you start

- **Storage is built in.** The artifact store exists on every instance. You declare the field; you do not configure storage.
- **A size limit.** One upload is limited to 50 megabytes by default. Your administrator sets the limit.
- **A type list, if you want one.** Facet accepts any file type by default. Declare an `accept` list when the field should take only some types.

## Steps

### 1. Declare the file field

```json
"contract": {
  "type": "file",
  "accept": ["application/pdf"],
  "title": "Signed contract"
}
```

The `accept` list uses MIME types. Facet decides the type of an upload from the file content, not from the file name, and rejects an upload that does not match the list. A field without `accept` takes every type.

### 2. Upload in the app

In a form, the user picks a file for the field. Facet uploads the bytes, stores them, and puts the artifact id into the field. The save and the upload are one step: if either fails, nothing is written.

### 3. Upload through the API

Send a multipart body. One part named `$content` carries the document fields, and one part per file field carries the bytes, named after the field.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Deliverable" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -F '$content={"title":"Kickoff deck"}' \
  -F 'contract=@./kickoff.pdf'
```

`-k` skips the certificate check of the local development address.

### 4. Know what the store does

| Rule | Effect |
| --- | --- |
| Same content, one copy | Identical bytes are stored once and reused. |
| Access follows documents | A file is readable through the documents that reference it. |
| Out-of-band uploads | A file pasted into a long text is uploaded first and linked on save. |

A longtext field can embed a file link with the form `urn:facet:artifact:<id>`. Every reader of that document gains access to the file.

## Example

```json
{
  "domain": "projects",
  "doctype": "Deliverable",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ title }}",
  "fields": {
    "title": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "contract": { "type": "file", "accept": ["application/pdf"] },
    "deck": { "type": "file" }
  }
}
```

The `contract` field takes only PDF files. The `deck` field takes any file type.

## Troubleshooting

### The upload answers `413`

The file is larger than the size limit. Use a smaller file, or ask your administrator to raise the limit.

### The upload answers `422` with a MIME error

The file content does not match the `accept` list. Rename the field list or convert the file; changing the file name alone does not help, because Facet reads the content.

### An export carries a short id instead of the file

That is the artifact id. The file content does not travel with a CSV or JSON export; download files from the document page.

### A file link in a document shows as dead

The file was destroyed by an administrator. The reference stays in the text but the bytes are gone.

## Related

- [Artifacts (engineering doc)](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md) — the artifact store in full.
- [Domains and isolation](/concepts/domains-and-isolation/) — how the store sits outside your domain.
- [Secret and write-only fields](/build/secret-write-only-fields/) — store credentials safely in fields.
