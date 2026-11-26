---
type: how-to
title: Send webhooks
description: Deliver signed change events from a doctype to an outside HTTPS endpoint.
audience: [author, developer]
features: [AUT-03]
sidebar:
  order: 1
verified_at: eee55a2
---

Your billing system needs to know the moment a booking is confirmed, and it
lives outside Facet. A webhook pushes a signed event to your system each
time a document changes: you register a target URL on a source doctype,
choose the events, and Facet delivers every match to your endpoint as an
HTTP POST. This page needs no Lua, but the receiver needs code to verify
the signature.

## When to use this

- An outside system must react within seconds to new or changed documents.
- You feed a data warehouse or a search index from Facet.
- You prefer your own code over scripts inside Facet.

## Before you start

- **A public HTTPS target.** Your target must be an HTTPS URL on a host that
  resolves publicly. An internal receiver a deployment actually wants is
  named on `webhook.allowed_hosts` in the server configuration.
- **The `webhook` channel.** Your role must carry the `webhook`
  [connectivity channel](/admin/people/roles-and-permissions/); a browser-only role cannot author webhooks. The
  **Webhooks** entry appears in the account menu only for roles that hold
  the channel.
- **The page.** Find it under **Settings → Webhooks**. You manage the
  webhooks you created; an administrator sees all.

## Create the webhook

Select **Create webhook** and fill in:

| Field | Meaning |
| --- | --- |
| Label | A name for the list. |
| Target URL | The HTTPS target of the POST. |
| Source doctype | The doctype to watch. |
| Events | Turn **Fire on all events** off to name the ones you want. |
| Custom headers | Optional headers merged into every POST, for receiver-side authentication. |

Facet generates a signing secret and binds the webhook to your account. The
binding is permanent: the webhook stays yours, and the secret, the bound
account, and the bound role cannot be edited afterwards.

The event list is a closed vocabulary: the change verbs (`created`,
`updated`, `deleted`), the repair events (`migrated`, `rolled_back`), and a
set of opt-in events. A match-all webhook never receives an opt-in event —
for example `notified` stays private to its recipient, and `child_changed`
ships an envelope rather than a document body — unless the list names it
explicitly. Named-action events (such as `booking_confirmed`) are dynamic
per doctype: you cannot type them into the list, but a match-all webhook
receives them. An unknown name is rejected when you save, with the allowed
names in the message.

## Verify the signature

Every delivery carries the header `X-Facet-Signature: sha256=<hex>`. The
hex is the HMAC-SHA256 of the exact raw body, keyed with your secret.
Verify it before you trust a payload — this example uses Node.js:

```js
import { createHmac, timingSafeEqual } from 'node:crypto';

export function verify(rawBody, secret, header) {
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex');
  return timingSafeEqual(Buffer.from(expected), Buffer.from(header));
}
```

Read the raw body as text before you parse it, and check against those
exact bytes. The full header table and body grammar live in the [webhook
payload reference](/reference/webhook-payloads/).

## Read the payload

The body is one JSON envelope. The main fields:

| Field | Meaning |
| --- | --- |
| `event` | The event name, for example `created`. |
| `domain`, `doc_type`, `doc_id` | Which document changed. |
| `actioner_id`, `cause` | The account that made the change and its cause trail. |
| `content` | The event payload. A plain document change ships only the id frame `{"id": "<doc_id>"}`, never the document body. Fetch the document through the API when you need its content. An opt-in event that carries more ships it — for example `notified` ships the notification record. |
| `mutation_id`, `emitted_at` | The change identity and its time. |
| `delivery_id` | Unique per delivery. |

Facet adds headers you can route on: `X-Facet-Event`, `X-Facet-Delivery`,
and `X-Facet-Mutation-Id`.

## What delivery guarantees

One plain paragraph, because it matters: the enqueue that hands an event to
the delivery queue can be lost in a rare failure — a publish fault, a
consumer outage, a trimmed stream. A reconcile job repairs that: every hour
it re-runs the enqueue decision from the durable change log for the last
`webhook.reconcile_window_hours` (24 hours by default). Transport after the
enqueue retries on a growing delay, up to five attempts. The two halves
together mean an event can arrive late and, in a race with the repair pass,
twice — never vanish silently inside the window. Make your receiver
idempotent: key on `mutation_id` and `delivery_id`. The pipeline behind
this sits in [Events and delivery
guarantees](/admin/under-the-hood/events-and-delivery/).

## Watch the call log

Open **Calls** on a webhook row. Every attempt is listed with its status
and the receiver's response. A failed call retries with a growing delay —
10 seconds, then 1 minute, 5 minutes, 30 minutes, and 2 hours. Select
**Test** to send one synthetic probe and read the answer as data; the probe
lands in the call log too. You can **Replay** a logged call by hand.

## Pause, do not delete

Toggle **Enabled** off to pause deliveries. Facet keeps the settings, the
secret, and the call log. Deleting removes the target for good — queued
deliveries still run, but nothing new arrives.

## Example

A webhook watches the Brightwater bookings. After Nadia confirms booking
`BK-2026-0001`, Facet POSTs this body to the receiver:

```json
{
  "webhook_id": "core.Webhook.01JCATPMKP4N82GVG2J7K4MHZZ",
  "delivery_id": "01JD5R7X4K92Q8WVBN6P3A1YCD",
  "event": "booking_confirmed",
  "domain": "rentals",
  "doc_type": "Booking",
  "doc_id": "rentals.Booking.BK-2026-0001",
  "mutation_id": "01JD5R6Y8K31N4TQZ9W2B5XDEG",
  "actioner_id": "iam.Account.01JD5R5T2M80K3P7N1Q4S6V9WX",
  "cause": { "kind": "request", "trace": "01JD5R6Y8K31N4TQZ9W2B5XDEG" },
  "content": { "id": "rentals.Booking.BK-2026-0001" },
  "emitted_at": "2026-12-07T09:15:02Z"
}
```

The receiver checks the signature, fetches the booking by `doc_id`, and
answers `200`. Any other answer counts as a failure and starts the retry
ladder.

## Troubleshooting

**Nothing arrives.**

Check, in order: the webhook is enabled; the source doctype matches; the
event is in the list; the bound role can still read the doctype. The call
log shows a skip reason when a gate refuses a delivery.

**The signature never verifies.**

You are hashing the parsed object. Hash the raw request body bytes.

**An internal URL is refused.**

Targets must resolve publicly. An administrator can name internal hosts in
`webhook.allowed_hosts` in the server configuration.

**The same event arrived twice.**

A retry after a timeout, or the repair pass racing a slow enqueue, can
deliver twice. Deduplicate on `mutation_id` and `delivery_id`.

## Related

- [Webhook payloads](/reference/webhook-payloads/) — every field and header.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the event pipeline behind webhooks.
- [React to events and schedules](/build/model/automation/event-hooks/) — run a script inside Facet on the same events.
