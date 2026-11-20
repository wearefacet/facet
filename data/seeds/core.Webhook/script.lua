-- core.Webhook lifecycle hooks.
local export = {}

-- HTTP field-name grammar (RFC 7230 section 3.2.6): token characters only.
local TOKEN_PATTERN = "^[A-Za-z0-9!#$%%&'*+%.%^_`|~-]+$"

-- Validates a caller-supplied `headers` object at authoring time. The
-- Facet-mandated `X-Facet-*` headers are stamped by the dispatcher at
-- delivery time; a caller-supplied key with that prefix (any case) is
-- rejected here with 422 instead of being silently shadowed at runtime.
-- Values must be strings and keys must match the field-name grammar, so
-- the dispatcher's merge never has to defend against malformed entries.
--
-- Runs on both authoring paths: `create` passes the full content,
-- `update` passes the patch (object fields replace wholesale, so the
-- incoming value is the complete new `headers` object; a PATCH that does
-- not touch `headers` arrives as nil and is skipped).
local function validate_headers(ctx, headers)
  if headers == nil then
    return
  end
  if type(headers) ~= "table" then
    ctx.error("headers must be an object")
  end
  for key, value in pairs(headers) do
    if type(key) ~= "string" or key:lower():match("^x%-facet%-") then
      ctx.error("headers keys must not start with X-Facet-: Facet sets those headers at delivery time")
    end
    if not key:match(TOKEN_PATTERN) then
      ctx.error("headers keys must match the HTTP field-name grammar (RFC 7230 token)")
    end
    if type(value) ~= "string" then
      ctx.error("headers values must be strings")
    end
  end
end

-- Validates a caller-supplied target URL at authoring time. Two rules:
--
-- 1. Scheme (B-77): with `webhook.allow_insecure_urls` false (the default),
--    a non-https target is rejected. The dispatcher and `/test` refuse
--    non-https targets at delivery time, so a plain-http URL would create a
--    webhook that can never deliver (silent-success class). When the flag
--    is on, the `url` field type has already validated the absolute
--    http(s) shape, so nothing more to check at this stage.
-- 2. Host (B-76, `util.safe_webhook_url`): the host must resolve to a
--    public address on every resolved IP. This runs regardless of the
--    scheme flag — an internal receiver is a delivery-time refusal either
--    way, and `webhook.allowed_hosts` is the sanctioned opt-in for a
--    legitimate internal receiver. The binding and the delivery-time gate
--    (`Webhook::TargetCheck`) share one rule, so authoring and delivery
--    never disagree about why a URL was refused.
--
-- Runs on both authoring paths: `create` passes the full content,
-- `update` passes the patch (a PATCH that does not touch `url` arrives
-- as nil and is skipped).
local function validate_url(ctx, url)
  if url == nil then
    return
  end
  if type(url) ~= "string" then
    ctx.error("url must be a string")
    return
  end
  if not util.insecure_urls_allowed() and not util.valid_https_url(url) then
    ctx.error("insecure webhook target URL rejected — only https is allowed; "
      .. "set webhook.allow_insecure_urls to permit plain http")
    return
  end
  if not util.safe_webhook_url(url) then
    ctx.error("webhook target URL rejected — the host must resolve to a public "
      .. "address; internal receivers need a webhook.allowed_hosts entry, and "
      .. "a host that does not resolve can never deliver")
  end
end

-- Validates a caller-supplied `events` list at authoring time. The event
-- vocabulary is closed: the publisher emits only the names that
-- `util.webhook_event_names` returns. A name outside that list creates a
-- binding that silently never fires (B-152) — the dispatch filter has no
-- way to warn about it — so the authoring gate rejects it here with 422,
-- and the message lists the allowed names so the author can self-correct.
-- An empty list stays valid: it means "fire on nothing" (the dispatch
-- filter treats it as opt-out). A nil value — the field absent — means
-- "fire on everything" and skips the gate, like `headers` and `url`.
--
-- Runs on both authoring paths: `create` passes the full content, `update`
-- passes the patch (a PATCH that does not touch `events` arrives as nil).
local function validate_events(ctx, events)
  if events == nil then
    return
  end
  if type(events) ~= "table" then
    ctx.error("events must be an array of event-name strings")
    return
  end
  local allowed = util.webhook_event_names()
  local known = {}
  for _, name in ipairs(allowed) do
    known[name] = true
  end
  for _, name in ipairs(events) do
    if type(name) ~= "string" then
      ctx.error("events entries must be strings")
    elseif not known[name] then
      ctx.error("unknown event name '" .. name .. "' — allowed event names: "
        .. table.concat(allowed, ", "))
    end
  end
end

-- Validates the actioner's connectivity at authoring time. Webhook
-- authoring is open to every role by permission shape (B-76 ownership
-- arbitration), but a role can be built without the channel:
-- `iam.Roles.connectivity` names the programmatic channels the role may
-- use. A role without `webhook` gets a clear 422 here instead of a
-- webhook that can never fire (the enqueue gate skips those with
-- `ChannelClosed`). A system bypass caller is exempt — seeding and
-- migration stamp bindings after the fact.
--
-- `util.role_has_channel` read semantics: a role projection that does not
-- exist passes (an authenticated actor's active role always has a live
-- projection — the auth layer loads it before any hook runs — so this
-- branch is fixture-only; the delivery gate fails closed there), while a
-- present projection with a missing or malformed `connectivity` list
-- refuses (fail closed).
local function validate_actor_channel(ctx)
  if ctx.actor == nil or ctx.actor.system == true then
    return
  end
  if not util.role_has_channel(ctx.actor.role_id, "webhook") then
    ctx.error("webhook authoring refused — the role's connectivity excludes the "
      .. "'webhook' channel; enable it on the role first")
  end
end

-- create: stamps the per-webhook secret and the bound identity.
--
-- secret is a server-generated ULID: read_only on the doctype, so the
-- caller cannot supply it; this hook is the only writer, and it
-- overwrites any caller-supplied value to guarantee the invariant.
-- account_id and role_id come from ctx.actor — the actioner's identity
-- and their active role at create time. A system bypass caller (seeding,
-- migration) leaves the fields untouched; in that path the webhook is
-- expected to be patched afterwards with a real binding before it can
-- fire (the enqueue-time check rejects a missing binding).
function export.create(ctx)
  validate_actor_channel(ctx)
  validate_headers(ctx, ctx.root.headers)
  validate_url(ctx, ctx.root.url)
  validate_events(ctx, ctx.root.events)
  ctx.root.secret = util.ulid()
  if ctx.actor ~= nil and ctx.actor.system == false then
    ctx.root.account_id = ctx.actor.id
    ctx.root.role_id = ctx.actor.role_id
  end
end

-- update: enforces immutability of the bound identity + per-webhook secret.
--
-- The binding is a credential. Allowing PATCH to reassign it silently
-- would let an admin move a webhook under another account's authority
-- without that account being involved. Reassigning a webhook = delete +
-- The same immutability rule applies to the per-webhook secret
-- (it is server-generated at create time). A PATCH that touches
-- `headers` or `url` is validated by the shared authoring rules.
function export.update(ctx)
  validate_actor_channel(ctx)
  if ctx.patch then
    validate_headers(ctx, ctx.patch.headers)
    validate_url(ctx, ctx.patch.url)
    validate_events(ctx, ctx.patch.events)
    if ctx.patch.account_id ~= nil then
      ctx.error("account_id is immutable after creation")
    end
    if ctx.patch.role_id ~= nil then
      ctx.error("role_id is immutable after creation")
    end
    if ctx.patch.secret ~= nil then
      ctx.error("secret is immutable after creation")
    end
  end
end

return export
