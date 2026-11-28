---
type: how-to
title: Scripts and guards
description: Run Lua guards and hooks on create, update, delete, and actions to enforce your rules.
audience: [author]
features: [DOM-08]
sidebar:
  order: 1
verified_at: eee55a2
---

A date that must not slip into the future, an owner forced from the
caller, a record that closes for edits in one state — a **lifecycle
script** covers rules like these. It runs inside every write to a doctype:
it can check the document and refuse the write, or fill and correct fields
before Facet stores them. You need Lua for this page; the ten-line module
pattern is all you need to start, and the full function surface sits in
the [Lua API reference](/reference/lua-api/). The script is part of the
doctype definition, so your rules travel with the model and apply on every
path — the app, the API, and agents.

## When to use this

Add a script when a rule exceeds what field constraints express: a date that
must not lie in the future, an owner forced from the caller, a record that
closes for edits in one state. Keep simple format rules in field
constraints, and row rights in roles.

## Before you start

- **[Lua](/reference/lua-api/).** The script follows one module pattern: it defines functions and
  returns them in a table.
- **A compiling script.** A syntax error fails when you save the doctype:
  Facet compiles the script at save time and reports the line.
- **No secret values.** A script never sees secret values; a `secret` field
  carries only its marker here.

## The hooks

| Function | Runs | May |
| --- | --- | --- |
| `export.validate(ctx)` | Before every create, update, delete, and action | Check and refuse with `ctx.error` |
| `export.create(ctx)` | Once, on create | Check, refuse, and change `ctx.root` |
| `export.update(ctx)` | On every update | Check, refuse, and change `ctx.root` |
| `export.delete(ctx)` | On delete | Check and refuse |
| `export.<action>(ctx, args)` | On a named action, then `update` runs | Check, refuse, and change `ctx.root` |

`validate` runs before the other hooks on every path, so one place covers
every door. After an action, `update` runs again against the final state,
with `ctx.changed` naming the fields the action set.

Every function receives one context table. The members you use most:

| Member | Meaning |
| --- | --- |
| `ctx.root` | The document content. Change it in place. |
| `ctx.patch` | On a plain update: the fields the caller sent. |
| `ctx.changed` | On an action-driven update: the fields the action set. |
| `ctx.action` | The action name during an action run; absent on a plain update. |
| `ctx.error(msg)` | Collects a refusal. The write then fails with `422`. |
| `ctx.now` | The current UTC time, as ISO 8601 text. |
| `ctx.actor` | The caller: `id`, `role_id`, `scope`, `system`. Absent for system runs; check `ctx.actor == nil` first. |

One shape rule matters: on an update, `ctx.root` is the **merged** document
— the current content with the patch already applied. A guard that must
compare old and new reads the caller's fields from `ctx.patch` (or
`ctx.changed`), not from a stored copy. The update hook cannot see the state
before the patch.

## Write the guard

Put every refusal into `validate` — it runs first, so one place covers every
path. A rule that compares the caller's change with the stored state lives
in `update`, reading the change from `ctx.patch`. The Brightwater booking
script locks the dates of a confirmed booking:

```lua
-- rentals.Booking.lua — the guard, complete
function export.update(ctx)
    if ctx.action ~= nil then
        return
    end
    if ctx.patch == nil then
        return
    end
    if ctx.patch.dates ~= nil and ctx.root.status == "confirmed" then
        ctx.error("A confirmed booking's dates are locked. Return the booking first.")
    end
end
```

The first two checks matter. `ctx.action` is set while an action runs, and
the guard must not refuse the **confirm** action that legitimately sets new
state. `ctx.patch` is absent when no patch drove the update.

## Write the hooks and actions

Mutate `ctx.root` for the corrections your model needs, and refuse with
`ctx.error` when a state is wrong. The same script can carry actions — see
[Add actions to a doctype](/build/model/behaviour/named-actions/). One
recipe covers a common case: force the owner from the caller's permission
scope.

```lua
-- Create hook: force the owner for callers scoped to their own records.
function export.create(ctx)
  if ctx.actor == nil then return end
  if ctx.actor.scope == "mine" and ctx.actor.system == false then
    ctx.root.owner_id = ctx.actor.id
  end
end
```

## Attach the script

The definition carries the source in its `script` field. In the doctype
editor you edit the script directly; Facet compiles it on save and reports
errors with line numbers. In files, the script sits beside the doctype's
YAML as a `.lua` file that the definition reads with `!read_file`:

```yaml
# rentals.Booking.yml
script: !read_file rentals.Booking.lua
```

A refused write answers `422` and carries your message. Nothing is stored.

## Troubleshooting

**Every write answers `422` with a script error.**

The script raised an error outside your `ctx.error` calls. The message
names the line. A common cause is a nil field: check before you compare.

**The write answers with the instruction limit.**

The script ran too long, most often in an unbounded loop. Facet stops a
script at 1 million instructions, 0.5 seconds, or 32 megabytes of memory,
whichever comes first.

**My fix did not take effect at once.**

The definition cache updates a second or two after you save the doctype.
Re-test after a short wait.

**The script must change another document.**

Use the `document.*` helpers: `document.create`, `document.get`,
`document.update`, `document.delete`, and `document.list`. They run in hooks
and actions, and stay inside the same domain — writes cannot cross domains.
Wrap a call in `pcall` when a failure is acceptable. A computed field may
not write at all.

## Related

- [Lua API](/reference/lua-api/) — the full script surface, helpers, and limits.
- [Add actions to a doctype](/build/model/behaviour/named-actions/) — the action half of the same script.
- [The mutation log](/admin/under-the-hood/change-log/) — where a refused or accepted write is recorded.
- [Computed fields](/build/model/data/computed-fields/) — derive field values automatically.
