-- core.Attachment lifecycle hooks.
--
-- `uploaded_by` is the attachment's ownership anchor: the `mine` named scope
-- (uploaded_by: $self) drives uploader-scoped read/update/delete grants. The
-- create hook forces it to the caller's account id so a caller can never
-- spoof uploadership. System-context creates (seeding, sweeps) leave it null.
--
-- A bare actor id is stored; the post-hook Normalize pass qualifies it to
-- the canonical `iam.Account.<id>` reference form.
--
-- There is no update hook: `name` is freely renameable and `file` may be
-- replaced with a new artifact id (the owner row for the new artifact is
-- appended by the service layer inside the same transaction).

local export = {}

function export.create(ctx)
    if ctx.actor == nil or ctx.actor.system then return end

    local supplied = ctx.root["uploaded_by"]
    if supplied ~= nil and supplied ~= ctx.actor.id then
        ctx.error("Cannot create an attachment uploaded by another account. uploaded_by must be omitted.")
        return
    end
    ctx.root.uploaded_by = ctx.actor.id
end

return export
