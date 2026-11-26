---
type: reference
title: Webhook payloads
description: Webhook payload fields, the signature header, and how to verify the signature.
audience: [developer, operator]
features: [AUT-03]
sidebar:
  order: 7
verified_at: 008dd880
---

Use this page to read a webhook body and to verify its signature on your receiver.

A webhook delivery is one HTTP POST. The body is a fixed-shape JSON
envelope, and every delivery carries a signature header computed from
the webhook's own secret.

This page gives the body fields, the headers, and the verification math.

## The POST request

| Header | Value |
| --- | --- |
| `Content-Type` | `application/json`. A custom header of the same name overrides it. |
| `User-Agent` | `Facet-Webhook/1.0`. A custom header of the same name overrides it. |
| `X-Facet-Signature` | `sha256=<hex>` — the signature. Never overridable. |
| `X-Facet-Event` | The event name, same as the body's `event`. |
| `X-Facet-Delivery` | The delivery id, same as the body's `delivery_id`. |
| `X-Facet-Webhook-Id` | The webhook id, same as the body's `webhook_id`. |
| `X-Facet-Mutation-Id` | The mutation id, when the event carries one. |
| `X-Facet-Origin` | `webhooks:<webhook_id>`. |

Custom headers from the webhook document merge in after the defaults.
Header keys that start with `X-Facet-` are rejected at authoring time,
so a custom header can never shadow the ones above.

## Body fields

The body is one JSON object. The fields always appear in this order, and
the signature covers these exact bytes:

| Field | Type | Content |
| --- | --- | --- |
| `webhook_id` | string | The qualified id of the `core.Webhook` document. |
| `delivery_id` | string | A fresh id for this delivery attempt. |
| `event` | string | The event name. See the table below. |
| `domain` | string | The source document's domain. |
| `doc_type` | string | The source document's doctype name. |
| `doc_id` | string | The source document's qualified id. For a job lifecycle event, the job id. |
| `mutation_id` | string \| null | The mutation that caused the event, when one exists. Job lifecycle events carry none. |
| `actioner_id` | string \| null | The qualified account id that made the change. |
| `cause` | object \| null | The cause trail: `kind`, plus optional `name`, `event`, `source`, `parent`, `trace`. |
| `content` | object | The event payload. See the table below. |
| `emitted_at` | string | RFC 3339 UTC timestamp of the event. |

The transport fields the webhook document carries — `url`, `secret`,
`headers` — never appear in the body.

### The `content` field per event family

| Event family | `content` holds |
| --- | --- |
| Document mutations: `created`, `updated`, `deleted`, a named action, `migrated`, `rolled_back` | `{ "id": "<doc_id>" }` — a document-id frame, not a document body. Fetch the document through the API when you need its content. |
| `child_changed` | `{ "id", "action", "child": {"doc_type", "doc_id"}, "parent": {"doc_type", "doc_id"} }` — the parent aggregate's change frame. |
| `notified` | `{ "id", "notification": { ... } }` — the notification record: `notification_id`, `account_id`, `kind`, `title`, `body`, `data`, `actions`, `created_at`, and the document pointers. |
| Job lifecycle: `export_completed`, `export_failed`, `import_completed`, `import_failed`, and the four `domain_*` names | `{ "id": "<job_id>", "export" \| "import": { ... } }` — the job report: counts such as `row_count`, `created`, `updated`, `skipped`, plus `artifact_id` and `format` where they apply. |

### Event names

A webhook binds to one source doctype and to a list of event names.

- **Omitting the `events` list** fires on the standard events.
- **Setting an empty list** fires on nothing.

| Name | Fires for | Opt-in |
| --- | --- | --- |
| `created`, `updated`, `deleted` | Document mutations of the source doctype. | no |
| `migrated`, `rolled_back` | Lazy-migration replays and rollback restores. | no |
| Named action names | One event per executed action. The event name is the action key in past tense — `approve_document` becomes `document_approved` — or the action's declared `event_name`. | no |
| `notified` | Notification events aimed at one account. | yes |
| `child_changed` | Changes to owned children of the bound aggregate. | yes |
| `export_completed`, `export_failed`, `import_completed`, `import_failed` | Document import/export jobs. | yes |
| `domain_export_completed`, `domain_export_failed`, `domain_import_completed`, `domain_import_failed` | Portable-domain jobs on `core.Domain`. | yes |

An opt-in event fires only when the webhook's `events` list names it. A
webhook without an `events` list never receives one.

## The signature

The signature header is:

```text
X-Facet-Signature: sha256=<lowercase hex of HMAC-SHA256(secret, raw_body)>
```

- The key is the webhook document's `secret` field — a server-generated
  id, stamped at create time and readable by the webhook's author. No
  server-wide signing key exists.
- The message is the raw request body, exactly as the receiver reads it
  from the wire. Do not re-serialise the JSON before verifying.
- The digest is lowercase hexadecimal, 64 characters.

### Verification — Node.js

```js
const crypto = require("crypto");

function verifySignature(rawBody, secret, header) {
  const expected =
    "sha256=" +
    crypto.createHmac("sha256", secret).update(rawBody, "utf8").digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(header);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = { verifySignature };
```

Read `rawBody` from the original request bytes, before any JSON parse
or re-stringify. The length check keeps `timingSafeEqual` from throwing
on a malformed header.

### Verification — openssl

```sh
EXPECTED="sha256=$(printf '%s' "$RAW_BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -hex | sed 's/^.* //')"
[ "$EXPECTED" = "$SIGNATURE_HEADER" ] && echo valid || echo invalid
```

## Delivery and retry behaviour

| Aspect | Behaviour |
| --- | --- |
| Transport timeout | 10 seconds per attempt, connect and read combined. |
| Success | Any `2xx` status. Every other status, including `3xx`, and every transport error count as a failure. |
| Retries | Up to 5 attempts per delivery, with delays of 10, 60, 300, 1800, and 7200 seconds. These are the defaults; the `webhook` config section overrides them. |
| Redirects | Not followed. |
| Duplicate deliveries | Possible. The enqueue path is repaired by a reconciler that can race the live path. |
| Order | Not guaranteed. Use `emitted_at` and `mutation_id` to detect and reorder. |

Receivers must tolerate duplicates and late deliveries. Store the
`delivery_id` of processed deliveries when you need exactly-once
effects on your side.

## Complete example

A webhook on the `accountancy.Contract` doctype delivers:

```json
{
  "webhook_id": "core.Webhook.01JHWK3QZ0M4T7R2V9X6B8ND5P",
  "delivery_id": "01JHWK3R2W5Y8C0F4G7J1M6T9Q",
  "event": "updated",
  "domain": "accountancy",
  "doc_type": "Contract",
  "doc_id": "accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A",
  "mutation_id": "01JHWK3N8A2D6H0M4P9S3V7X1Z",
  "actioner_id": "iam.Account.01JHWK36D9G3K7Q1W5E8R4T2Y0",
  "cause": {
    "kind": "request",
    "trace": "01JHWK3N8A2D6H0M4P9S3V7X1Z"
  },
  "content": {
    "id": "accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A"
  },
  "emitted_at": "2026-11-13T09:30:00Z"
}
```

With the webhook secret `01JHWK3S8X2M5P7R0T3V6Y9B2D`, the signature
header on this body — serialized without whitespace — is:

```text
X-Facet-Signature: sha256=8cce667b2e605b0e4ea17ee9d2ccc0d74464576b5c555810f98eb09d66e03b0c
```

You can reproduce the digest over the same compact form:

```sh
printf '%s' '{"webhook_id":"core.Webhook.01JHWK3QZ0M4T7R2V9X6B8ND5P","delivery_id":"01JHWK3R2W5Y8C0F4G7J1M6T9Q","event":"updated","domain":"accountancy","doc_type":"Contract","doc_id":"accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A","mutation_id":"01JHWK3N8A2D6H0M4P9S3V7X1Z","actioner_id":"iam.Account.01JHWK36D9G3K7Q1W5E8R4T2Y0","cause":{"kind":"request","trace":"01JHWK3N8A2D6H0M4P9S3V7X1Z"},"content":{"id":"accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A"},"emitted_at":"2026-11-13T09:30:00Z"}' \
  | openssl dgst -sha256 -hmac "01JHWK3S8X2M5P7R0T3V6Y9B2D" -hex | sed 's/^.* //'
```

The command prints
`8cce667b2e605b0e4ea17ee9d2ccc0d74464576b5c555810f98eb09d66e03b0c`.
A real delivery signs the bytes as sent; the example signs the compact
form so you can run it verbatim.

## Related

- [Outbound webhooks](/build/model/automation/webhooks/) — register and manage webhooks.
- [Event hooks](/build/model/automation/event-hooks/) — run Lua inside Facet instead of calling out.
