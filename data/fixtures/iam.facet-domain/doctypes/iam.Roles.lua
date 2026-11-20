-- iam.Roles lifecycle hooks.
-- Module pattern: returns a table of exported functions.
local export = {}

-- connectivity: the closed channel vocabulary. A role names the
-- programmatic channels it may use — 'mcp', 'webhook', 'api' (API keys),
-- 'assistant'. Browser access (the core application and hosted apps) is
-- never governed here, so an absent value stays valid and reads as "no
-- channels". An unknown name is rejected with 422 and the message lists
-- the allowed names, so a typo'd role cannot silently close a channel
-- (same message pattern as the core.Webhook `events` gate, B-152).
--
-- Runs on both authoring paths: `create` passes the full content, `update`
-- passes the patch (a PATCH that does not touch `connectivity` arrives as
-- nil).
local ALLOWED_CHANNELS = { "mcp", "webhook", "api", "assistant" }

local function validate_connectivity(ctx, value)
  if value == nil then return end
  if type(value) ~= "table" then
    ctx.error("connectivity must be an array of channel names")
    return
  end
  local known = {}
  for _, name in ipairs(ALLOWED_CHANNELS) do
    known[name] = true
  end
  for _, name in ipairs(value) do
    if type(name) ~= "string" then
      ctx.error("connectivity entries must be strings")
    elseif not known[name] then
      ctx.error("unknown channel '" .. tostring(name) ..
        "' — allowed channels: " .. table.concat(ALLOWED_CHANNELS, ", "))
    end
  end
end

-- create: validate the channel list.
function export.create(ctx)
  validate_connectivity(ctx, ctx.root and ctx.root.connectivity or nil)
end

-- update: the role `name` is the role's identity. The document id is
-- `iam.Roles.<name>` (the same named-id form the seeds and the portable
-- bundles use), and account documents reference that id in their `roles`
-- array. Renaming would desync the id from the name, so any PATCH that
-- carries `name` is refused -- the same rule `app.App` applies to its
-- slug. Recreate the role under the new name instead.
function export.update(ctx)
  if ctx.patch and ctx.patch.name ~= nil then
    ctx.error("'name' is immutable after creation — the role id is iam.Roles." ..
      tostring(ctx.root and ctx.root.name or "<unknown>") ..
      "; recreate the role under the new name")
  end
  validate_connectivity(ctx, ctx.patch and ctx.patch.connectivity or nil)
end

-- delete: refuse to delete a role that is still assigned to any account.
--
-- iam.Account.roles stores role document ids (e.g. "iam.Roles.admin"). The
-- document list API has no array-contains operator, so we list every account
-- and check membership in Lua. Facet targets mid-sized organizations, so the
-- full-account scan is acceptable here. When an array-contains filter is added
-- to Document::List, this can switch to a single filtered `document.list`.
--
-- A projection's `content` is exposed to Lua as a JSON string, so we
-- `util.json_decode` it before reading the `roles` array.
function export.delete(ctx)
  local doc_id = ctx.doc_id
  if doc_id == nil then return end

  local ok, result = pcall(document.list, "Account", {}, nil, 1, 10000)
  if not ok then
    -- Listing failed (RBAC, doctype missing, etc). Do not silently allow the
    -- delete — surface the failure so the audit trail records it.
    if ctx.error then
      ctx.error("role delete: failed to list accounts: " .. tostring(result))
    end
    return
  end

  if result == nil or result.items == nil then return end

  for _, account in ipairs(result.items) do
    if type(account.content) == "string" then
      local ok2, content = pcall(util.json_decode, account.content)
      if ok2 and type(content) == "table" and type(content.roles) == "table" then
        for _, role_id in ipairs(content.roles) do
          if role_id == doc_id then
            if ctx.error then
              ctx.error("role is still assigned to account " .. tostring(account.id) ..
                " — unassign it before deleting")
            end
            return
          end
        end
      end
    end
  end
end

return export
