-- iam.Account lifecycle hooks.
-- Module pattern: returns a table of exported functions.
local export = {}

-- Deduplicate the account's `roles` array, preserving first-occurrence order.
--
-- `iam.Account.roles` is a set of qualified role document ids (e.g.
-- "iam.Roles.admin"). A duplicate would crash the frontend's keyed `{#each}`
-- that renders the assignments page, so the invariant "no duplicate role ids"
-- is enforced here at the write boundary (create and update). The persisted
-- value is the deduplicated array.
local function dedupe_roles(roles)
  if type(roles) ~= "table" then
    return roles
  end

  local seen = {}
  local result = {}
  for _, role_id in ipairs(roles) do
    if type(role_id) == "string" and not seen[role_id] then
      seen[role_id] = true
      table.insert(result, role_id)
    end
  end
  return result
end

-- Normalize the account's `organizational_unit` path.
--
-- The invariant is "begins with '/' and ends with exactly one '/'". Only
-- the boundaries are normalized — the inner path is left untouched
-- (`a//b` stays `a//b`). An empty string collapses to the root `/`. A
-- non-string value raises (the write is rejected); the doctype validator
-- is the primary gate, this hook is defence in depth. A nil value does
-- nothing — the type default `/` applies at creation.
local function normalize_ou(ctx)
  local ou = ctx.root.organizational_unit
  if ou == nil then
    return
  end
  if type(ou) ~= "string" then
    error("organizational_unit must be a string")
  end
  if ou == "" then
    ctx.root.organizational_unit = "/"
    return
  end
  if ou:sub(1, 1) ~= "/" then
    ou = "/" .. ou
  end
  while ou:sub(1, 2) == "//" do
    ou = ou:sub(2)
  end
  while ou:sub(-2) == "//" do
    ou = ou:sub(1, -2)
  end
  if ou:sub(-1) ~= "/" then
    ou = ou .. "/"
  end
  ctx.root.organizational_unit = ou
end

-- Normalize the account's `email` to the stored form.
--
-- The document id of an account IS its email address (lowercased) —
-- Document::Create.resolve_doc_id derives it from this field. Lowercasing
-- here at the write boundary keeps the stored content equal to the id and
-- matches the lookup form every consumer uses (`find_account_by_email`,
-- the OIDC resolution, the login lookup all compare lowercase). Only the
-- create hook normalizes: the email is immutable after creation (the
-- update gate in Document::Update refuses a change).
local function normalize_email(ctx)
  local email = ctx.root.email
  if email == nil then
    return
  end
  if type(email) ~= "string" then
    return
  end
  ctx.root.email = string.lower(email:match("^%s*(.-)%s*$"))
end

-- Bootstrap status rule.
--
-- A freshly created HUMAN account has no credential and no federation yet —
-- it starts `pending` until its first full login flips it to `active`
-- (Facet::IAM::Login bootstrap flip). Two creates are exempt:
--
--   - service accounts authenticate through API keys, which require
--     `active` — they are machine identities with no bootstrap;
--   - JIT-provisioned OIDC accounts carry a non-empty
--     `federated_identities` array and are created `active` by the
--     provider flow (src/iam/oidc/identity.cr#provision_content).
--
-- An explicit non-default status (`suspended`, `disabled`) is honoured —
-- only the implicit/default `active` is replaced.
local function bootstrap_status(ctx)
  if ctx.root.service_account == true then
    return
  end
  local fed = ctx.root.federated_identities
  if type(fed) == "table" and #fed > 0 then
    return
  end
  if ctx.root.status == nil or ctx.root.status == "active" then
    ctx.root.status = "pending"
  end
end

function export.create(ctx)
  ctx.root.roles = dedupe_roles(ctx.root.roles)
  normalize_ou(ctx)
  normalize_email(ctx)
  bootstrap_status(ctx)
end

function export.update(ctx)
  ctx.root.roles = dedupe_roles(ctx.root.roles)
  normalize_ou(ctx)
end

return export
