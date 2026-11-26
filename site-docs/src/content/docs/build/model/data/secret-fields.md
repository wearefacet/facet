---
type: how-to
title: Secret and write-only fields
description: Store credentials in the secret store and accept values that Facet never stores or returns.
audience: [author, admin]
features: [DOC-09, PLT-03]
sidebar:
  order: 4
verified_at: fd345fe3
---

Two field settings keep sensitive values out of sight, and they solve two different problems. A `secret` field stores a credential in an encrypted store beside the document; the document carries only a marker. A `write_only` field accepts a value, hands it to the script, and then throws it away.

## When to use this

Use a `secret` field for a value the system must keep: an API key, a password hash, a one-time token. Use a `write_only` field for a value the script needs once and nobody should keep, such as a plaintext password that the script hashes.

| | `secret` field | `write_only` field |
| --- | --- | --- |
| Value kept | Yes, encrypted, outside documents | No, discarded after the write |
| Visible on read | No, a marker only | No, gone after the write |
| Visible in history, search, exports | No | No |
| Visible to scripts | No, only the marker | Yes, during the write |
| Change and clear | Yes, from the document page | Not applicable |

## Before you start

- **A draft domain.** You edit the doctype in a draft domain.
- **A mode.** A `secret` field declares a `mode`: `hash` for values that are only ever checked, `sealed` for values the system must read back itself, and `token` for a one-time value Facet generates.
- **The limits.** Secrets never appear in actions as arguments, in arrays or dictionaries, or in the display name and search templates.

## Steps

### 1. Declare the secret field

```json
"api_key": {
  "type": "secret",
  "mode": "sealed",
  "title": "API key"
}
```

Rules per mode:

| Mode | Use | Extra key |
| --- | --- | --- |
| `hash` | Verify a candidate against the stored value, never read it back. | — |
| `sealed` | The system reads the value back for its own features. | — |
| `token` | Facet generates the value; a caller consumes it once. | `ttl_seconds` (required) |

`min`, `max`, and `pattern` are allowed on a secret field; they check the plaintext when it is set, not the marker.

### 2. Set the value in the app

The document page shows a marker with **Change** and **Clear**. A change stages the new value: Facet stores it and bumps the version on the marker. A `token` mode shows **Generate new** and displays the token once.

### 3. Declare a write-only field

```json
"new_password": {
  "type": "string",
  "write_only": true,
  "title": "New password"
}
```

The script of the doctype reads the value during the write, does its work, and Facet strips the field before the document is stored. The common pairing is a `read_only` hash field: the script hashes the write-only input and stores the hash there, because a `secret` field accepts only staged values.

## Example

```json
{
  "domain": "ops",
  "doctype": "Service",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "api_key": { "type": "secret", "mode": "sealed" },
    "reset_code": { "type": "secret", "mode": "token", "ttl_seconds": 3600 },
    "new_password": { "type": "string", "write_only": true }
  }
}
```

A stored document carries markers instead of values:

```json
{
  "name": "Billing",
  "api_key": { "mode": "sealed", "version": 3, "set_at": "2026-03-01T09:12:00Z" }
}
```

A cleared secret stores `null`. A `write_only` field never appears in stored content at all.

## Troubleshooting

### The write answers `422` on the secret field

Only three shapes are valid: a stage handle, a marker, and `null` to clear. A plaintext string in a document body is always rejected.

### The token was shown once and is lost

Tokens display once, at generation. Generate a new one; the old token stops working.

### An admin cannot read the value back

That is the design. No route returns a sealed or hashed value. Only the system features that own the field read it, and a hashed value is never readable at all. To rotate, set a new value; the marker version rises.

The values sit in the encrypted store, keyed by document and field name, outside the document tables. When a document is deleted, the store keeps its slots until the retention window passes; a maintenance task then removes them.

### The write-only value is needed again later

It is gone. Facet never stores it. Keep the source of the value outside Facet if you need it again.

:::caution
Rolling a document back to an earlier state does not restore old secret values. The current values stay in place, and old credentials never come back.
:::

## Related

- [Secret store (engineering doc)](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md) — the store, its modes, and its lifecycle.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — who may read which fields.
- [Named actions](/build/model/behaviour/named-actions/) — add typed operations to the doctype.
