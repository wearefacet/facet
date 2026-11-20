---
title: Lifecycle scripts and guards
description: Run Lua guards and hooks on create, update, delete, and actions to enforce your rules.
audience: [author]
features: [DOM-08]
sidebar:
  order: 11
verified_at: fd345fe3
---

A lifecycle script runs inside every write to a doctype. It can check the document and refuse the write, or fill and correct fields before Facet stores them. The script is part of the doctype definition, so your rules travel with the model and apply on every path: the app, the API, and agents.

## When to use this

Add a script when a rule exceeds what field constraints express: a date that must not lie in the future, an owner forced from the caller, a record that closes for edits in one state. Keep simple format rules in field constraints, and row rights in roles.

## Before you start

- **Lua.** You write Lua. The script follows one module pattern: it defines functions and returns them in a table.
- **A compiling script.** A syntax error fails when you save the doctype: Facet compiles the script at save time.
- **No secret values.** A script never sees secret values; a `secret` field carries only its marker here.

## Steps

### 1. Learn the hooks

| Function | Runs | May |
| --- | --- | --- |
| `export.validate(ctx)` | Before every create, update, delete, and action | Check and refuse with `ctx.error` |
| `export.create(ctx)` | Once, on create | Check, refuse, and change `ctx.root` |
| `export.update(ctx)` | On every update | Check, refuse, and change `ctx.root` |
| `export.delete(ctx)` | On delete | Check and refuse |
| `export.<action>(ctx, args)` | On a named action, then `update` runs | Check, refuse, and change `ctx.root` |

Every function receives one context table. The members you use most:

| Member | Meaning |
| --- | --- |
| `ctx.root` | The document content. Change it in place. |
| `ctx.patch` | On a plain update: the fields the caller sent. |
| `ctx.changed` | On an action: the fields the action set. |
| `ctx.error(msg)` | Collects a refusal. The write then fails with `422`. |
| `ctx.now` | The current UTC time, as ISO 8601 text. |
| `ctx.actor` | The caller: `id`, `role_id`, `scope`, `system`. Absent for system runs; check `ctx.actor == nil` first. |

### 2. Write the guard

Put every refusal into `validate`. It runs before all other hooks, so one place covers every path.

### 3. Write the hooks

Mutate `ctx.root` for the corrections your model needs, and refuse with `ctx.error` when a state is wrong.

### 4. Attach the script

The definition carries the source in its `script` field. In the doctype editor you edit the script directly; Facet compiles it on save and reports the errors with line numbers.

## Example

The complete script below guards an employee record: no future hire dates, an owner forced from the caller's scope, and no edits on a terminated record.

```lua
local export = {}

-- Guard: runs before every create, update, delete, and action.
function export.validate(ctx)
  if ctx.root.hire_date and ctx.root.hire_date > ctx.now then
    ctx.error("hire_date cannot be in the future")
  end
end

-- Create hook: force the owner for callers scoped to their own records.
function export.create(ctx)
  if ctx.actor == nil then return end
  if ctx.actor.scope == "mine" and ctx.actor.system == false then
    ctx.root.owner_id = ctx.actor.id
  end
end

-- Update hook: a terminated record is closed for edits. An action that
-- sets a new state runs first, so a valid re-open action still passes.
function export.update(ctx)
  if ctx.root.status == "terminated" then
    ctx.error("A terminated record is closed for edits")
  end
end

return export
```

A refused write answers `422` and carries your message. Nothing is stored.

## Troubleshooting

### Every write answers `422` with a script error

The script raised an error outside your `ctx.error` calls. The message names the line. A common cause is a nil field: check before you compare, as the example does with `hire_date`.

### The write answers with the instruction limit

The script ran too long, most often in an unbounded loop. Facet stops a script at 1 million instructions, 0.5 seconds, or 32 megabytes of memory, whichever comes first.

### My fix did not take effect at once

The definition cache updates a second or two after you save the doctype. Re-test after a short wait.

### The script must change another document

Use the `document.*` helpers: `document.create`, `document.get`, `document.update`, `document.delete`, and `document.list`. They run in hooks and actions, and stay inside the same domain. Wrap a call in `pcall` when a failure is acceptable. A computed field may not write at all.

## Related

- [Lua API (reference)](/reference/lua-api/) — the full script surface, helpers, and limits.
- [The mutation log](/concepts/mutation-log/) — where a refused or accepted write is recorded.
- [Computed fields](/build/computed-fields/) — derive field values automatically.
