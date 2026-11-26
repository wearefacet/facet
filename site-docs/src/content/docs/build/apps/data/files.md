---
type: how-to
title: Uploading and serving files
description: Upload files into documents and serve them through signed grants.
audience: [developer]
features: [PLT-04]
sidebar:
  order: 4
verified_at: a77c6171
---

Facet stores file bytes in object storage. A `file` field on a document
holds an artifact id, not the bytes. A longtext field can embed a
`urn:facet:artifact:<id>` link. Reads of the bytes go through short-lived
signed URLs.

> **For agents:** Attach on write: `POST /Api/<domain>/<doctype>` (or
> `PATCH`) with `multipart/form-data` — a `$content` part with the document
> JSON plus one part per `file` field. Standalone: `POST
> /Api/core/artifacts` with a `file` part answers `201 {id, filename,
> mime_type, size, sha256}`. `GET /Api/core/artifacts/:id` returns a fresh
> signed `url` (TTL 1 h; media 6 h); mint again with `POST
> /Api/core/artifacts/:id/grant`. Serve an app origin with
> `GET /Api/core/artifacts/:id/download?app=<APP_ID>` (`Origin` registered).

## When to use this

Use this page when:

- You attach files to documents as people save them.
- You upload a file before you know the document that will hold it.
- You serve images or downloads to people with no Facet session.

## Before you start

- An artifact is a set of bytes with metadata. It belongs to no domain.
- An artifact becomes readable to others when its id lands in a document.
  The save appends an owner row. Uploading alone grants nothing.
- A `file` field holds the artifact id. A longtext link shares the file
  with every reader of the document.
- The upload cap is 50 MiB per request by default
  (`artifact.max_upload_bytes`); an oversize body answers `413`.
- To attach on write you need `create` or `update` rights on the target
  doctype. To serve from your app's origin, the origin must be registered
  on an active app — see [CORS and allowed origins](/build/apps/connect/cors/).

## Steps

### 1. Attach files on write

One multipart call creates the document and uploads the parts in one
transaction:

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F '$content={"name": "Acme"};type=application/json' \
  -F 'logo=@/path/to/logo.png'
```

The `$content` part carries the document JSON. Each `file` field rides in
a part named by its field path: `logo`, `avatars[0].file`, `items[0].file`.
The server uploads the bytes and puts the artifact id into the field. A
failure rolls back the uploads and the document together.

### 2. Upload standalone, then link

When the document does not exist yet, upload first:

```sh
curl -s -X POST "https://facet.company.tld/Api/core/artifacts" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F 'file=@/path/to/report.pdf'
```

The answer is `201`:

```json
{
  "id": "01JARQ5G7X9K2M3N4P5Q6R7S8T",
  "filename": "report.pdf",
  "mime_type": "application/pdf",
  "size": 48213,
  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
}
```

The uploading account is the only reader until the id lands in a document.
Paste the id into a `file` field, or embed
`urn:facet:artifact:01JARQ5G7X9K2M3N4P5Q6R7S8T` in a longtext, and save.
Every reader of the document can then read the file. The prune sweeps an
unlinked upload after the retention window.

### 3. Read metadata and mint a fresh URL

```sh
curl -s "https://facet.company.tld/Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T" \
  -H "Authorization: Bearer $FACET_TOKEN"
```

The answer is the upload shape plus two members: `url`, the signed serve
URL, and `expires_at`. The URL rotates on every fetch. `POST
/Api/core/artifacts/:id/grant` mints another URL without the metadata. The
TTL is server-derived: 1 hour for documents and images, 6 hours for audio
and video.

### 4. Serve a file to a browser

The download gateway does the auth check, the read check, and the mint,
then answers `302` to the signed URL:

```http
GET /Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T/download?app=01JHQ9M4T8C3XK2PB5WY6RD7QF
```

Put the URL in an `<a href>` or an `<img src>` from your app's origin.
With `?app=` present, the request must carry an `Origin` header that
matches a registered allowed origin. The gateway resolves the app from the
`Origin`, checks it equals the `?app=` value, and reads through the app's
grant ceiling. Without an `Origin` header the `?app=` part is ignored: the
call falls through to cookie or bearer auth. A request with no credential
at all runs under the seeded anonymous role. The gateway answers
`Cache-Control: no-store`, so every click mints a fresh grant.

### 5. Publish a permanent URL, or revoke

A permanent URL does not expire. It needs a named permission — the
`publish_artifact` action on the owner doctype. `read` alone is not
enough. The call names the owner row that binds the grant:

```sh
curl -s -X POST "https://facet.company.tld/Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T/publish" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"owner_id": "01JGK2M4N6P8R0T2V4X6Z8B2D4"}'
```

Revoke any grant with `DELETE /Api/core/artifacts/grants/:gid`. The gate
accepts `publish_artifact` on the owner document, the `revoke *.*`
operator action, or the system bypass.

## Example

The TypeScript SDK mirrors these routes — see [The TypeScript
SDK](/build/apps/data/sdk/):

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
  baseUrl: 'https://facet.company.tld',
  auth: staticKey(process.env.FACET_API_KEY!),
});
const companies = facet.domain('crm').doctype('Company');
const doc = companies.doc('crm.Company.abc');
// file is the file to upload; ownerId names the owner row to bind.

// Attach: one multipart call. The uploads and the mutation share one
// server-side transaction.
await companies.create({ name: 'Acme' }, { files: { logo: file } });
await doc.update({ name: 'Acme' }, { files: { 'items[0].file': file } });

// Standalone upload, then link the id or the URN.
const { id, filename } = await facet.artifacts.upload(file);
await facet.artifacts.uploadAsUrn(file); // urn:facet:artifact:<id> for longtexts

// Read URLs for someone with no session.
const grant = await facet.artifacts.grant(id); // ephemeral; the server derives the TTL
const meta = await facet.artifacts.show(id);
await facet.artifacts.revoke(grant.grant_id);

// A permanent public URL needs the publish_artifact action on an owner
// document; the provenance row binds the grant.
await facet.artifacts.publish(id, { ownerId });

// <a href> / <img src>: the gateway mints a fresh grant per request.
facet.artifacts.downloadUrl(id);
facet.artifacts.downloadUrl(id, { appId }); // app-origin reads
const bytes = await facet.artifacts.download(id); // follows the 302, returns the bytes
```

## Behaviour notes

- **MIME comes from the bytes.** The server sniffs magic bytes and ignores
  the client's `Content-Type`. An unknown type becomes
  `application/octet-stream`.
- **Dedup reuses bytes you can read.** Identical bytes under a readable
  provenance are reused; the store write is skipped.
- **The serve route hardens responses.** It sends `nosniff`, a Content
  Security Policy (CSP), and a `Content-Disposition` that follows the MIME
  type.
- **Removing a link does not revoke access.** The owner row that the
  document appended stays.
- **`file` fields export as ids only.** Bytes do not move in a bulk export
  — see [Bulk import/export via API](/build/apps/data/bulk-import-export/).

## Troubleshooting

**A download answers `403`.**

No readable provenance: the id is not in any document your credential can
read. Link it into a document you can read, or read it as the uploader.

**An upload answers `413`.**

The body is over the cap, 50 MiB by default. Split the file.

**An upload answers `415`.**

The route takes only `multipart/form-data`. Send the file as a part.

**A signed URL stopped working.**

The TTL expired. Mint a fresh one; the server derives the TTL from the
MIME type.

**The image renders for a colleague but answers `403` in your app.**

The app-origin path needs both `?app=<APP_ID>` and an `Origin` header that
matches a registered allowed origin. Check both.

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the document routes the multipart intake rides on.
- [The TypeScript SDK](/build/apps/data/sdk/) — the `facet.artifacts` helpers.
- [CORS and allowed origins](/build/apps/connect/cors/) — registering the origin the gateway checks.
- [Agent tools](/build/apps/agents/agent-tools/) — `get_artifact` and `request_artifact_upload` for agents.
- Internals on GitHub:
  [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md).
