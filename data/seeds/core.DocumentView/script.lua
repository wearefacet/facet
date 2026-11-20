local export = {}

-- The duplicate-kind check is called from create/update hooks only.
-- The validate hook is intentionally omitted since create/update already
-- call it, which would produce duplicate error messages.
function export.create(ctx)
    check_duplicate_kind(ctx)
    check_editor_domain(ctx)
end

function export.update(ctx)
    check_duplicate_kind(ctx)
end

function check_duplicate_kind(ctx)
    local parent = ctx.root["parent_doctype"]
    local kind = ctx.root["kind"]
    if parent == nil or kind == nil then
        return
    end

    local result = document.list("DocumentView", { kind = kind, parent_doctype = parent }, { "id" }, 1, 1000)
    if result == nil or result.items == nil then
        return
    end

    -- Iterate over existing views with the same kind + parent.
    -- ctx.doc_id is set on update/action/delete (the current document's ID).
    -- On create it's nil since the ID hasn't been assigned yet.
    for _, view in ipairs(result.items) do
        if ctx.doc_id == nil or view.id ~= ctx.doc_id then
            ctx.error("Duplicate view kind '" ..
                kind .. "' for doctype '" .. parent .. "'. A doctype cannot have multiple views with the same kind.")
            return
        end
    end
end

-- Domain-editor gate on create: a caller whose matching create permission
-- is scoped to the `domain_editor` named scope may only attach views to
-- doctypes of the domains they edit. Unrestricted callers (admin, blanket
-- roles — `ctx.actor.scopes` absent) and system writers (seeding, publish,
-- structure copy — `ctx.actor.system`) pass without the check. A scoped
-- caller whose context sets did not resolve is denied (fail closed).
function check_editor_domain(ctx)
    local actor = ctx.actor
    if actor == nil or actor.system then
        return
    end

    local scopes = actor.scopes
    if scopes == nil then
        return
    end

    local is_domain_editor = false
    for _, alias_name in ipairs(scopes) do
        if alias_name == "domain_editor" then
            is_domain_editor = true
        end
    end
    if not is_domain_editor then
        return
    end

    local parent = ctx.root["parent_doctype"]
    if parent == nil then
        return -- required-field validation covers the absent case
    end

    local sets = actor.context_sets
    local allowed = sets and sets.editor_doctypes
    if allowed == nil then
        ctx.error("Domain-editor scope could not resolve the editable domains — view creation denied")
        return
    end

    for _, qualified in ipairs(allowed) do
        if qualified == parent then
            return
        end
    end
    ctx.error("Doctype '" .. parent .. "' does not belong to a domain you edit")
end

return export
