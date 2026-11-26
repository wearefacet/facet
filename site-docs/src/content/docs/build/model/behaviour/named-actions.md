---
type: how-to
title: Add actions to a doctype
description: Add named actions with typed arguments and a Lua implementation to a doctype.
audience: [author]
features: [DOM-07]
sidebar:
  order: 0
verified_at: eee55a2
---

A warehouse team should move a broken item to repair with one click, not by
editing a status field by hand. A **named action** is an operation with a
name, such as `confirm` or `send_to_repair`. The user runs it from the
document page menu, Facet checks the typed arguments, and a Lua function in
the doctype script does the work. You need Lua for the function body — a
ten-line primer is enough, and the full surface sits in the [Lua API
reference](/reference/lua-api/).

## When to use this

Add an action when a change needs more than an edit: a state rule, several
fields moved together, or a value derived from arguments. If the rule only
checks one field, a field constraint or a lifecycle guard is simpler — see
[Scripts and guards](/build/model/behaviour/scripts-and-guards/).

## Before you start

- **A script.** A doctype that declares actions must carry a script, and the
  [script](/build/model/behaviour/scripts-and-guards/) must define one function per action.
- **A permission.** Users need a permission whose action name equals the
  action key, for example `send_to_repair` on `equipment.Item`.
- **A free name.** Eight names are reserved for the lifecycle: `validate`,
  `create`, `update`, `delete`, `migrate`, `snapshot`, `history`,
  `rollback`. An action cannot take one of them.

## Declare the action

Add the action to the doctype's `actions` map:

```yaml
# equipment.Item definition
actions:
  send_to_repair:
    args: {}
```

An action definition carries these keys:

| Key | Purpose |
| --- | --- |
| `args` | Typed arguments. Facet checks `type`, `required`, `default`, `min`/`max`, a closed `values` list, and `collection` before the script runs. |
| `states` | The field values the document must carry before the action is offered. An action without `states` is always offered. |
| `description` | The text the action editor shows. |
| `event_name` | The event the action emits. The default is the past-tense form of the action key. |

Every argument carries a type. A `required` argument answers `422` when it
is missing; `min`/`max` bound numbers (and string lengths); `values` closes
the choice to a list; `collection: true` makes the argument an array and
checks each element. A reference argument arrives in the script already
qualified, as `equipment.Item.<id>`.

The `states` gate keeps the menu honest. To offer **Send to repair** only
when the item is not already in repair:

```yaml
actions:
  send_to_repair:
    states:
      status: [available, out]
    args: {}
```

A document outside those states answers `422` before the script runs, and
the document page hides the menu entry on the same rule.

## Implement the function

The script exports one function per action. It receives the context `ctx`
and the checked arguments `args`, and it changes the document by writing to
`ctx.root`. The Brightwater item script is complete:

```lua
-- equipment.Item.lua
local export = {}

-- Named action: send the item to repair.
-- Only an item that is not already in repair can move there.
function export.send_to_repair(ctx, args)
    if ctx.root.status == "in_repair" then
        ctx.error("Item is already in repair")
        return
    end
    ctx.root.status = "in_repair"
end

return export
```

`ctx.error` collects a refusal: the write fails with `422` and carries your
message.

## Grant the permission

Add a permission line with the action name to a role:

```json
{ "action": "send_to_repair", "on": "equipment.Item" }
```

Without the line, the menu entry stays hidden and a direct call answers
`403`. Who holds which line is an administrator's job — see [Roles and
permissions](/admin/people/roles-and-permissions/).

## Run the action

In the app, open a document and pick the action from its menu. Facet checks
the arguments, runs the script, and shows the result. The same call works
over the API:

```sh
curl -k -X POST "https://facet.localhost:3443/Api/equipment/Item/EQ-2026-0001/send_to_repair" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

`-k` skips the certificate check of the local development address. The item
then shows **In repair** everywhere. Facet stores one history entry with the
fields the action changed.

Events travel with actions. The Brightwater booking declares its two
actions with explicit event names, and the equipment domain's hook listens
for exactly those names:

```yaml
# rentals.Booking definition
actions:
  confirm:
    args: {}
    event_name: booking_confirmed
  mark_returned:
    args: {}
    event_name: booking_returned
```

Without an override, Facet derives the event name from the action key. See
[React to events and schedules](/build/model/automation/event-hooks/) for
the hook that consumes them.

## Troubleshooting

**The menu entry does not show.**

The document state does not match the `states` gate, or your role lacks the
action permission.

**The call answers `422` with an argument error.**

An argument is missing, out of range, or outside a closed `values` list.
The message names the argument.

**The call answers `422` with a script error.**

The Lua function raised an error it did not catch. The message carries the
line number in your script. Fix the script and save the doctype; the
definition cache updates a second or two later.

**The action ran but nothing changed.**

The function returned without changing `ctx.root`. Facet stores no history
entry when an action changes nothing.

## Related

- [Lua API](/reference/lua-api/) — the full script surface.
- [Scripts and guards](/build/model/behaviour/scripts-and-guards/) — guard writes with Lua hooks.
- [The mutation log](/admin/under-the-hood/change-log/) — how an action lands in the history.
