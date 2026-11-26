---
type: how-to
title: "MCP: connecting agents"
description: Connect an external agent to Facet over MCP under one pinned role.
audience: [developer]
features: [AI-05, APP-04]
sidebar:
  order: 1
verified_at: a77c6171
---

Facet is a Model Context Protocol (MCP) server. An external agent signs in
under one pinned role and works on documents as that role. Facet is the
resource server: it validates tokens minted by its own `/OAuth/*` endpoints
and issues none itself.

> **For agents:** `POST /Api/_mcp/<role_slug>` — JSON-RPC 2.0, with `Authorization: Bearer <token>`. Take the URL
> verbatim from `GET /Api/_mcp/endpoints`; never derive it from your own origin. A first call without a token
> answers `401` plus a `WWW-Authenticate` challenge naming `/.well-known/oauth-protected-resource`. Connect:
> `POST /OAuth/register` → `GET /OAuth/authorize` with `resource=<per-role MCP identifier>` and
> `role=<qualified role id>` → `POST /OAuth/token` (PKCE) → `initialize`, `tools/list`, `tools/call`. Bare role
> names answer `400 invalid_request`; use `iam.Roles.admin`, never `admin`.

## When to use this

Connect an external agent over MCP when:

- You drive Facet from an external agent through MCP.
- You want role RBAC without an app registration.
- You need the audit to show one pinned role per session.

## Before you start

- The account holds the role, and the role's `connectivity` lists the `mcp`
  channel.
- MCP is not an app: no registration document, no grant ceiling. The role is
  the only bound.
- You need the endpoint URL. `GET /Api/_mcp/endpoints` (browser session, app
  token, or API key) answers with one URL per held role, sorted by role id:

```json
{
  "endpoints": [
    { "role": "iam.Roles.editor", "url": "https://facet.example.com/Api/_mcp/iam.Roles.editor" }
  ]
}
```

- Render the URL verbatim. The token's `aud` must equal it exactly; a URL
  derived from your own origin fails.

## Steps

The connect sequence:

<!-- d2
direction: down
Agent -> Facet: First call, no token
Facet -> Agent: 401 + WWW-Authenticate challenge
Agent -> Facet: GET /.well-known/oauth-protected-resource
Agent -> Facet: GET /OAuth/authorize (resource + role)
Facet -> Agent: The consent screen pins the role
Agent -> Facet: POST /OAuth/token with the code verifier
Facet -> Agent: Access token (aud + role)
Agent -> Facet: POST /Api/_mcp/:role_slug (JSON-RPC)
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9e5d826c-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9e5d826c-dark.svg" alt="Diagram" loading="lazy" />
</div>

### 1. Discover the authorization server

A first call without a token answers `401`. The `WWW-Authenticate` header
carries a `resource_metadata` address. Fetch that RFC 9728 protected resource
metadata (PRM): the per-role identifier in `resource`, Facet in
`authorization_servers`, and `"bearer_methods_supported": ["header"]`.

### 2. Register the client

`POST /OAuth/register` implements RFC 7591 dynamic client registration. It is
stateless: Facet mints an opaque public-client id and keeps no record. The
consent screen and PKCE carry the security.

```sh
curl -sX POST https://facet.example.com/OAuth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:8765/callback"],"client_name":"my-agent"}'
```

The answer carries the `client_id` — an opaque public-client id, no secret.

### 3. Authorize with the resource parameter

Send the account's browser to `GET /OAuth/authorize`. Carry the PKCE
parameters from [User login](/build/apps/connect/user-login/), plus:

| Parameter | Value |
| --- | --- |
| `resource` | the per-role MCP identifier: `https://<host>/Api/_mcp/<role_slug>` |
| `role` | the qualified role id, for example `iam.Roles.editor` |

The consent screen pins that role. It denies a role the account does not
hold, and a role whose `connectivity` lacks the `mcp` channel. Both denials
carry the same `access_denied` answer; the code records the resource and the
role.

### 4. Exchange the code

Exchange the code at `POST /OAuth/token` as the login flow does. The access
token carries `aud` (the per-role identifier, exact match), `role` (the
qualified id), `sub` (the account id), `sid` (the session id), and no `app`
claim.

### 5. Call the tool surface

JSON-RPC 2.0 rides `POST /Api/_mcp/<role_slug>`. One request carries one
call; the answer is one response. Start with `initialize`; the server answers
with its protocol version and the pinned role. Then send
`notifications/initialized` — it expects no response. List the role's tools:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
```

The answer lists the tools with `name`, `description`, and `inputSchema` —
see [Agent tools](/build/apps/agents/agent-tools/) for the catalogue. Call one:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "list_documents",
    "arguments": {
      "domain": "crm",
      "doctype": "Contact",
      "filters": { "status__eq": "active" },
      "sort": ["-created_at"]
    }
  }
}
```

### 6. Refresh the session

POST `grant_type=refresh_token` to `/OAuth/token`. An MCP session revalidates
the account, the held role, and the role's `mcp` channel. A role that lost
the channel loses its sessions at the next refresh; a live access token
stays valid to its TTL.

## Explanation

### The model

- **The URL pins the role.** One `:role_slug` serves one session. There is no
  in-session switch; another role means another URL.
- **Role ids are qualified.** The `role` parameter and the URL slug carry
  `iam.Roles.admin`; bare names are ambiguous across domains.
- **MCP is not an app.** No grant intersection applies; plain role RBAC runs, exactly as on REST.
- **No system principal.** The dispatch rejects a system context outright.
- **MCP is a data plane.** Tools work on documents of registered doctypes;
  schema authoring stays on REST and in the builder assistant.

### Limits

The optional `mcp:` block in `config.{env}.yml` sets the caps:

| Key | Default | Bounds |
| --- | --- | --- |
| `max_concurrency_per_sid` | 4 | dispatches in flight per session; over the cap, requests wait |
| `max_result_rows` | 200 | rows a list tool returns |
| `max_response_bytes` | 1048576 | bytes of a tool result envelope |
| `max_batch_ops` | 25 | operations in one `batch` call |

Query duration rides the shared statement timeout
(`database.statement_timeout_ms`); there is no separate MCP pool. Files never
ride JSON-RPC: `request_artifact_upload` mints a one-time signed upload URL —
see [Agent tools](/build/apps/agents/agent-tools/) and [Uploading and serving files](/build/apps/data/files/).

### Attribution

Every write stamps `mutations.channel = "mcp"` plus the pinned role as
`acting_role`. The audit shows the session's one role — see [Auditing activity](/admin/history/audit/).

## Example

After consent, exchange the code and call the surface. Build the PKCE pair as
[User login](/build/apps/connect/user-login/) shows:

```sh
curl -sX POST https://facet.example.com/OAuth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&code=AUTH_CODE&client_id=CLIENT_ID&redirect_uri=http://localhost:8765/callback&code_verifier=VERIFIER"

curl -sX POST "https://facet.example.com/Api/_mcp/iam.Roles.editor" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## Troubleshooting

**The first call answers `401` with a `WWW-Authenticate` challenge.**

That answer is normal. Follow `resource_metadata` to the PRM document and
start the flow.

**`400 invalid_request` names the role shape.**

The authorize `role` parameter carries a bare name. Send the qualified id:
`iam.Roles.admin`, not `admin`.

**The consent screen denies the sign-in.**

The account does not hold the role, or its `connectivity` lacks the `mcp`
channel. Both denials carry `access_denied`.

**The token works on MCP, and REST refuses it.**

By design. The token's `aud` names the MCP surface; REST rejects it, and so
does the endpoints directory. Use a session, an app token, or an API key.

**A response carries the `MCP-Tools-Changed` header.**

The role's permissions changed. Call `tools/list` again before the next call.

## Related

- [Agent tools](/build/apps/agents/agent-tools/) — the catalogue these routes serve.
- [How apps work on Facet](/build/apps/how-apps-work/) — the app model; MCP is not an app.
- [Governing the assistant](/admin/assistant/govern/) — mounts the same catalogue.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — the rights model.
- Internals on GitHub: [mcp.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mcp.md).
