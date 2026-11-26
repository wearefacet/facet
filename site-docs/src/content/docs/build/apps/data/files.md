---
title: Upload and serve files
description: Store file bytes as artifacts, attach them to documents, and serve them through signed grants.
type: how-to
audience: [developer]
features: [PLT-04]
verified_at: eee55a2
sidebar:
  order: 4
---

Facet stores file bytes as artifacts. A `file` field on a document holds an
artifact id, not the bytes. A longtext field can embed a
`urn:facet:artifact:<id>` link. Reads of the bytes go through short-lived
signed URLs.

> **For agents:** Attach on write: `POST /Api/<domain>/<doctype>` (or `PATCH`) with
> `multipart/form-data` — a `$content` part with the document JSON plus one part per `file` field.
> Standalone: `POST /Api/core/artifacts` with a `file` part answers `201 {id, filename, mime_type,
> size, sha256}`. `GET /Api/core/artifacts/:id` returns a fresh signed `url`; mint another with
> `POST /Api/core/artifacts/:id/grant`. Revoke with `DELETE /Api/core/artifacts/grants/:gid`.
> Serve an app origin with `GET /Api/core/artifacts/:id/download?app=<APP_ID>` (`Origin` registered).

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

The live calls on this page ran against a dev instance at
`https://facet.localhost:3443` with the Brightwater Rentals data loaded.

## Steps

### 1. Attach files on write

One multipart call creates the document and uploads the parts in one
transaction:

```sh
curl -sk -b facet-cookies.txt -X POST https://facet.localhost:3443/Api/clients/Company \
  -H 'X-Requested-With: XMLHttpRequest' \
  -F '$content={"name": "Café des Sports", "city": "Vienne"};type=application/json' \
  -F 'logo=@/path/to/logo.png'
```

The `$content` part carries the document JSON. Each `file` field rides in a
part named by its field path: `logo`, `avatars[0].file`, `items[0].file`.
The server uploads the bytes and puts the artifact id into the field. A
failure rolls back the uploads and the document together.

### 2. Upload standalone, then link

When the document does not exist yet, upload first. This session uploaded a
two-line text file:

```sh
printf 'Brightwater invoice, season 2026\nTotal: 1 240 EUR\n' > sample.txt

curl -sk -b facet-cookies.txt -H 'X-Requested-With: XMLHttpRequest' \
  -F 'file=@sample.txt;type=text/plain' \
  https://facet.localhost:3443/Api/core/artifacts
```

The answer is `201`:

```json
{
  "id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "filename": "sample.txt",
  "mime_type": "text/plain",
  "size": 50,
  "sha256": "0387edeb06179ee53dcdab018063aa7253615b0b28e97b748bae04ecb09ffbb7"
}
```

The uploading account is the only reader until the id lands in a document.
Paste the id into a `file` field, or embed
`urn:facet:artifact:06H1FS5YBW6JQ7R39DQBK6T236` in a longtext, and save.
Every reader of the document can then read the file. The prune sweeps an
unlinked upload after the retention window.

### 3. Read metadata and mint a fresh URL

```sh
curl -sk -b facet-cookies.txt \
  https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236
```

The answer is the upload shape plus two members:

```json
{
  "id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "filename": "sample.txt",
  "mime_type": "text/plain",
  "size": 50,
  "sha256": "0387edeb06179ee53dcdab018063aa7253615b0b28e97b748bae04ecb09ffbb7",
  "url": "https://facet.localhost:3443/A/06H1FS5YF8NMQWGA39QDAFRN8S?exp=1795700796&sig=JwJ1NpGQ_DNumjlYj96z3scupyAGD0j_LJvpkE1pS0k",
  "expires_at": "2026-11-26T13:46:36Z"
}
```

`url` is a signed serve URL; it rotates on every fetch — each call mints a
fresh grant. `POST /Api/core/artifacts/:id/grant` mints another URL without
the metadata:

```json
{
  "grant_id": "06H1FS6HNCZ1C6KWKZXMZSRDAE",
  "artifact_id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "url": "https://facet.localhost:3443/A/06H1FS6HNCZ1C6KWKZXMZSRDAE?exp=1795700801&sig=1c4MSJtJHj33Ute1t-JujvVaAlXskA3u-tpVW0uuL_8",
  "expires_at": "2026-11-26T13:46:41Z"
}
```

The TTL is server-derived: about 1 hour for documents and images, 6 hours
for audio and video.

### 4. Serve a file to a browser

The download gateway does the auth check, the read check, and the mint, then
answers `302` to the signed URL:

```sh
curl -sk -D - -o /dev/null -b facet-cookies.txt \
  'https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236/download' | grep -i location
# location: https://facet.localhost:3443/A/06H1FS5YJC402HNNVJHGAF529V?exp=…&sig=…
```

Put the gateway URL in an `<a href>` or an `<img src>` from your app's
origin. With `?app=<APP_ID>` present, the request must carry an `Origin`
header that matches a registered allowed origin. The gateway resolves the
app from the `Origin`, checks it equals the `?app=` value, and reads through
the app's grant ceiling. Without an `Origin` header the `?app=` part is
ignored: the call falls through to cookie or bearer auth. A request with no
credential at all runs under the seeded anonymous role. The gateway answers
`Cache-Control: no-store`, so every click mints a fresh grant.

### 5. Publish a permanent URL, or revoke

A permanent URL does not expire. It needs a named permission — the
`publish_artifact` action on the owner doctype. `read` alone is not enough.
The call names the owner row that binds the grant:

```sh
curl -sk -b facet-cookies.txt -X POST \
  https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236/publish \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"owner_id": "<owner document id>"}'
```

Revoke any grant with `DELETE /Api/core/artifacts/grants/:gid`:

```sh
curl -sk -b facet-cookies.txt -X DELETE -o /dev/null -w '%{http_code}\n' \
  -H 'X-Requested-With: XMLHttpRequest' \
  https://facet.localhost:3443/Api/core/artifacts/grants/06H1FS6HNCZ1C6KWKZXMZSRDAE
# 204
```

After the revoke, that grant's URL stops serving. The gate accepts
`publish_artifact` on the owner document, the `revoke *.*` operator action,
or the system bypass.

## Example

The TypeScript SDK mirrors these routes — see
[The TypeScript SDK](/build/apps/data/sdk/):

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');
const doc = companies.doc('06H1FM1B3MXBPS0JYVM3BDD154');
// file is the file to upload; ownerId names the owner row to bind.

// Attach: one multipart call. The uploads and the mutation share one
// server-side transaction.
await companies.create({ name: 'Café des Sports' }, { files: { logo: file } });
await doc.update({ name: 'Café des Sports' }, { files: { 'items[0].file': file } });

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
- **`file` fields export as ids only.** Bytes do not move in a bulk export —
  see [Bulk import and export](/build/apps/data/bulk-import-export/).

## Troubleshooting

**A download answers `403`.**

No readable provenance: the id is not in any document your credential can
read. Link it into a document you can read, or read it as the uploader.

**An upload answers `413`.**

The body is over the cap, 50 MiB by default. Split the file.

**An upload answers `415`.**

The route takes only `multipart/form-data`. Send the file as a part.

**A signed URL stopped working.**

The TTL expired. Mint a fresh one; the server derives the TTL from the MIME
type.

**The image renders for a colleague but answers `403` in your app.**

The app-origin path needs both `?app=<APP_ID>` and an `Origin` header that
matches a registered allowed origin. Check both.

**Revoking one grant did not take the artifact down.**

A revoke kills one grant. A fresh `show` or `download` call mints a new one.
Unlink the artifact from every document to remove read access for good.

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the document routes the multipart intake rides on.
- [The TypeScript SDK](/build/apps/data/sdk/) — the `facet.artifacts` helpers.
- [CORS and allowed origins](/build/apps/connect/cors/) — registering the origin the gateway checks.
- [What agents can do](/build/apps/agents/agent-tools/) — `get_artifact` and `request_artifact_upload` for agents.
- Internals on GitHub:
  [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md).
