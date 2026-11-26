-- core.Comment lifecycle hooks.
--
-- The `author` field is the comment's ownership anchor: the `mine` named
-- scope (author: $self) drives author-scoped read/update/delete grants. The
-- create hook forces it to the caller's account id so a caller can never
-- spoof authorship. System-context creates (seeding, sweeps) leave it null.
--
-- A bare actor id is stored; the post-hook Normalize pass qualifies it to
-- the canonical `iam.Account.<id>` reference form.
--
-- Thread rules live here too:
--   * `reply_to` is settable only at create time and must reference a live
--     comment attached to the same target document. Threads nest to any
--     depth; the panel caps the visual indent, the data does not.
--     Existence itself is already gated by the reference existence check;
--     the hook adds the same-target rule on top, so a reply can never
--     cross from one host document to another.
--   * `edited_at` is stamped by the update hook when the body actually
--     changes. It is read_only in the definition, so callers can never set
--     it directly.
--
-- Mentions notify. An account URN in the body (`urn:facet:iam:Account:`
-- plus the id segment, in link or bare form) sends the named account one
-- `comment_mention` notification routed to the host document. Account ids
-- are the account's email, lowercased (named-id create), so the id segment
-- carries `@` and the email punctuation, not just a ULID's alphanumerics.
-- Create notifies every mention; update notifies net-new ids only, on a
-- real body change — a mention kept through an edit stays silent, a removed
-- and re-added one notifies again. The author never notifies themself.
-- System contexts never notify. Every fetch and every send is pcall-guarded:
-- a failed label lookup degrades the title, a failed send drops one
-- mention, and neither can fail the comment.

local export = {}

-- Label cap. The `notifications.title` column holds 256 chars; two clipped
-- labels plus the fixed words always fit.
local LABEL_CHARS = 80

-- Fields probed, in order, for a document label. The Lua surface cannot
-- render a doctype's `display_name` template, so the label is the first
-- non-empty conventional name field on the content. No match — no label,
-- and the title omits the suffix.
local LABEL_FIELDS = { "display_name", "title", "name" }

-- Reference values arrive normalized to the qualified storage form
-- (`core.Comment.<id>`); `document.get` expects the bare opaque id.
local function bare_comment_id(ref)
    if type(ref) ~= "string" then return nil end
    return ref:gsub("^core%.Comment%.", "")
end

local function fetch_comment_content(id)
    if id == nil then return nil end
    local ok, proj = pcall(document.get, "Comment", id)
    if not ok then return nil end
    return util.json_decode(proj.content)
end

-- Splits a qualified reference value into domain, doctype, and id. The id
-- segment may itself contain a dot, so the tail stays whole.
local function split_qualified_ref(ref)
    if type(ref) ~= "string" then return nil end
    local domain, doctype, id = ref:match("^([^.]+)%.([^.]+)%.(.+)$")
    if domain == nil then return nil end
    return domain, doctype, id
end

-- Clips to LABEL_CHARS characters without splitting a code point.
local function clip_label(value)
    local len = utf8.len(value)
    if len == nil or len <= LABEL_CHARS then return value end
    local offset = utf8.offset(value, LABEL_CHARS + 1)
    return offset and value:sub(1, offset - 1) or value
end

-- One label from a live document. Cross-domain reads are grant-gated; a
-- denied or failed read returns nil and the caller degrades.
local function document_label(qualified_doctype, id)
    local ok, proj = pcall(document.get, qualified_doctype, id)
    if not ok or type(proj) ~= "table" or proj.deleted_at ~= nil then return nil end
    local ok_json, content = pcall(util.json_decode, proj.content)
    if not ok_json or type(content) ~= "table" then return nil end
    for _, field in ipairs(LABEL_FIELDS) do
        local value = content[field]
        if type(value) == "string" and value ~= "" then
            return clip_label(value)
        end
    end
    return nil
end

-- Distinct account ids mentioned in a body: the URN prefix followed by an
-- id segment, in markdown link or bare form. Returns a set.
--
-- Account ids are the account's email, lowercased (named-id create), so
-- the scan accepts the practical email charset (`@ . _ - +` beside the
-- alphanumerics) and trims a trailing `.` or `-` — bare-form sentence
-- punctuation, and no real id ends with either. The scan stays a
-- heuristic: the enqueue-time account existence check is the validator,
-- and a scan overrun fails there, contained.
local function mentioned_accounts(text)
    local found = {}
    if type(text) ~= "string" then return found end
    for raw in text:gmatch("urn:facet:iam:Account:([%w@%.%+%-_]+)") do
        local id = raw:gsub("[%.%-]+$", "")
        if #id > 0 then found[id] = true end
    end
    return found
end

-- Sends one comment_mention notification per mentioned account, author
-- excepted. The notification routes to the host document through the
-- comment's qualified target.
local function notify_mentions(actor_id, target, mentioned)
    if next(mentioned) == nil then return end
    if type(target) ~= "string" then return end

    local actor_name = document_label("iam.Account", actor_id) or "Someone"
    local title = actor_name .. " mentioned you"

    local domain, doctype, id = split_qualified_ref(target)
    if domain ~= nil then
        local host_name = document_label(domain .. "." .. doctype, id)
        if host_name ~= nil then
            title = title .. " on " .. host_name
        end
    end

    for account_id in pairs(mentioned) do
        if account_id ~= actor_id then
            pcall(notification.send, account_id, target, "comment_mention", title, { icon = "at-sign" })
        end
    end
end

function export.create(ctx)
    local reply_to = ctx.root["reply_to"]
    if reply_to ~= nil then
        local parent = fetch_comment_content(bare_comment_id(reply_to))
        if parent == nil then
            ctx.error("reply_to must reference an existing comment")
            return
        end
        if parent["target"] ~= ctx.root["target"] then
            ctx.error("reply_to must reference a comment attached to the same resource")
            return
        end
    end

    if ctx.actor == nil or ctx.actor.system then return end

    local supplied = ctx.root["author"]
    if supplied ~= nil and supplied ~= ctx.actor.id then
        ctx.error("Cannot create a comment authored by another account. author must be omitted.")
        return
    end
    ctx.root.author = ctx.actor.id

    notify_mentions(ctx.actor.id, ctx.root["target"], mentioned_accounts(ctx.root["body"]))
end

function export.update(ctx)
    -- The pre-persist projection still holds the old content on the same
    -- transaction connection, so it is the immutability baseline.
    local old = fetch_comment_content(ctx.doc_id)
    local old_reply_to = old ~= nil and old["reply_to"] or nil
    local new_reply_to = ctx.root["reply_to"]

    if ctx.patch["reply_to"] ~= nil then
        if new_reply_to ~= old_reply_to then
            ctx.error("reply_to cannot be changed after the comment is created")
            return
        end
    elseif old_reply_to ~= nil and new_reply_to == nil then
        -- An explicit null in the patch is stripped from the Lua view of
        -- both the patch and the merged content, so a cleared value shows
        -- up as an absent key over a non-null old value.
        ctx.error("reply_to cannot be cleared after the comment is created")
        return
    end

    -- Stamp the edit marker only on a real body change; a PATCH that
    -- resubmits the same body stays a no-op.
    local new_body = ctx.patch["body"]
    local body_changed = new_body ~= nil and (old == nil or new_body ~= old["body"])
    if body_changed then
        ctx.root["edited_at"] = ctx.now
    end

    -- Net-new mentions only, and only on a real body change. System
    -- contexts never notify.
    if ctx.actor == nil or ctx.actor.system then return end
    if not body_changed or old == nil then return end
    local old_mentions = mentioned_accounts(old["body"])
    local fresh = {}
    for id in pairs(mentioned_accounts(new_body)) do
        if not old_mentions[id] then fresh[id] = true end
    end
    notify_mentions(ctx.actor.id, ctx.root["target"], fresh)
end

return export
