---
type: how-to
title: Named actions
description: Add named actions with typed arguments and a Lua implementation to a doctype.
audience: [author]
features: [DOM-07]
sidebar:
  order: 0
verified_at: fd345fe3
---

A named action is an operation with a name, such as `promote` or `release`. The user runs it from the document page menu, Facet checks the typed arguments, and a Lua function in the doctype script does the work. An action lands in the history as the changes it made, next to plain edits.

## When to use this

Add an action when a change needs more than an edit: a state rule, several fields moved together, or a value derived from arguments. If the rule only checks one field, a `pattern` or a lifecycle guard is simpler (see [Lifecycle scripts and guards](/build/model/behaviour/scripts-and-guards/)).

## Before you start

- **A script.** A doctype that declares actions must carry a script, and the script must define one function per action.
- **A permission.** Users need a permission whose action name equals the action key, for example `promote` on `hr.Employee`.
- **A free name.** `validate`, `create`, and `update` are reserved names; they belong to the lifecycle.

## Steps

### 1. Declare the action

```json
"actions": {
  "release": {
    "description": "Release the order to production",
    "states": { "status": ["approved"] },
    "args": {
      "note": { "type": "string", "required": true, "max": 200 }
    }
  }
}
```

| Key | Purpose |
| --- | --- |
| `args` | Typed arguments. Facet checks type, `required`, `min`/`max`, `default`, and a closed `values` list before the script runs. |
| `states` | The field values the document must carry before the action is offered. An action without `states` is always offered. |
| `description` | The text the action editor shows. |

### 2. Implement the function

The script exports one function per action. It receives the context `ctx` and the checked arguments `args`, and it changes the document by writing to `ctx.root`.

### 3. Grant the permission

Add a permission line with the action name to a role:

```json
{ "action": "release", "on": "projects.Order" }
```

Without the line, the menu entry stays hidden and a direct call answers `403`.

### 4. Run the action

In the app, open a document and pick the action from its menu. Facet checks the arguments, runs the script, and shows the result.

## Example

The complete script below implements `release`. It re-checks the state rule, sets three fields, and stamps the time.

```lua
local export = {}

function export.release(ctx, args)
  if ctx.root.status ~= "approved" then
    ctx.error("Only approved orders can be released")
    return
  end
  ctx.root.status = "released"
  ctx.root.released_at = ctx.now
  ctx.root.release_note = args.note
end

return export
```

The call runs the action on one document:

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Order/01HQ2F5WX8K4M3PZC6NRB9TJVA/release" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"note": "Budget confirmed"}'
```

`-k` skips the certificate check of the local development address. Facet stores one history entry with the fields the action changed.

## Troubleshooting

### The menu entry does not show

The document state does not match the `states` gate, or your role lacks the action permission.

### The call answers `422` with an argument error

An argument is missing, out of range, or outside a closed `values` list. The message names the argument.

### The call answers `422` with a script error

The Lua function raised an error it did not catch. The message carries the line number in your script. Fix the script and save the doctype; the definition cache updates a second or two later.

### The action ran but nothing changed

The function returned without changing `ctx.root`. Facet stores no history entry when an action changes nothing.

## Related

- [Lua API (reference)](/reference/lua-api/) — the full script surface.
- [The mutation log](/admin/under-the-hood/change-log/) — how an action lands in the history.
- [Lifecycle scripts and guards](/build/model/behaviour/scripts-and-guards/) — guard writes with Lua hooks.
