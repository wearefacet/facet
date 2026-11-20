# MCP Resource Server

The MCP (Model Context Protocol) surface lets an external agent act on
Facet as a delegated account under one fixed role. Facet is the MCP server,
in-process: Kemal mounts `/Api/_mcp/:role_slug` inside the Facet binary.
Facet is an OAuth 2.1 **resource server** on that surface — it validates
tokens minted by the existing `/OAuth/*` endpoints and issues none of
its own.

**Source files:** `src/mcp.cr`, `src/mcp/routes.cr`, `src/mcp/dispatch.cr`,
`src/mcp/skills.cr`, `src/mcp/protected_resource.cr`,
`src/event/subscriber/role_cache.cr`.

The shared tool catalogue these routes serve lives in `src/agent_tools.cr` +
`src/agent_tools/*.cr` — see [`agent-tools.md`](agent-tools.md).

## Core invariants

- **The URL pins the role.** Each `:role_slug` is one role for the lifetime
  of the session. There is no in-session role switching; to change hats the
  user mounts a different URL.
- **The role parameter carries the qualified role id.** The authorize `role`
  parameter and the URL slug hold the qualified projection id
  (`iam.Roles.admin`), never the bare role name — bare names are ambiguous
  across domains. A bare name answers `400 invalid_request` naming the shape
  ("the role parameter is the qualified role id, e.g. `iam.Roles.admin`").
- **MCP is not an app.** No `app.App` row backs it, no grant intersection
  applies (`app_grant_permits?` is never invoked), and the regular
  role-only RBAC enforcement applies exactly as on REST.
- **No system principal.** The dispatch path asserts the built context is a
  real principal; `AuthContext.system` is mechanically rejected.
- **Exact-match audience.** The token's `aud` must equal this route's
  resource identifier — an absolute URI from config, never derived from the
  `Host` header.
- **MCP is a data plane.** The catalogue is document-level only: read,
  write, action, history, sidecar tools over registered doctypes. It
  exposes no schema-authoring tools — no domain or doctype create/update,
  no `/check`, no publish. Schema authoring is a REST/UI concern (`POST
  /Api/core/DocType`, `PUT /Api/core/DocType/:id`, the draft-domain
  endpoints — see [`draft-domains.md`](draft-domains.md)) plus the
  in-process domain-builder assistant, whose write tools are scoped to a
  verified draft domain (see [`assistant.md`](assistant.md)). An external
  agent authors a domain over REST and consumes it over MCP.

## Endpoints

| Route | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/Api/_mcp/:role_slug` | POST | Bearer (aud-pinned) | JSON-RPC over Streamable HTTP — `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call` |
| `/Api/_mcp/endpoints` | GET | Browser session / app token / API key (cookie or Bearer) | Directory of the caller's held-role MCP URLs (Settings page) |
| `/.well-known/oauth-protected-resource` | GET | none | RFC 9728 PRM document, parameterized by the `resource` query string |

Unauthenticated calls to the MCP endpoint receive `401` with
`WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource"`
so a spec-compliant client discovers the authorization server on its first
call. No CORS checks run on this surface — MCP clients are server-to-server.

## Endpoint directory (Settings page)

`GET /Api/_mcp/endpoints` returns one endpoint per held role, sorted by
role id:

```json
{
  "endpoints": [
    { "role": "iam.Roles.editor", "url": "https://…/Api/_mcp/iam.Roles.editor" }
  ]
}
```

`AuthHandler` skips the `/Api/_mcp/` prefix (the resource server verifies
MCP tokens itself on POST), so the route builds its context through
`AuthHandler.auth_context_from_request` — cookie or Bearer session
machinery. MCP tokens carry `aud` and are rejected by the REST `aud`
rule, so a role-pinned token cannot enumerate the account's other roles.

The URLs come from `MCP.resource_identifier` — the exact string dispatch
compares the token `aud` against. Clients must render them verbatim and
never derive them from their own origin: a non-Caddy origin would mint
links whose `aud` fails the exact-match check.

## Dispatch chain

Every request runs this chain before any tool dispatch:

1. Token decodes and verifies (ES256, alg-pinned).
2. `aud` equals `https://<host>/Api/_mcp/<role_slug>` exactly.
3. URL `:role_slug` equals the token's `role` claim.
4. Account is `active` and not soft-deleted; role projection exists.
5. `AuthContext.mcp` is built (the pinned role rides as `acting_role`);
   `system?` asserted false.

Dispatch wraps execution in a per-`sid` semaphore
(`mcp.max_concurrency_per_sid`) so parallel agent traffic cannot exhaust
the shared DB pool. `tools/list` runs inside the same slot — a stale
roles generation forces a registry rebuild from the DB, so the listing
is not free.

MCP queries run on the **shared** connection pool under
`database.statement_timeout_ms` — no separate MCP pool exists. The row
and byte caps (`mcp.max_result_rows`, `mcp.max_response_bytes`) bound
response size; the shared statement timeout bounds query duration.

## Token issuance (OAuth branch)

An MCP client discovers the authorization server through the RFC 9728 PRM
document, then self-registers through RFC 7591 dynamic client registration
(`POST /OAuth/register`, advertised as `registration_endpoint` in the
AS metadata — see [`oauth.md`](oauth.md) → Dynamic client registration).
Registration is stateless: the client_id is an opaque public-client id, and
the consent screen plus PKCE carry the security.

The existing authorize/token endpoints branch on the RFC 8707 `resource`
parameter. When `resource` names a per-role MCP identifier:

- `Authorize.build_mcp_consent` / `issue_mcp_code` skip `app.App` loading
  and `GrantResolver`; they validate the pinned `role` against the account's
  held roles (reject outright — no silent fallback) and record `resource`
  + `mcp_role` into the code. The elected role's `connectivity` must also
  carry the `mcp` channel (`iam.Roles.connectivity`): the pinned consent
  screen denies a channel-less role with the same `access_denied` shape as
  an unheld role, and `issue_mcp_code` denies the election with a
  redirect-eligible `AccessDenied`. Delegated app tokens (the non-`resource`
  branch) are never gated by the field.
- `Token.call` mints an access token with `aud` + `role` and **no `app`
  claim**, backed by a browser-session-shaped Redis session (empty `app`).
- Refresh dispatches on session shape: MCP sessions revalidate account-active
  + role-held + the `mcp` connectivity channel only (`Refresh.call_mcp` — a
  role that lost the channel loses its MCP sessions at the next refresh;
  the still-live access token stays valid to its TTL); app sessions keep
  grant revalidation (`Refresh.call`).

## Tool catalogue

The tools are the shared agent catalogue (`AgentTools`) — one definition per
tool serves MCP clients and the assistant registrars. See
[`agent-tools.md`](agent-tools.md) for the tool table, the `requires` tags,
the caps, and the error taxonomy.

`aggregate_documents` is the aggregates path both surfaces share: `count`
or `sum` / `avg` / `min` / `max` over a numeric field, with the same filter
grammar, row and byte caps, RBAC scope clauses, and field-visibility
enforcement as `list_documents`. A `money` field aggregates to the
per-currency `{currency => amount}` bag.

MCP-protocol behaviour on top of the catalogue:

- `tools/list` renders `AgentTools.list_for(auth_context)` — the
  role-filtered listing. Visibility is a convenience for the agent, never a
  boundary; the per-doctype enforcement stays in `ReadEnforcer` /
  `WriteEnforcer` at call time, exactly as on REST.
- Every write/action tool wraps its service call in
  `Database.with_transaction { |db| … ; Event::Publisher.flush }`. The
  `:action` requirement matches any role permission whose action is neither
  a reserved CRUD action (`read`/`create`/`update`/`delete`) nor the
  wildcard — i.e. a named action such as `hire` or `promote`.

`Event::Subscriber::RoleCache` subscribes to `fanout:iam.Roles:*`. On every
roles mutation it evicts the mutated role's entry from the process-local
role content cache (`IAM::RoleStore` — every role lookup, authenticated or
not, reads through it) and calls `AgentTools.mark_stale`; the next
`tools/list` rebuilds from the live permission map. Open sessions observe
the generation bump through the `MCP-Tools-Changed` response header and
re-list.

File artifacts move over HTTP, not through the tool arguments. The
`request_artifact_upload` tool mints a one-time signed upload capability;
the agent's HTTP client POSTs the multipart body to it (the capability
route revalidates the account + pinned role and lands the bytes through
the standard uploader under the `_account` owner convention), and the
agent then links the returned artifact id into a document with the write
tools. `get_artifact` mints a media-aware ephemeral download URL for any
artifact the pinned role can read. `list_artifact_refs` answers "where is
this artifact used" — the live documents whose `file` fields hold the id
or whose longtext embeds a `urn:facet:artifact:<id>` link (the
`artifact_references` rows, via `Artifact::Refs`): the artifact gate is
provenance-based (denied, deleted, and unknown ids all surface as one
non-disclosing `NotFound`), and every returned referrer passed its own
doctype's list scope — unreadable referrers are skipped silently, the
same non-disclosure as `get_backrefs`. Use it to verify a link landed (an
unlinked upload is swept by prune) and to survey usage before replacing
or deleting an artifact. All three tools are catalogue entries (serving
both surfaces) — see [`agent-tools.md`](agent-tools.md) and
[`artifact.md`](artifact.md) → Signed upload capability. No file content
ever rides the JSON-RPC channel, so the `max_response_bytes` cap never
bounds a file.

Beyond the catalogue the surface mounts one tool: `read_skill`
(`src/mcp/skills.cr`). It serves the shared skill corpus
(`src/agent_tools/skills/`) — short markdown references for the
catalogue's tools, front-matter-tagged `surfaces: [workspace, mcp]` (see
[`agent-tools.md`](agent-tools.md) → Toolset rule). The loader is not a
registry entry — the surface is a property of the mount, the same way the
assistant registrars mount their own — so `tools/list` appends it after
the catalogue and `tools/call` intercepts the name before
`AgentTools.call`. An MCP session has no server-side prompt, so the tool
description names the available skills and the `name` argument carries
an `enum` of those names, both built from the corpus front-matter at
request time; discovery costs no extra tool call. The `enum` is the
resilient channel — a client that truncates a long description still
forwards the valid values in the schema. Success
answers with the `{skill, title, body}` envelope; an unknown or
surface-untagged name (the chat-only etiquette skill, the domain-builder
corpus) raises `NotFound` whose `data` carries `skill` plus the
surface's `available` skill names — discovery on error, for a client
whose cached `tools/list` predates the current corpus. The list is
surface-filtered: it never names a skill this surface does not serve.
The corpus loads on first read and never reloads (see `SkillFiles`), so
a new or edited skill file shows up in the description and in
`available` only after a process restart. Skill files are static
reference documents with no tenant data, so no permission gate applies —
the loader serves every real principal.

## Mutation attribution

`Mutation::Client` takes the audit metadata as two structs: `Provenance`
(channel + `app` / `api_key` / `acting_role`) and `Cause` (kind/name/event/
source/parent/trace — see [`mutation.md`](mutation.md)). The dispatch chain
builds the request's `AuthContext` through `AuthContext.mcp`, which carries
the URL-pinned role as `acting_role`; the document services derive the
provenance from the context, so every mutation the write tools make stamps
`mutations.channel = "mcp"` plus `mutations.acting_role`, making the
one-role-per-session invariant auditable. Every authenticated channel
stamps `acting_role` with its elected role (see
[`mutation.md`](mutation.md) → the `mutations` table); the MCP-specific
part is the `channel = "mcp"` stamp plus the authorize-time pin — the
mounted URL fixes the role for the session's lifetime.

Direct mutations (`create_document`, `update_document`, `delete_document`)
are root mutations of kind `request`. `call_action` keeps the action's
cause (kind `action`, name = action name) — the action name is the more
precise provenance, and the MCP surface is carried by the channel.

## Configuration

Optional `mcp:` block in `config.{env}.yml`:

```yaml
mcp:
  max_concurrency_per_sid: 4   # per-session dispatch cap (tools/list included)
  max_result_rows: 200         # row cap applied by the list tools (documents, sidecars, history)
  max_response_bytes: 1048576  # byte cap applied to tool result envelopes
  max_batch_ops: 25            # op-count cap of the batch tool's ops array
```

Query duration is not an `mcp:` knob: MCP rides the shared pool, whose
`database.statement_timeout_ms` bounds every statement it issues.

## Quirks

- The resource identifier uses the configured `host`, assuming `https`
  when no scheme is present — same rule as `OAuth::Discovery`.
- `ActiveRole#role_id` holds the role's bare `name`; the token's `role`
  claim and the URL slug hold the qualified projection id
  (`iam.Roles.<name>`). Both spellings appear in audit output.
- `_mcp` (leading underscore) prevents collisions with a `mcp` custom
  domain, mirroring other reserved `_`-prefixed names.
