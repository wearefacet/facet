---
title: Event and schedule hooks
description: Run Lua scripts automatically when documents change or on a schedule.
audience: [author]
features: [AUT-02, AUT-08]
sidebar:
  order: 22
verified_at: fd345fe3
---

A domain can carry its own automation. An **event hook** runs a Lua script when a document somewhere changes. A **schedule hook** runs one on a cron schedule. Hooks live on the domain document, so they move with the domain when you publish or export it.

## When to use this

- Every new contract on hold should alert a reviewer.
- A roll-up job should run every night.
- A script should react to another domain's changes, the granted way.

## Before you start

- **The domain document.** You update the domain document to declare hooks.
- **The event names.** Know the event names you care about: `created`, `updated`, `deleted`, and the rest of the mutation vocabulary.
- **The right tool.** Hooks run inside Facet. To call an outside system, use a webhook instead. See [Outbound webhooks](/build/webhooks/).

## Steps

### 1. Write the hook entry

Add an entry to the `hooks` array of the domain document. An event hook names a source and carries a script:

```json
{
  "id": "alert-on-hold",
  "kind": "event",
  "source": { "domain": "accountancy", "doc_type": "Contract", "events": ["created"] },
  "script": "local export = {}\n\nfunction export.on_event(ctx)\n  if ctx.event.content.status == \"on_hold\" then\n    ctx.error(\"Contract \" .. ctx.event.doc_id .. \" entered on-hold\")\n  end\nend\n\nreturn export"
}
```

| Part | Meaning |
| --- | --- |
| `id` | Unique within the domain. |
| `source.domain` | Required. The domain to watch. |
| `source.doc_type` | Optional. Without it, the hook watches every doctype of that domain. |
| `source.events` | Optional. Without it, the hook fires on every event. |

### 2. Know the script surface

The `script` value is Lua text. It returns a table with `on_event` (event hooks) or `on_schedule` (schedule hooks), as in the entry above.

Inside the script you can read and write documents with `document.get`, `document.list`, `document.create`, and `document.update`, and you can notify people with `notification.send`. Writes from hooks are marked as automated, so a hook that writes what it watches cannot loop.

### 3. Add a schedule hook

A schedule hook trades the source for a cron expression: five numeric fields, in UTC, with `/` steps allowed. Macros such as `@daily` and the seconds field are refused. The Example below shows a complete schedule entry.

### 4. Save and watch it run

Facet compiles each script when you save the domain. A script that does not compile, or lacks the right function, is refused. An edit takes effect on the next event or tick, without a restart.

:::caution
Delivery is at-most-once. A server fault during a hook drops that fire; nothing retries it. Write hooks that tolerate a miss, or run a schedule hook that re-checks state.
:::

## Example

A roll-up that counts active contracts each night into a `Dashboard` document of the own domain. Declare the hook with `kind: "schedule"` and `schedule: "0 3 * * *"`. The `script` value is the text below:

```lua
local export = {}

function export.on_schedule(ctx)
  local ok, result = pcall(document.list, "Contract", { status = "active" })
  if not ok then
    ctx.error("roll-up failed: " .. tostring(result))
    return
  end
  local ok2, doc = pcall(document.get, "Dashboard", "01JD5R6Y8K31N4TQZ9W2B5XDEF")
  if not ok2 then
    ctx.error("dashboard row missing: " .. tostring(doc))
    return
  end
  local body = util.json_decode(doc.content)
  body.open_contracts = result.total
  document.update("Dashboard", "01JD5R6Y8K31N4TQZ9W2B5XDEF", body)
end

return export
```

The schedule `"0 3 * * *"` runs it at 03:00 UTC every day. The reads and writes stay inside the owning domain, so no grant is needed.

:::note
A hook on a foreign source fires only when an active grant admits the owning domain, and the script then sees only the granted fields.
:::

## Troubleshooting

**The hook never fires.**

Check the source: the domain must be live, the doctype must exist, and a foreign source needs an active grant. A brand-new hook also starts at the present moment; it does not replay past events.

**The script fails at runtime.**

The fire logs the error and moves on. Fix the script and save the domain again; nothing retries the missed fire.

**My schedule did not run during an outage.**

A missed tick is lost. The next due time runs normally.

## Related

- [Lua API reference](/reference/lua-api/) — every global a hook script may call.
- [Event delivery](/concepts/events-delivery/) — how change events travel.
- [Outbound webhooks](/build/webhooks/) — call an outside system on the same events.
