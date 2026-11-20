-- iam.OIDCProvider lifecycle hooks.
--
-- Validation that the schema cannot express, enforced on the merged state
-- in both hooks. The pattern follows app.App: shape rules run through
-- Crystal-backed util bindings (Lua patterns cannot parse a URI), the
-- name immutability rides ctx.patch, and defaults are applied at create.
--
-- The name is the URL segment of /auth/oidc/{name} AND the join key of
-- the account links (`federated_identities[].provider`). The schema's
-- unique constraint only covers live rows, so the create hook also
-- refuses a name a tombstoned provider still holds through the
-- util.oidc_name_tombstoned binding: recreating a name pointed at a
-- different issuer would silently re-authenticate every existing link
-- against the new IdP.
local export = {}

local DEFAULT_SCOPES = { "openid", "email", "profile" }

-- Returns the array when it is a table of non-empty strings, nil when
-- absent, and raises through ctx when the shape is wrong. Returning the
-- table itself lets the caller take #array — a boolean would not.
local function array_of_strings(ctx, field, v)
  if v == nil then
    return nil
  end
  if type(v) ~= "table" then
    ctx.error(field .. " must be an array of non-empty strings")
    return nil
  end
  for _, entry in ipairs(v) do
    if type(entry) ~= "string" or entry == "" then
      ctx.error(field .. " entries must be non-empty strings")
      return nil
    end
  end
  return v
end

-- Lowercases the domain allowlist in place and rejects empty entries.
local function normalize_domains(ctx, domains)
  if domains == nil then
    return
  end
  for i, entry in ipairs(domains) do
    if entry == "" then
      ctx.error("domains entries must be non-empty")
      return
    end
    domains[i] = string.lower(entry)
  end
end

function export.create(ctx)
  local name = ctx.root.name
  if type(name) ~= "string" or not string.match(name, "^[a-z0-9-]+$") then
    ctx.error("name must be lowercase alphanumeric with hyphens (it appears in /auth/oidc/ URLs)")
    return
  end

  if util.oidc_name_tombstoned and util.oidc_name_tombstoned(name) then
    ctx.error("name '" .. name .. "' is still held by a deleted provider — accounts may still " ..
      "carry links under it. Choose a different name, or purge the deleted provider first")
    return
  end

  if type(ctx.root.issuer) ~= "string" or not util.valid_issuer_url(ctx.root.issuer) then
    ctx.error("issuer must be an absolute https URL — plain http is allowed only on a loopback host " ..
      "(localhost, *.localhost, 127.0.0.1, ::1)")
    return
  end

  -- Label defaults to the name.
  if util.is_empty(ctx.root.label) then
    ctx.root.label = name
  end

  local domains = array_of_strings(ctx, "domains", ctx.root.domains)
  normalize_domains(ctx, domains)

  -- JIT provisioning resolves its roles at login time: the provider's
  -- default_role when set, else the instance baseline
  -- (iam.oidc.provision_roles on core.SystemSettings). A provider without
  -- either cannot provision — the flow denies with a clear audit reason —
  -- but that is a runtime condition this hook cannot see, so no
  -- save-time coupling is enforced here.

  -- Scopes default to the OIDC standard trio — when absent or empty. A
  -- shape error was already recorded when the value was present but
  -- malformed (scopes is nil then); the create fails on it either way.
  local scopes = array_of_strings(ctx, "scopes", ctx.root.scopes)
  if scopes == nil or #scopes == 0 then
    ctx.root.scopes = DEFAULT_SCOPES
  end

  -- enabled defaults on: the operator just configured the provider
  -- deliberately (the schema default covers the absent case; an explicit
  -- null is normalized away before this hook runs).
  if ctx.root.enabled == nil then
    ctx.root.enabled = true
  end
end

function export.update(ctx)
  if ctx.patch and ctx.patch.name ~= nil then
    ctx.error("name is immutable after creation")
  end

  if ctx.patch and ctx.patch.issuer ~= nil then
    if type(ctx.patch.issuer) ~= "string" or not util.valid_issuer_url(ctx.patch.issuer) then
      ctx.error("issuer must be an absolute https URL — plain http is allowed only on a loopback host " ..
        "(localhost, *.localhost, 127.0.0.1, ::1)")
      return
    end
  end

  if ctx.patch and ctx.patch.domains ~= nil then
    array_of_strings(ctx, "domains", ctx.patch.domains)
    normalize_domains(ctx, ctx.root.domains)
  end

  -- Note: no save-time coupling between auto_provision and default_role.
  -- See the create hook above — the role baseline resolves at login time
  -- from the provider document or the instance setting.

  if ctx.patch and ctx.patch.scopes ~= nil then
    local scopes = array_of_strings(ctx, "scopes", ctx.patch.scopes)
    if scopes ~= nil and #scopes == 0 then
      ctx.error("scopes cannot be emptied — the authorization request needs at least 'openid'")
      return
    end
  end
end

return export
