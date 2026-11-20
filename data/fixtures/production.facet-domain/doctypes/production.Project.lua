-- production.Project lifecycle script.
--
-- Demonstrates the `ctx.actor` RBAC surface in the `create` hook. When the
-- caller's create permission carries the `mine` named scope (i.e. an
-- `owner_id: $self` permission line), the hook forces `owner_id` to the
-- caller's account id -- so a scoped creator can only create projects they
-- own.  System-context creates (seeding, migrations) and unrestricted
-- creators are left untouched.
--
-- See doc/backend/lua-engine.md -> "ctx.actor" for the full surface.

local export = {}

function export.create(ctx)
    if ctx.actor == nil then
        -- No auth context (legacy callers / unit tests). Nothing to enforce.
        return
    end

    -- Only the `mine` scope (owner_id: $self) constrains ownership at create
    -- time. Unrestricted creators and system bypass are left alone.
    if ctx.actor.scope == "mine" and ctx.actor.system == false then
        ctx.root.owner_id = ctx.actor.id
    end
end

return export
