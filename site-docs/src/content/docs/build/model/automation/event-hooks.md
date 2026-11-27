---
type: how-to
title: React to events and schedules
description: Run Lua event hooks automatically when documents change, and schedule jobs with cron.
audience: [author]
features: [AUT-02, AUT-08, AUT-09]
sidebar:
  order: 0
verified_at: eee55a2
---

When a Brightwater booking is confirmed, its items must leave the warehouse
stock — across the domain boundary, without anyone clicking. You need Lua
for this page; a ten-line primer is enough, and the full surface sits in
the [Lua API reference](/reference/lua-api/). A **hook** is a Lua script
the domain owns that Facet runs automatically: an **event hook** fires when
a document somewhere changes, a **schedule hook** fires on a cron schedule.
Hooks live on the domain document, so they move with the domain when you
publish or export it.

## When to use this

- A state change in one doctype should update documents in another.
- A roll-up or digest should run every night.
- A script should react to another domain's changes, the granted way.

## Before you start

- **The domain document.** You declare hooks by editing the domain's own
  document, not a doctype.
- **The event names.** Know the events you care about: `created`,
  `updated`, `deleted`, and the action events your model emits.
- **The right tool.** Hooks run inside Facet. To call an outside system, use
  a webhook instead — see [Send webhooks](/build/model/automation/webhooks/).

## Where hooks live

A hook is one entry in the `hooks` list of the domain document. The
**Lua script** is a separate value, and the entry points at it. There are
two places to write both.

**In the app.** Open **Configure → Domains**, open the domain, and open the
**Overview** tab. The editor shows the domain's name and description; it
has no field for the `hooks` list. To add a hook there, send a patch that
carries the full list — see the example at the end of this page. The hook
is live as soon as the patch saves; there is no restart.

**In files.** The hook script sits in the domain folder, and `domain.yml`
reads it with a `!read_file` tag:

```text
equipment.facet-domain/
├── domain.yml
└── hooks/
    └── 1-booking-drives-stock.lua
```

```yml
content:
  color: "#0F766E"
  description: Rental equipment — items, categories, and maintenance tickets.
  hooks:
    - id: booking-drives-stock
      kind: event
      source:
        domain: rentals
        doc_type: Booking
        events:
          - booking_confirmed
          - booking_returned
      script: !read_file hooks/1-booking-drives-stock.lua
meta: {}
```

The file name is free. An export names each script `{i}-{hook_id}.lua`,
where `{i}` is the hook's position in the list. The dev watcher applies
the folder on the next save — see [The domain
watcher](/build/model/in-files/domain-watcher/).

## Declare an event hook

An event hook names a source and a script. Add one entry to the `hooks`
list:

```json
{
  "id": "alert-on-hold",
  "kind": "event",
  "source": { "domain": "accountancy", "doc_type": "Contract", "events": ["created"] },
  "script": "…"
}
```

| Part | Meaning |
| --- | --- |
| `id` | Required. Unique within the domain. |
| `kind` | Required. `event` for a hook on changes, `schedule` for a cron hook. |
| `source.domain` | Required. The domain to watch. |
| `source.doc_type` | Optional. Without it, the hook watches every doctype of that domain. |
| `source.events` | Optional. Without it, the hook fires on every event. |
| `script` | Required. The Lua text, or `!read_file` in files mode. |

The `script` value holds the script text itself, not a path. In files mode
only, `!read_file` reads the text from the named file. Do not paste the Lua
into a one-line JSON string: keep it in its own `.lua` file and point
`script` at it, as above.

## Write the script

The script is a Lua module. It returns a table that carries `on_event`
for an event hook, or `on_schedule` for a schedule hook. A script that
lacks that function is refused when you save.

```lua
local export = {}

function export.on_event(ctx)
  if ctx.event.content.status == "on_hold" then
    ctx.error("Contract " .. ctx.event.doc_id .. " entered on-hold")
  end
end

return export
```

Inside the script you read and write documents with the `document.*`
helpers, and you notify people with `notification.send`. The full surface
sits in the [Lua API reference](/reference/lua-api/).

An event hook receives the change in `ctx.event`. The members are:

| Member | Meaning |
| --- | --- |
| `ctx.event.domain`, `ctx.event.doc_type`, `ctx.event.doc_id` | Which document changed. |
| `ctx.event.event` | The event name. |
| `ctx.event.content` | The document's field values, as a Lua table. It is empty when the document was deleted. |
| `ctx.error(msg)` | Collects an error for the log. |
| `ctx.now` | The current UTC time, as ISO 8601 text. |

One event carries a different shape: an aggregate `child_changed` frame
ships an envelope — the parent's id, the action, and pointers to the child
and the parent — not the child's field values. A hook that needs the child
body fetches it with `document.get`.

Writes from hooks are marked as automated, so a hook that writes what it
watches cannot loop. A hook on a **foreign** source fires only when an
active grant admits the owning domain, and the script then sees only the
granted fields — the same-domain fields stay complete.

## Add a schedule hook

A schedule hook trades the source for a cron expression: five numeric
fields, in UTC, with `/` steps allowed. Macros such as `@daily` and the
seconds field are refused. Each fire runs once per cluster, even on a
multi-server installation.

```json
{ "id": "morning-digest", "kind": "schedule", "schedule": "0 6 * * *", "script": "…" }
```

The script exports `on_schedule` instead of `on_event`. The example below
shows a complete one.

## Save and watch it run

Facet compiles each script when you save the domain. A script that does not
compile, or lacks the right function, is refused. An edit takes effect on
the next event or tick, without a restart.

Read the server log to see a fire. Each `ctx.error` call writes one line
with the message; the change that triggered the hook still saves.

## Delivery, stated honestly

Event delivery is **at-most-once, by decision**. PostgreSQL keeps the
durable state; the event bus is a reaction path, not a ledger. A server
fault during a hook fire drops that one fire: Facet logs it and counts it on
the `GET /Healthcheck` endpoint under `event_loss`. Nothing retries it.
Write hooks that tolerate a miss — re-check state on the next event, or run
a schedule hook that re-reads the world. The full contract sits in [Events
and delivery guarantees](/admin/under-the-hood/events-and-delivery/).

Two more edges follow from the same decision. A brand-new hook starts at
the present moment: it does not replay past events. And a domain that gains
its first hook after a server boot connects within seconds; events fired in
that short window are not delivered to it.

## Example

The Brightwater equipment domain carries this hook, complete and running
on the example instance. First the script, then the declaration that
points at it:

```lua
-- booking-drives-stock — equipment domain hook
-- Fires when a Booking in the rentals domain is confirmed or returned. A
-- confirmed booking marks its items out; a returned booking brings them
-- back. The cross-domain read of the booking's lines needs an active grant
-- from rentals to equipment.
local export = {}

function export.on_event(ctx)
    local ev = ctx.event
    if ev.doc_type ~= "Booking" then
        return
    end
    local status = ev.content and ev.content.status
    if status ~= "confirmed" and status ~= "returned" then
        return
    end

    local target = status == "confirmed" and "out" or "available"

    -- List the booking's lines across the domain boundary. Without an
    -- active grant this raises; the pcall turns it into a collected error.
    local ok, result = pcall(document.list, "rentals.BookingLine", { parent_id__eq = ev.doc_id })
    if not ok then
        ctx.error("Could not read the booking's lines: " .. tostring(result))
        return
    end

    for _, line in ipairs(result.items or {}) do
        local content = util.json_decode(line.content or "{}")
        local ref = content.item
        if ref then
            -- The reference stores the qualified form equipment.Item.<id>;
            -- the read and the write want the bare id.
            local item_id = string.match(ref, "([^%.]+)$")
            -- Read the item's current state first. An item in repair cannot
            -- go out on a booking: collect the refusal and leave that item
            -- in repair — the rest of the booking still goes out.
            local ok_item, proj = pcall(document.get, "Item", item_id)
            if not ok_item then
                ctx.error("Item " .. tostring(ref) .. ": " .. tostring(proj))
            else
                local item = util.json_decode(proj.content or "{}")
                if target == "out" and item.status == "in_repair" then
                    ctx.error("Item " .. tostring(ref) .. " is in repair and cannot be booked out")
                else
                    local done, err = pcall(document.update, "Item", item_id, { status = target })
                    if not done then
                        ctx.error("Item " .. tostring(ref) .. ": " .. tostring(err))
                    end
                end
            end
        end
    end
end

return export
```

In files, the script sits in `hooks/1-booking-drives-stock.lua`, and
`domain.yml` carries the declaration — the full file is in [Where hooks
live](#where-hooks-live). The declaration names the source and the two
action events:

```yml
hooks:
  - id: booking-drives-stock
    kind: event
    source:
      domain: rentals
      doc_type: Booking
      events:
        - booking_confirmed
        - booking_returned
    script: !read_file hooks/1-booking-drives-stock.lua
```

To send the same declaration from the app, PATCH the domain document with
the list in `content.hooks`:

```sh
curl -X PATCH "$(facet-cli host)/Api/core/Domain/equipment" \
  -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{
    "hooks": [{
      "id": "booking-drives-stock",
      "kind": "event",
      "source": {
        "domain": "rentals",
        "doc_type": "Booking",
        "events": ["booking_confirmed", "booking_returned"]
      },
      "script": "local export = {}\n\nfunction export.on_event(ctx)\n  -- …\nend\n\nreturn export"
    }]
  }'
```

The `hooks` key is replaced as a whole: send every hook the domain keeps,
not only the new one.

A schedule hook follows the same shape. A morning digest for the warehouse
lead sends one notification per open ticket, every day at 06:00 UTC:

```lua
local export = {}

function export.on_schedule(ctx)
    local ok, result = pcall(document.list, "MaintenanceTicket",
        { status__in = { "reported", "waiting_parts" } })
    if not ok then
        ctx.error("digest failed: " .. tostring(result))
        return
    end
    for _, ticket in ipairs(result.items or {}) do
        local t = util.json_decode(ticket.content or "{}")
        if t.assignee then
            pcall(notification.send, t.assignee, nil, "ticket_open",
                "Ticket still open: " .. tostring(t.problem))
        end
    end
end

return export
```

```yml
hooks:
  - id: morning-digest
    kind: schedule
    schedule: "0 6 * * *"
    script: !read_file hooks/2-morning-digest.lua
```

The reads stay inside the owning domain, so no grant is needed. See
[Notifications and mentions](/build/model/automation/notifications/) for the
`notification.send` arguments.

## Troubleshooting

**The hook never fires.**

Check the source: the domain must be live, the doctype must exist, and a
foreign source needs an active grant. Check `source.events` too — an event
name the source never emits matches nothing. A brand-new hook also starts
at the present moment; it does not replay past events.

**The save is refused with a hook error.**

The message names the hook and the field. The usual causes: a missing
`kind`, an empty `script`, a script that does not return a table, a script
without `on_event` (or `on_schedule` for a schedule hook), a duplicate
`id`, or a cron expression with a macro or a seconds field.

**The script fails at runtime.**

The fire logs the error and moves on. Fix the script and save the domain
again; nothing retries the missed fire.

**My schedule did not run during an outage.**

A missed tick is lost. The next due time runs normally.

## Related

- [Lua API](/reference/lua-api/) — every global a hook script may call.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the full delivery contract.
- [Send webhooks](/build/model/automation/webhooks/) — call an outside system on the same events.
