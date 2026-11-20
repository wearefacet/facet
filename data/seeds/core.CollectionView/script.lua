local export = {}

function export.create(ctx)
    if ctx.actor == nil or ctx.actor.system then return end
    if ctx.actor.scope == "mine" then
        local supplied = ctx.root["owner_id"]
        if supplied ~= nil and supplied ~= ctx.actor.id then
            ctx.error(
            "Cannot create a personal view owned by another account. owner_id must be omitted or match your account.")
            return
        end
        ctx.root.owner_id = ctx.actor.id
    elseif ctx.actor.scope == nil then
        -- Unrestricted create: owner_id may be nil (general) or any account (personal).
    else
        ctx.error("Unexpected scope '" .. tostring(ctx.actor.scope) .. "' for CollectionView create.")
    end
end

function export.update(ctx)
    if ctx.actor == nil or ctx.actor.system then return end
    if ctx.doc_id == nil then return end

    -- owner_id is immutable: once a view is general (nil) it stays general,
    -- once personal it stays owned by the original creator. ctx.root is the
    -- patch-merged document, so compare against the persisted original to
    -- detect an attempted scope change.
    local ok, result = pcall(document.get, "CollectionView", ctx.doc_id)
    if not ok or result == nil then return end
    local original = util.json_decode(result.content)
    local original_owner = original["owner_id"]
    local new_owner = ctx.root["owner_id"]
    if original_owner ~= new_owner then
        ctx.error("owner_id is immutable. Create a new view to change general vs personal scope.")
    end
end

return export
