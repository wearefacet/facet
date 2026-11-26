---
title: Connect agents over MCP
description: Connect an external agent to Facet over MCP under one pinned role, from discovery to tools/call.
type: how-to
audience: [developer]
features: [AI-05, APP-04]
verified_at: eee55a2
sidebar:
  order: 1
---

Facet is a Model Context Protocol (MCP) server. An external agent signs in
under one pinned role and works on documents as that role. Facet is the
resource server: it validates tokens minted by its own `/OAuth/*` endpoints
and issues none itself.

> **For agents:** `POST /Api/_mcp/<role_slug>` — JSON-RPC 2.0, with `Authorization: Bearer <token>`.
> Take the URL verbatim from `GET /Api/_mcp/endpoints`; never derive it from your own origin. A
> first call without a token answers `401` plus a `WWW-Authenticate` challenge naming
> `/.well-known/oauth-protected-resource`. Connect: `POST /OAuth/register` → `POST /OAuth/authorize`
> with `resource=<per-role MCP identifier>` and `role=<qualified role id>` (browser consent) →
> `POST /OAuth/token` (PKCE) → `initialize`, `notifications/initialized` (202), `ping`, `tools/list`,
> `tools/call`. Bare role names answer `invalid_target`; use `iam.Roles.admin`, never `admin`.

## When to use this

Connect an external agent over MCP when:

- You drive Facet from an external agent through MCP.
- You want role RBAC without an app registration.
- You need the audit to show one pinned role per session.

## Before you start

- The account holds the role, and the role's `connectivity` lists the `mcp`
  channel.
- MCP is not an app: no registration document, no grant ceiling. The role
  is the only bound.
- You need the endpoint URL. `GET /Api/_mcp/endpoints` (browser session,
  app token, or API key) answers with one URL per held role:

```json
{
  "endpoints": [
    { "role": "iam.Roles.admin", "url": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin" }
  ]
}
```

- Render the URL verbatim. The token's `aud` must equal it exactly; a URL
  derived from your own origin fails.

The session below ran against a dev instance at
`https://facet.localhost:3443` with the Brightwater Rentals data loaded.
Ravi's admin account drove it, so the browser consent steps carry a session
cookie (`-b facet-cookies.txt`); a real client opens the same URLs in a
browser.

## Steps

The connect sequence:

<!-- d2
direction: down
Agent -> Facet: First call, no token
Facet -> Agent: 401 + WWW-Authenticate challenge
Agent -> Facet: GET /.well-known/oauth-protected-resource
Agent -> Facet: POST /OAuth/authorize (resource + role)
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

A first call without a token answers `401`. The challenge is the entry
point:

```sh
curl -sk -D - -o /dev/null -X POST \
  https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
```

```text
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://facet.localhost:3443/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin"

{"error":"Authentication required"}
```

Fetch that RFC 9728 protected resource metadata (PRM) document:

```sh
curl -sk https://facet.localhost:3443/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin
```

```json
{
  "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin",
  "authorization_servers": ["https://facet.localhost:3443"],
  "bearer_methods_supported": ["header"],
  "scopes_supported": [],
  "resource_documentation": "https://facet.localhost:3443/Api/_mcp"
}
```

The authorization-server metadata carries the endpoint map
(`/.well-known/oauth-authorization-server`): `authorization_endpoint`,
`token_endpoint`, `registration_endpoint`,
`code_challenge_methods_supported: ["S256"]`,
`token_endpoint_auth_methods_supported: ["none"]`, and
`dpop_signing_alg_values_supported: ["ES256"]`.

### 2. Register the client

`POST /OAuth/register` implements RFC 7591 dynamic client registration. It
is stateless: Facet mints an opaque public-client id and keeps no record.
The consent screen and PKCE carry the security. `redirect_uris` is
required; only `token_endpoint_auth_method: "none"` is supported:

```sh
curl -sk -X POST https://facet.localhost:3443/OAuth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://127.0.0.1:8765/callback"],"client_name":"brightwater-agent"}'
```

```json
{
  "client_id": "o-4ZmjY-zkPOT8w61Nzf0GJ55VfTq7Zkrk6TC2Iu8XU",
  "client_id_issued_at": 1795696890,
  "redirect_uris": ["http://127.0.0.1:8765/callback"],
  "token_endpoint_auth_method": "none",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "client_name": "brightwater-agent"
}
```

### 3. Authorize with the resource parameter

The agent sends the account's browser to the consent screen. Carry the
Proof Key for Code Exchange (PKCE) parameters from
[User login](/build/apps/connect/user-login/), plus:

| Parameter | Value |
| --- | --- |
| `resource` | the per-role MCP identifier: `https://<host>/Api/_mcp/<role_slug>` |
| `role` | the qualified role id, for example `iam.Roles.admin` |

The consent screen pins that role. It denies a role the account does not
hold, and a role whose `connectivity` lacks the `mcp` channel. Both denials
carry the same `access_denied` answer; the code records the resource and
the role.

The consent confirm is a `POST /OAuth/authorize` with the same parameters
plus the elected `role` — this is the step a browser form submits. In the
session below, a signed-in operator session drives it through `curl`. The
request needs the CSRF header:

```sh
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')

curl -sk -b facet-cookies.txt -X POST https://facet.localhost:3443/OAuth/authorize \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{
    "client_id": "o-4ZmjY-zkPOT8w61Nzf0GJ55VfTq7Zkrk6TC2Iu8XU",
    "redirect_uri": "http://127.0.0.1:8765/callback",
    "state": "consent-round-trip",
    "code_challenge": "'"$CHALLENGE"'",
    "code_challenge_method": "S256",
    "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin",
    "role": "iam.Roles.admin"
  }'
```

```json
{
  "redirect_uri": "http://127.0.0.1:8765/callback",
  "code": "U_2Xcqxi-BslGQOnrRca0T4fqgqKWxuU3KsE77lntF0",
  "state": "consent-round-trip",
  "app_id": "",
  "role_id": "iam.Roles.admin",
  "iss": "https://facet.localhost:3443"
}
```

A `resource` that names no role answers `400` before any consent:

```json
{
  "error": "invalid_target",
  "error_description": "'resource' must name a role-pinned MCP endpoint (https://facet.localhost:3443/Api/_mcp/<role_slug>)"
}
```

### 4. Exchange the code

Exchange the code at `POST /OAuth/token` with the PKCE verifier. The
verifier travels form-encoded, so it must carry no raw `+` or `=` — use a
URL-safe alphabet:

```sh
curl -sk -X POST https://facet.localhost:3443/OAuth/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&code=$CODE&code_verifier=$VERIFIER&client_id=$CLIENT_ID&redirect_uri=http://127.0.0.1:8765/callback"
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "4ed709fecffa3fc3…"
}
```

The access token carries `aud` (the per-role identifier, exact match),
`role` (the qualified id), `sub` (the account id), `sid` (the session id),
and no `app` claim. A wrong verifier, a reused code, or a mismatched
`redirect_uri` answers `400`:

```json
{ "error": "invalid_grant", "error_description": "PKCE verification failed" }
```

```json
{ "error": "invalid_grant", "error_description": "redirect_uri mismatch" }
```

### 5. Call the tool surface

JSON-RPC 2.0 rides `POST /Api/_mcp/<role_slug>`. One request carries one
call; the answer is one response. Start with `initialize`; the server
answers with its protocol version and the pinned role:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"brightwater-agent","version":"0.1"}}}'
```

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "facet", "version": "1.0", "role": "iam.Roles.admin" }
  }
}
```

Then send `notifications/initialized` — it expects no response and answers
`202`. A `ping` answers `{"jsonrpc":"2.0","id":2,"result":{}}`. List the
role's tools:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
```

The admin role sees 24 tools — `ping`, `list_domains`, `list_doctypes`,
`get_schema`, `whoami`, `list_documents`, `aggregate_documents`,
`get_document`, `resolve_refs`, `search_documents`, `create_document`,
`update_document`, `delete_document`, `call_action`, `batch`,
`list_mutations`, `get_links`, `get_backrefs`, `create_sidecar`,
`list_sidecars`, `request_artifact_upload`, `get_artifact`,
`list_artifact_refs`, `read_skill` — each with `name`, `description`, and
`inputSchema`. See [What agents can do](/build/apps/agents/agent-tools/)
for the catalogue. Call one:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_documents","arguments":{"query":"Maison"}}}'
```

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [{ "type": "text", "text": "{\"data\":[…],\"meta\":{\"query\":\"Maison\",\"total\":5}}" }],
    "structuredContent": { "data": [ … ], "meta": { "query": "Maison", "total": 5, "domain": null } }
  }
}
```

The payload rides twice: as a JSON string in `result.content[0].text`, and
as an object in `result.structuredContent`.

### 6. Refresh the session

POST `grant_type=refresh_token` to `/OAuth/token`. An MCP session
revalidates the account, the held role, and the role's `mcp` channel. A
role that lost the channel loses its sessions at the next refresh; a live
access token stays valid to its TTL (900 seconds in the session above).

## Explanation

### The model

- **The URL pins the role.** One `:role_slug` serves one session. There is
  no in-session switch; another role means another URL.
- **Role ids are qualified.** The `role` parameter and the URL slug carry
  `iam.Roles.admin`; bare names are ambiguous across domains.
- **MCP is not an app.** No grant intersection applies; plain role RBAC
  runs, exactly as on REST.
- **No system principal.** The dispatch rejects a system context outright.
- **MCP is a data plane.** Tools work on documents of registered doctypes;
  schema authoring stays on REST and in the builder assistant.
- **Bearer only.** A session cookie on an `/Api/_mcp/` route answers `401`
  — the surface takes tokens, never cookies. The browser session is for
  the consent screen only.

### Limits

The optional `mcp:` block in `config.{env}.yml` sets the caps:

| Key | Default | Bounds |
| --- | --- | --- |
| `max_concurrency_per_sid` | 4 | dispatches in flight per session; over the cap, requests wait |
| `max_result_rows` | 200 | rows a list tool returns |
| `max_response_bytes` | 1048576 | bytes of a tool result envelope |
| `max_batch_ops` | 25 | operations in one `batch` call |

Query duration rides the shared statement timeout
(`database.statement_timeout_ms`); there is no separate MCP pool. Files
never ride JSON-RPC: `request_artifact_upload` mints a one-time signed
upload URL — see [What agents can do](/build/apps/agents/agent-tools/) and
[Upload and serve files](/build/apps/data/files/).

### Attribution

Every write stamps `mutations.channel = "mcp"` plus the pinned role as
`acting_role`. The audit shows the session's one role — see
[Auditing activity](/admin/history/audit/).

## Example

The full session, end to end, on one Brightwater dev instance. Steps 3 and
4 need a browser consent in production; the script drives the consent with
a signed-in operator session instead:

```sh
BASE=https://facet.localhost:3443
MCPURL=$BASE/Api/_mcp/iam.Roles.admin
JAR=facet-cookies.txt

# 0. Operator session for the consent steps.
curl -sk -c $JAR -X POST $BASE/Api/iam/login \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"email": "ravi@brightwater.example", "password": "brightwater-ravi"}'

# 1. Discover.
curl -sk -D - -o /dev/null -X POST $MCPURL \
  -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
curl -sk $BASE/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin

# 2. Register.
CLIENT_ID=$(curl -sk -X POST $BASE/OAuth/register \
  -H 'Content-Type: application/json' \
  -d '{"redirect_uris":["http://127.0.0.1:8765/callback"],"client_name":"brightwater-agent"}' \
  | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)

# 3. PKCE pair, then consent (browser step in production).
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')
CODE=$(curl -sk -b $JAR -X POST $BASE/OAuth/authorize \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"client_id":"'"$CLIENT_ID"'","redirect_uri":"http://127.0.0.1:8765/callback","state":"consent-round-trip","code_challenge":"'"$CHALLENGE"'","code_challenge_method":"S256","resource":"'"$MCPURL"'","role":"iam.Roles.admin"}' \
  | grep -o '"code":"[^"]*"' | cut -d'"' -f4)

# 4. Token.
ACCESS_TOKEN=$(curl -sk -X POST $BASE/OAuth/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&code=$CODE&code_verifier=$VERIFIER&client_id=$CLIENT_ID&redirect_uri=http://127.0.0.1:8765/callback" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# 5. Initialize, initialized, tools/list, tools/call.
curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"brightwater-agent","version":"0.1"}}}'

curl -sk -o /dev/null -w '%{http_code}\n' -X POST $MCPURL \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'

curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_documents","arguments":{"query":"Maison"}}}'
```

## Troubleshooting

**The first call answers `401` with a `WWW-Authenticate` challenge.**

That answer is normal. Follow `resource_metadata` to the PRM document and
start the flow.

**`400 invalid_target` on authorize.**

The `resource` parameter sits under the MCP prefix but names no role — for
example the bare `…/Api/_mcp`. Name the role-pinned endpoint:
`…/Api/_mcp/iam.Roles.admin`.

**The consent screen denies the sign-in.**

The account does not hold the role, or its `connectivity` lacks the `mcp`
channel. Both denials carry `access_denied`.

**`400` with `{"error":"Missing 'role' field"}` on the consent confirm.**

The consent confirm carries the elected role in its body — the same
qualified role id the resource pins. Add `"role": "iam.Roles.admin"`.

**The token works on MCP, and REST refuses it.**

By design. The token's `aud` names the MCP surface; REST rejects it, and so
does the endpoints directory. Use a session, an app token, or an API key.

**A response carries the `MCP-Tools-Changed` header.**

The role's permissions changed. Call `tools/list` again before the next
call.

## Related

- [What agents can do](/build/apps/agents/agent-tools/) — the catalogue these routes serve.
- [How apps work on Facet](/build/apps/how-apps-work/) — the app model; MCP is not an app.
- [Governing the assistant](/admin/assistant/govern/) — mounts the same catalogue.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — the rights model.
- Internals on GitHub:
  [mcp.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mcp.md).
