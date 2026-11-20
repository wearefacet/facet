---
title: Artifacts
description: Moving files in and out of Facet — request_artifact_upload plus a multipart POST, then linking the artifact id; get_artifact plus a GET for downloads. No bytes ride the tool arguments.
tags: [artifacts, files, upload, download]
surfaces: [mcp]
---

# Artifacts

File bytes never travel through tool arguments — no base64, no JSON
payloads. The tools hand you a short-lived signed URL; your HTTP client
does the transfer.

## Uploading a file

1. **Mint.** `request_artifact_upload` with `filename` (and `size_bytes`
   when you know it — an oversized file is refused here before any byte
   moves). The result carries `upload_url`, `method: "POST"`, and
   `field: "file"`, plus `meta.expires_at` and `meta.max_bytes`.
2. **Upload.** Immediately POST `multipart/form-data` to `upload_url`
   with exactly one part named `file` holding the raw bytes — and **no
   Authorization header**. The URL signature is the credential; a bearer
   token (for example your MCP token) is rejected by the REST auth gate
   before the route runs. The URL is
   **single-use** and expires in about 5 minutes — upload right away.
   A `201` body answers `{id, filename, mime_type, size, sha256}`.
3. **Link.** Put the returned `id` into a document with
   `create_document` or `update_document`: as the value of a `file`
   field, or as a `[filename](urn:facet:artifact:<id>)` link inside a
   longtext field. Linking is what keeps the artifact alive — an
   unlinked upload is swept by prune after the retention window.

## Upload failures (403 with a `reason` body)

- `expired` / `already_used` — the URL is spent. Call
  `request_artifact_upload` again for a fresh one. Do not retry the same
  URL.
- `invalid_signature` — the URL is wrong. Re-mint; do not guess the
  query parameters.
- `stale` — the account or role that minted the URL changed. Re-mint
  after the situation recovers.
- `415` — wrong `Content-Type`. Send
  `multipart/form-data` with a boundary; the URL is still valid after a
  415 (only a parsed body burns it).
- `413` — the file exceeds `max_upload_bytes`. Pass `size_bytes` to the
  mint call so this fails before the upload.

## Downloading a file

1. `get_artifact` with the `artifact_id` — the value of a `file` field
   or the id inside a `urn:facet:artifact:` link.
2. GET `data.download_url` with your HTTP client. The signature in the
   URL is the credential — no headers needed.
3. The URL is **not** single-use: stream, retry, or seek freely until
   `meta.expires_at` (about 1 hour for documents and images, 6 hours for
   audio and video). Past expiry, call `get_artifact` again — access is
   re-checked at every mint.

A denied or unknown artifact id raises the same refusal discipline as
every other tool: report it, do not retry around it.
