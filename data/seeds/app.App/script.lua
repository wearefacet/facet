-- app.App lifecycle hooks.
-- Module pattern: returns a table of exported functions.
local export = {}

-- Validates the optional `host` field: shape first, then the Facet
-- reserved-host set. Runs on create and on every update that touches the
-- field, so a host can never enter the document in a form the dispatcher
-- would reject or resolve against Facet's own origin.
--
-- The dispatcher's reserved-host fall-through (Facet's own hosts always
-- win before any app lookup) is the defence-in-depth backstop; this hook
-- is the operator-facing error surface.
--
-- Shape: a bare lowercase hostname — no scheme, no port, no path, no
-- wildcard characters (checked by the util.valid_hostname binding, since
-- Lua patterns cannot express the rule). The deployment target supplies
-- the port at serve time, so the stored host never carries one.
--
-- Reserved: the value must not name a host Facet itself answers at —
-- the configured `host`, `base_url`, or `artifact_base_url` host, or a
-- loopback literal (`127.0.0.1`, `::1`; internal traffic reaches the
-- backend by IP). The port strip before the comparison is defensive only —
-- the shape rule already refuses a port. The reserved set comes
-- from the util.facet_hosts binding; there is no app_hosting config
-- section.
local function validate_host(ctx, host)
  if host == nil or host == "" then
    return
  end
  if type(host) ~= "string" or not util.valid_hostname(host) then
    ctx.error("host must be a bare lowercase hostname — no scheme, no port, no path, no wildcard characters")
    return
  end
  local bare = string.match(host, "^([^:]+)")
  for _, reserved in ipairs(util.facet_hosts()) do
    if bare == reserved then
      ctx.error("host '" .. host .. "' is reserved by Facet")
      return
    end
  end
end

-- Validates the optional `redirect_uris` array: every entry must be an
-- https URI (any host) or an http URI on a loopback host — localhost, a
-- '*.localhost' subdomain, 127.0.0.1, or ::1. An http redirect on a
-- remote host sends the authorization code over plaintext, so the scheme
-- follows the host (B-154). No fragment, no userinfo, no query. The only
-- permitted wildcard is a '*' port on an http loopback host — RFC 8252:
-- the OS assigns the local listener's port, so a native client cannot
-- pin it. Any other '*' is rejected. The parse runs through the
-- util.valid_redirect_uri binding (Crystal-backed), since Lua patterns
-- cannot parse a URI.
--
-- Request time matches a presented URI exactly, except that a '*'-port
-- entry matches any port — see OAuth::RedirectUri.match?.
local function validate_redirect_uris(ctx, uris)
  if uris == nil then
    return
  end
  if type(uris) ~= "table" then
    ctx.error("redirect_uris must be an array of absolute URIs")
    return
  end
  for _, uri in ipairs(uris) do
    if type(uri) ~= "string" or not util.valid_redirect_uri(uri) then
      ctx.error("redirect_uris entries must use https on any host or http on a loopback host (localhost, *.localhost, 127.0.0.1, ::1), without fragment, userinfo, or query; the only permitted wildcard is a '*' port on an http loopback host")
      return
    end
  end
end

-- Headless coherence: an app marked `no_asset` is never a deploy target
-- and never gains a host — nothing would be served at it. Checked on the
-- merged state in both hooks, so either field arriving alone in a PATCH
-- is caught against the other's stored value.
local function validate_asset_state(ctx)
  local no_asset = ctx.root.no_asset == true
  local host = ctx.root.host
  if no_asset and host ~= nil and host ~= "" then
    ctx.error("host cannot be set on an app with no_asset")
  end
end

-- Validates the optional `allowed_origins` array: every entry must be a
-- bare origin (scheme + host + optional port). This is the CORS surface:
-- the handler echoes a registered origin with
-- `Access-Control-Allow-Credentials: true` on `/Api/*`, so an entry must be
-- a well-formed, credential-safe origin — never a wildcard, a path, or an
-- `http` origin on a remote host (which would carry a `SameSite` cookie in
-- plaintext).
--
-- Shape: one entry is `scheme://host[:port]`, with no path, no userinfo,
-- no query, no fragment, no wildcard. The scheme is https, or http on a
-- loopback host (the same scheme-follows-host rule as redirect_uris).
--
-- The design lets an app register more than one origin (a hosted app plus a
-- local dev build), so the gate is the shape, not a single fixed host. The
-- parse runs through the util.valid_origin binding (Crystal-backed), since
-- Lua patterns cannot parse a URI.
local function validate_allowed_origins(ctx, origins)
  if origins == nil then
    return
  end
  if type(origins) ~= "table" then
    ctx.error("allowed_origins must be an array of origins")
    return
  end
  for _, origin in ipairs(origins) do
    if type(origin) ~= "string" or not util.valid_origin(origin) then
      ctx.error("allowed_origins entries must be a bare origin (scheme://host[:port], https on any host or http on a loopback host), without path, userinfo, query, fragment, or wildcard")
      return
    end
  end
end

-- create: assigns an autogenerated ULID as client_id.
--
-- The brief defines client_id as a public, autogenerated ULID. The field
-- is marked read_only on the doctype, so callers cannot supply it; this
-- hook is the only writer. It overwrites any caller-supplied value to
-- guarantee the invariant.
function export.create(ctx)
  ctx.root.client_id = util.ulid()
  validate_host(ctx, ctx.root.host)
  validate_redirect_uris(ctx, ctx.root.redirect_uris)
  validate_allowed_origins(ctx, ctx.root.allowed_origins)
  validate_asset_state(ctx)
end

-- update: enforces slug immutability, the app-scoped guard, and validates
-- the host field.
--
-- `slug` is the human-readable identifier the caller chose at create
-- time. The doctype schema marks it `unique: true` but cannot express
-- "set once at create, never changed via PATCH" -- that is a runtime
-- lifecycle concern, enforced here so the rule lives with the rest of
-- the app.App business logic rather than in the document service.
--
-- The check uses `ctx.patch` (the partial PATCH body the caller
-- submitted), not `ctx.root`, because `ctx.root` is the merged state
-- and would always agree with `ctx.patch.slug`. We treat ANY presence
-- of `slug` in the patch as an attempt to modify it -- callers simply
-- must not send the field on update. This mirrors the `read_only`
-- semantic on `client_id` (rejected whenever supplied), but applied
-- only at PATCH time so create can still write the initial value.
--
-- App-scoped guard: an app-scoped caller (a service account acting for
-- an app — `ctx.actor.app_id` present) may never widen a grant ceiling
-- or swap the pinned service role/account. Without this guard a CLI
-- holder with `update` on app.App could PATCH its own document and
-- self-modify the ceiling — a privilege-escalation path. Operators
-- (session callers, no `app_id` on the actor) keep full edit rights.
--
-- `host` IS settable after creation (an app may move to a new hostname),
-- but every new value passes the same shape + reserved-host validation
-- as at create time.
--
-- `redirect_uris` is validated on every update that carries it, with the
-- same shape rule as at create time.
--
-- `allowed_origins` is validated on every update that carries it, and
-- against the merged host: an update that moves the host re-checks the
-- stored origins, and an update that carries origins re-checks them against
-- the stored host.
function export.update(ctx)
  if ctx.patch and ctx.patch.slug ~= nil then
    ctx.error("slug is immutable after creation")
  end
  if ctx.patch and ctx.actor and ctx.actor.app_id then
    for _, field in ipairs({ "grants", "service_role_id", "service_account_id" }) do
      if ctx.patch[field] ~= nil then
        ctx.error(field .. " cannot be modified by an app-scoped caller")
      end
    end
  end
  if ctx.patch and ctx.patch.host ~= nil then
    validate_host(ctx, ctx.patch.host)
  end
  if ctx.patch and ctx.patch.redirect_uris ~= nil then
    validate_redirect_uris(ctx, ctx.patch.redirect_uris)
  end
  if ctx.patch and (ctx.patch.allowed_origins ~= nil or ctx.patch.host ~= nil) then
    validate_allowed_origins(ctx, ctx.root.allowed_origins)
  end
  validate_asset_state(ctx)
end

-- deploy: the named action behind the deploy route's gate. The deploy
-- mutation is not a document action — the multipart route creates the
-- `app.Deployment` document itself and runs no Lua here, so the function
-- validates nothing and changes nothing. It exists because ScriptValidator
-- requires a matching export for every declared action.
function export.deploy(ctx, args)
end

return export
