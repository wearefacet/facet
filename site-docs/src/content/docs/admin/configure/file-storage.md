---
title: File storage
description: Store uploaded files on a local directory or an S3 bucket, and run the store care tasks.
type: how-to
audience: [operator]
features: [PLT-04]
sidebar:
  order: 4
verified_at: c34885a
---

The team starts uploading photos of damaged equipment, and you must decide
where the bytes live. Every uploaded file lives in one object store.
PostgreSQL holds the metadata and the access rules; the store holds the
bytes. You choose the backend at boot: a local directory or an S3 bucket.
S3-compatible services such as MinIO, R2, and Backblaze work through the
endpoint setting.

## When to use this

Set up or care for the store when:

- You configure file storage for a new install.
- You rotate the artifact signing secret.
- You clean ownerless files or orphaned objects.

## Before you start

- Two top-level keys are required: `artifact_base_url` and
  `artifact_grant_secret`. The boot fails without them.
- `artifact_base_url` is the origin that streams bytes. Browsers receive
  signed capability URLs there. Use a dedicated origin in production, never
  the main host.
- The storage adapter wires once per process from the config file. Pick the
  backend before the first upload.

## Steps

### 1. Choose the backend

```yaml
artifact:
  storage:
    type: filesystem
    directory: /data/store
```

```yaml
artifact:
  storage:
    type: s3
    bucket: facet-artifacts
    region: eu-west-1
    directory: artifacts
```

| Field | Default | Meaning |
| --- | --- | --- |
| `type` | `filesystem` | `filesystem` or `s3`. Another value fails the boot. |
| `directory` | `tmp/uploads/dev` | Filesystem: the storage root. S3: the key prefix inside the bucket. |
| `bucket` | none | S3 only. Required for `s3`. |
| `region` | none | S3 only. Required for `s3`. |
| `access_key_id` | none | S3 only. Falls back to the `S3_ACCESS_KEY_ID` env var. |
| `secret_access_key` | none | S3 only. Falls back to the `S3_SECRET_ACCESS_KEY` env var. |
| `endpoint` | none | S3 only. Falls back to the `S3_ENDPOINT` env var. Set it for S3-compatible backends. |
| `public` | `false` | Reserved. Serving always goes through signed grants. |

The entry is validated at boot. An `s3` entry needs the bucket, the region,
and both credentials, or the boot stops with a message that names the
missing fields.

:::caution
The backend is file-only. The settings page shows the effective type as a
read-only row, and a runtime switch is refused. A switch would strand the
existing bytes in the old backend. To move backends, copy the objects and
change the file during a restart window.
:::

### 2. Size the knobs

| Key | Default | Meaning |
| --- | --- | --- |
| `artifact.max_upload_bytes` | `52428800` (50 MiB) | Hard cap on one upload. An oversized upload answers `413` before any disk write. Config file only: a change needs a restart. |
| `artifact.grant_ttl_seconds` | `3600` | Signed-URL TTL for documents and images. |
| `artifact.grant_ttl_media_seconds` | `21600` | Signed-URL TTL for audio and video. |
| `artifact.upload_grant_ttl_seconds` | `300` | TTL of a one-time signed upload URL for agent surfaces. Config file only: a change needs a restart. |
| `artifact.prune_after_days` | `30` | Ownerless files become prune-eligible after this window. `0` keeps every file forever. |
| `artifact.grant_prune_days` | `7` | Expired ephemeral grant rows leave the table after this window. `0` keeps every row forever. |

Four keys are hot: `grant_ttl_seconds`, `grant_ttl_media_seconds`,
`prune_after_days`, and `grant_prune_days`. A settings save changes them
from the next mint or prune run — see
[System settings](/admin/configure/system-settings/).

`max_upload_bytes` and `upload_grant_ttl_seconds` stay in the config file
only: the settings registry holds no entry for them, so a change needs a
restart. `storage.type` is read-only on the settings page — the storage
adapter wires once per process, and a runtime switch is refused.

### 3. Rotate the signing secret

Anyone holding `artifact_grant_secret` can mint valid download links for
every artifact. Rotate it with the previous-secret key:

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
artifact_grant_secret_previous: !env ARTIFACT_GRANT_SECRET_PREVIOUS
```

Set the new value in `artifact_grant_secret` and move the old value to
`artifact_grant_secret_previous`. Links signed with the old secret keep
working until they expire. Remove the previous key one TTL window after the
rotation.

### 4. Run the care tasks

```sh
facet artifacts:prune                 # soft-delete ownerless files
facet artifacts:prune --hard          # remove rows and bytes
facet artifacts:reconcile --dry-run   # list objects with no artifact row
facet artifacts:reconcile             # delete them (older than one hour)
facet artifacts:revoke <artifact-id>  # invalidate every signed URL for one file
```

The prune keeps a file that any live owner row or recent reference names.
The admin page at **Configure → Platform → Artifacts** lists the store with
per-row counts. See [First start and bootstrap](/admin/install/bootstrap/)
for the command details.

## Example

A complete S3 setup for one environment. The credentials come from the
environment, not from the file:

```yaml
artifact_base_url: "https://cdn.example.tld"
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET

artifact:
  prune_after_days: 30
  grant_ttl_seconds: 3600
  grant_ttl_media_seconds: 21600
  max_upload_bytes: 52428800
  upload_grant_ttl_seconds: 300
  storage:
    type: s3
    bucket: facet-artifacts
    region: eu-west-1
    directory: artifacts
```

With `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, and `S3_ENDPOINT` set in
the environment.

## Troubleshooting

**The boot fails and names missing storage fields.**

An `s3` entry misses the bucket, the region, or a credential. Fill the YAML
key or set the env fallback.

**An upload answers `413`.**

The body passed `artifact.max_upload_bytes`. Raise the cap, or split the
file.

**A download link stopped working.**

The signed URL expired. Grant TTLs are 1 hour by default, 6 hours for media.
The gateway mints a fresh link on every click from the app.

**Ownerless uploads disappear.**

A standalone upload has no owner document until it lands in one. The prune
sweeps it after `prune_after_days`, unless a reference keeps it. Raise the
window, or pin it on the settings page.

**A caller cannot download a file they can name.**

Access follows provenance, not knowledge of the id. A caller reads a file
through an owner row they can read, or through an operator `download *.*`
action. See [Hide a field from some roles](/admin/people/hidden-fields/)
for the tag layer.

## Related

- [Configuration files](/admin/configure/configuration-files/) — where the `artifact:` section lives.
- [System settings](/admin/configure/system-settings/) — the hot serving knobs.
- [Files in doctypes](/build/model/data/files/) — the author-side view of file fields.
- [Files in apps](/build/apps/data/files/) — file uploads from the app surface.
- [Retention](/admin/history/retention/) — the prune window among the other windows.
- Internals on GitHub: [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
