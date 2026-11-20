---
title: Lifecycle Scripts
description: Lua module pattern, ctx table, create/update/delete hooks, named actions, computed fields, migration functions, fixture-derived patterns.
tags: [lua, scripts, lifecycle]
---

# Lifecycle Scripts

A doctype definition may carry a `script` field — the source of a Lua module. The module pattern is mandatory:

```lua
local export = {}

function export.create(ctx)
  ctx.root.created_by = ctx.actor_id
  ctx.root.created_at = ctx.now
end

return export
```

## The `ctx` table

| Field | Description |
|---|---|
| `ctx.root` | The document content. Mutations here are persisted as the final content. |
| `ctx.error(msg)` | Collects a validation error. The list of error strings is returned to the caller as a 422. |
| `ctx.actor_id` | The actioner's account id (e.g. `system:assistant`). |
| `ctx.now` | Current ISO-8601 timestamp string. |
| `ctx.doc_id` | The current document's id (update, delete, action contexts). |
| `ctx.get_children(name)` | Lists child document ids by relationship name (create, update, delete, action). |
| `ctx.actor` | Read-only RBAC surface for the caller (create, update, delete, action). See read_skill("lua-actor"). |

## Date and period helpers

The `date.*` globals cover date arithmetic, boundaries, components, and range checks. All math runs in Crystal, in UTC. Use them instead of hand-rolling calendars in Lua — the sandbox has no `os` library, and month lengths, leap years, and weekdays are not expressible in Lua patterns.

Values stay strings: a calendar date is `YYYY-MM-DD`, a datetime is UTC RFC-3339. Every function takes either form and preserves it — date in gives date out, datetime in gives datetime out. Bad input (unparseable value, unknown unit, wrong argument kind) raises a catchable Lua error; wrap user-controlled values in `pcall` when needed.

| Function | Returns | Description |
|---|---|---|
| `date.now()` | string | Current UTC time |
| `date.today()` | string | Current UTC calendar date, `YYYY-MM-DD` — the server's "today", not the caller's local day |
| `date.diff(a, b, unit)` | number | Signed distance. Elapsed units — `second`, `minute`, `hour`, `day`, `week` — are fractional physical spans (Jul 27 → Aug 6 is 10 days). Calendar units — `month`, `year` — are whole numbers counting calendar positions (Jul 27 → Aug 6 is 1 month, Jan 1 → Jan 31 is 0 months) |
| `date.add(iso, n, unit)` | string | Adds `n` units; negative subtracts. `month`/`year` clamp the day (Jan 31 + 1 month = Feb 28) and need a whole `n`; sub-day units need a datetime |
| `date.start_of(iso, unit)` | string | First day/instant of `unit`: `day`, `week` (Monday), `month`, `quarter`, `year` |
| `date.end_of(iso, unit)` | string | Last day (dates) or last whole second (datetimes) of `unit` |
| `date.parts(iso)` | table | `{year, month, day, hour, minute, second, weekday}`; `weekday` ISO-8601, Monday = 1 |
| `date.period_overlaps(a, b)` | boolean | Two `{start, end}` datetime ranges share an instant; touching ranges do not overlap (`[)` bounds) |
| `date.period_contains(p, x)` | boolean | `x` inside the range: start included, end excluded |
| `date.dateperiod_overlaps(a, b)` | boolean | Calendar-date ranges; touching ranges DO overlap (inclusive bounds) |
| `date.dateperiod_contains(p, x)` | boolean | Calendar-date range, inclusive both ends; a datetime `x` uses its UTC date |

```lua
-- due date = today + 30 days (a `date` field stays a calendar date)
function export.create(ctx)
    ctx.root.due_date = date.add(date.today(), 30, "day")
end

-- billing month key from a datetime field
function export.compute_billing_month(ctx)
    if not ctx.root.created_at then return nil end
    local p = date.parts(ctx.root.created_at)
    return string.format("%04d-%02d", p.year, p.month)
end

-- two `period` fields must not overlap (touching is allowed — [) bounds)
function export.validate(ctx)
    local a = {start = ctx.root.window_start, ["end"] = ctx.root.window_end}
    local b = {start = ctx.root.maintenance_start, ["end"] = ctx.root.maintenance_end}
    if date.period_overlaps(a, b) then
        ctx.error("the booking window overlaps the maintenance window")
    end
end
```

Period bounds read through `p["end"]` — `end` is a Lua keyword. Range checks take the stored `{start, end}` shape as read from `ctx.root`.

## Lifecycle hooks

- `create(ctx)` — runs after validation, before persistence. Mutations to `ctx.root` become the persisted document.
- `update(ctx)` — runs after validation. Mutations to `ctx.root` are diffed against the original and persisted as an update mutation.
- `delete(ctx)` — cleanup hook before the tombstone is inserted. Cannot mutate the deleted document.
- All three are optional — if absent from the export table, no Lua code runs.

## Validation hook

`validate(ctx)` is a regular lifecycle hook called during create and update. Use it for cross-field rules that the schema cannot express:

```lua
-- From data/fixtures/hr.Employee/script.lua
function export.validate(ctx)
    -- Reject future hire_date
    if ctx.root.hire_date and ctx.root.hire_date > ctx.now then
        ctx.error("hire_date cannot be in the future")
    end

    -- Reject manager reference set to self. Reference values are fully
    -- qualified `{domain}.{Doctype}.{id}` strings, so compare the id
    -- segment (everything after the second dot).
    if ctx.root.manager and ctx.root.person then
        local function ref_id(v)
            local first = v:find("%.")
            if not first then return v end
            local second = v:find("%.", first + 1)
            if not second then return v end
            return v:sub(second + 1)
        end
        if ref_id(ctx.root.manager) == ref_id(ctx.root.person) then
            ctx.error("manager cannot reference self")
        end
    end
end
```

The `ref_id` helper pattern — split only on the first two dots — is the canonical way to compare qualified reference values in Lua.

## Named actions

Actions declared on the doctype definition are matched against the Lua export. If `actions: {promote: {}}` is declared, `export.promote(ctx, args)` must exist. `ScriptValidator` rejects a doctype definition with a missing action function.

Follow the guard-then-act structure from the fixtures: guard with `ctx.error(...)` + `return` first, then mutate `ctx.root` last:

```lua
-- From data/fixtures/crm.Deal/script.lua
function export.move_stage(ctx, args)
    if ctx.root.stage_id == args.target_stage_id then
        ctx.error("Deal is already in this stage")
        return
    end
    ctx.root.stage_id = args.target_stage_id
end
```

Action arguments are preflight-validated against `args` before the function runs; the script can still guard on document state (`status`, `type`, ...) with `ctx.error`.

## Computed fields

For every `data` field with `compute: <suffix>`, the script must export `export.compute_<suffix>(ctx)`. **The function must RETURN the value** — the returned value is what lands in the field. `ctx.root` is updated between computations so subsequent computes see prior results.

`compute_when` lists the field names whose change triggers recompute. After `update`/`action`, only those fields whose `compute_when` intersects the changed-fields set are recomputed.

```lua
-- From data/fixtures/crm.Company/script.lua
-- Computed field: search_text = name + " " + domain_name
function export.compute_company_search_text(ctx)
    local parts = {}
    if ctx.root.name then
        table.insert(parts, ctx.root.name)
    end
    if ctx.root.domain_name then
        table.insert(parts, ctx.root.domain_name)
    end
    if #parts > 0 then
        return table.concat(parts, " ")
    end
    return nil
end
```

The mutate-only form (`ctx.root.search_text = ...` with no return) also works — a `ctx.root` write to the computed field is honoured when the function returns nil — but the return form is the contract; prefer it.

## Migration functions

`migrations: {"1": "migrate_from_1"}` requires `export.migrate_from_1(ctx)` in the module. Migration functions run at read time when the document's `meta.schema_version` is less than the doctype's current version. The result is persisted as a snapshot mutation so subsequent reads skip migration.

Migration functions receive the same `ctx` table but with `ctx.actor_id` set to `"system:migration"`.

## Inter-document operations

The `document.*` globals (`document.create`, `document.get`, `document.update`, `document.delete`, `document.list`) let a script read and write other documents in the same domain — e.g. the `crm.Deal.win` action converts `Prospect` rows into `Customer` rows. See read_skill("lua-document-helpers") for the full surface and the `pcall` error-handling pattern.

## ScriptValidator requirements

At doctype create/update time, `ScriptValidator` checks:

- The script compiles as a Lua module.
- Every declared action has a matching `export.<name>` function.
- Every `data` field has a matching `export.compute_<suffix>` function.
- Every migration function declared in `migrations` exists in the export table.

In draft mode these checks still apply — they're schema-level, not version-level.
