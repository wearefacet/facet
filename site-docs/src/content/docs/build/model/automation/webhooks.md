---
type: how-to
title: Outbound webhooks
description: Deliver signed change events from a doctype to an outside HTTPS endpoint.
audience: [author, developer]
features: [AUT-03]
sidebar:
  order: 1
verified_at: f1409cdc
---

A webhook pushes a signed event to your system each time a document changes. You register a target URL on a source doctype, choose the events, and Facet delivers every match to your endpoint as an HTTP POST.

## When to use this

- An outside system must react within seconds to new or changed documents.
- You feed a data warehouse or a search index from Facet.
- You prefer your own code over scripts inside Facet.

## Before you start

- **A public HTTPS target.** Your target must be an HTTPS URL on a host that resolves publicly.
- **The `webhook` channel.** Your role must carry the `webhook` connectivity channel; a browser-only role cannot author webhooks.
- **The page.** Find it under **Settings → Webhooks**. You manage the webhooks you created; an administrator sees all.

## Steps

### 1. Create the webhook

Select **Create webhook** and fill in:

| Field | Meaning |
| --- | --- |
| Label | A name for the list. |
| URL | The HTTPS target of the POST. |
| Source doctype | The doctype to watch. |
| Events | Leave empty for all, or name the ones you want. |

Facet generates a signing secret and binds the webhook to your account. The binding is permanent: the webhook stays yours.

### 2. Verify the signature

Every delivery carries the header `X-Facet-Signature: sha256=<hex>`. The hex is the HMAC-SHA256 of the exact raw body, keyed with your secret. Verify it before you trust a payload — this example uses Node.js:

```js
import { createHmac, timingSafeEqual } from 'node:crypto';

export function verify(rawBody, secret, header) {
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex');
  return timingSafeEqual(Buffer.from(expected), Buffer.from(header));
}
```

Read the raw body as text before you parse it, and check against those exact bytes.

### 3. Read the payload

The body is one JSON envelope. The main fields:

| Field | Meaning |
| --- | --- |
| `event` | The event name, for example `created`. |
| `domain`, `doc_type`, `doc_id` | Which document changed. |
| `actioner_id`, `cause` | The account that made the change and its cause trail. |
| `content` | The event payload. A plain document change ships only the id frame `{"id": "<doc_id>"}`, never the document body. Fetch the document through the API when you need its content. An opt-in event that carries more ships it — for example `child_changed` ships the aggregate envelope, and `notified` ships the notification record. |
| `mutation_id`, `emitted_at` | The change identity and its time. |
| `delivery_id` | Unique per delivery. |

Facet adds headers you can route on: `X-Facet-Event`, `X-Facet-Delivery`, and `X-Facet-Mutation-Id`. See the [webhook payload reference](/reference/webhook-payloads/).

### 4. Watch the call log

Open **Calls** on a webhook row. Every attempt is listed with its status and response. A failed call retries on a growing delay, up to five attempts. Select **Test** to send one synthetic probe and read the answer. You can replay a logged call by hand.

:::caution
Deliveries can repeat. A repair pass re-sends missed events inside a recent window, and retries can double-fire after a timeout. Make your receiver idempotent: key on `mutation_id` and `delivery_id`.
:::

### 5. Disable instead of delete

Toggle **Enabled** off to pause deliveries. Facet keeps the settings, the secret, and the call log.

## Example

A webhook watches `crm.Company` for `created`. Facet POSTs this body to `https://hooks.example.com/facet`:

```json
{
  "webhook_id": "core.Webhook.01JCATPMKP4N82GVG2J7K4MHZZ",
  "delivery_id": "01JD5R7X4K92Q8WVBN6P3A1YCD",
  "event": "created",
  "domain": "crm",
  "doc_type": "Company",
  "doc_id": "crm.Company.01JD5R6Y8K31N4TQZ9W2B5XDEF",
  "mutation_id": "01JD5R6Y8K31N4TQZ9W2B5XDEG",
  "actioner_id": "iam.Account.01JD5R5T2M80K3P7N1Q4S6V9WX",
  "cause": {
    "kind": "request",
    "trace": "01JD5R6Y8K31N4TQZ9W2B5XDEG"
  },
  "content": {
    "id": "crm.Company.01JD5R6Y8K31N4TQZ9W2B5XDEF"
  },
  "emitted_at": "2026-11-13T09:15:02Z"
}
```

The receiver checks the signature, fetches the company by `doc_id`, and answers `200`. Any other answer counts as a failure and starts the retry ladder: 10 seconds, then 1 minute, 5 minutes, 30 minutes, and 2 hours.

## Troubleshooting

**Nothing arrives.**

Check, in order: the webhook is enabled; the source doctype matches; the event is in the list; the bound role can still read the doctype. The call log shows a skip reason when a gate refuses a delivery.

**The signature never verifies.**

You are hashing the parsed object. Hash the raw request body bytes.

**An internal URL is refused.**

Targets must resolve publicly. An administrator can allow named internal hosts in the server configuration.

## Related

- [Webhook payloads reference](/reference/webhook-payloads/) — every field and header.
- [Event delivery](/admin/under-the-hood/events-and-delivery/) — the event pipeline behind webhooks.
- [Event and schedule hooks](/build/model/automation/event-hooks/) — run a script inside Facet on the same events.
