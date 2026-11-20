-- core.SystemSettings lifecycle hooks.
--
-- Singleton guards. The settings document is exactly one row whose id
-- (`settings`) the sealed credential slots bind to: a second row would fork
-- the settings surface, and a delete would strand the secret store rows
-- that point at the document. The create hook therefore admits only the
-- seed principal (`system` — the seed pass writes with the system actioner),
-- and the delete hook refuses unconditionally. Updates follow the normal
-- RBAC gate; no update hook exists. The guard-hook precedent is
-- core.DomainEditor.
local export = {}

local SEED_ACTOR = "system"

function export.create(ctx)
    if ctx.actor_id ~= SEED_ACTOR then
        ctx.error("core.SystemSettings is a singleton: only the platform seed may create it")
    end
end

function export.delete(ctx)
    ctx.error("core.SystemSettings cannot be deleted")
end

return export
