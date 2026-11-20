# Agent Tools (shared tool catalogue)

`AgentTools` is the one catalogue of LLM-callable document tools. A tool's
name, description, input schema, and handler exist once, here; the MCP
resource server exposes the catalogue to external agents, and the assistant
registrars mount the same entries onto in-process agents (the workspace
assistant's mount — every entry except `ping` — lives in
[`workspace-assistant.md`](workspace-assistant.md)).
One catalogue keeps the toolset identical across surfaces — same
capabilities, same RBAC, same caps, same error mapping.

**Boundary — document tools only.** The catalogue carries no
schema-authoring tools: no domain or doctype create/update, no `/check`,
no publish. `create_document` enforces the composition rules of an
already-registered doctype (the `member_of` parent gate), it does not
register doctypes. Schema authoring belongs to REST/UI (`POST
/api/core/DocType`, `PUT /Api/core/DocType/:id`, the draft-domain
endpoints — see [`draft-domains.md`](draft-domains.md)) and to the
in-process domain-builder assistant, whose schema tools are scoped to a
verified draft domain (see [`assistant.md`](assistant.md)).

**Source files:** `src/agent_tools.cr` (facade),
`src/agent_tools/registry.cr`, `src/agent_tools/discover.cr`,
`src/agent_tools/read.cr`, `src/agent_tools/write.cr`,
`src/agent_tools/sidecar.cr`, `src/agent_tools/history.cr`,
`src/agent_tools/artifacts.cr` (upload/download capabilities),
`src/agent_tools/errors.cr`, `src/agent_tools/caps.cr`,
`src/agent_tools/skills.cr` (skill corpus + surface filter).
The MCP protocol layer around the catalogue lives in
`src/mcp/` — see [`mcp.md`](mcp.md).

## Public API

| Call | Purpose |
| --- | --- |
| `AgentTools.call(auth_context, name, arguments)` | Executes one tool under the caller's `AuthContext`. Returns the JSON payload; raises an `AgentTools::ToolError` subclass on failure. An optional root `Mutation::Cause` rides into the write services — `nil` (the MCP path) keeps each write's default root `request` cause; the workspace registrar passes a root `assistant` cause. |
| `AgentTools.list_for(auth_context)` | Role-filtered tool listing (`Definition` records: name, description, input schema). A system principal gets no listing (fail closed). |
| `AgentTools.service_error(err, context)` | Maps a `Facet::ServiceError` to the tool-error taxonomy (403 → `RbacDenied`, 404/410 → `NotFound`, 422 → `InvalidParams`). |
| `AgentTools.mark_stale` / `current_generation` | Staleness signalling for role-filtered listings (see [mcp.md](mcp.md) → invalidation). |
| `AgentTools::Registry.execute` | The dispatch the facade wraps; what a registrar's tool callback delegates to. Takes the same optional root cause. |
| `AgentTools::Registry.entries` / `visible_entries` | All entries / the role-permitted subset. |

`Registry::Entry` carries `name`, `description`, `input_schema` (JSON-Schema
object), `requires` (`:none` / `:read` / `:write` / `:action`), and the
handler. `Registry::Context` hands the handler a db connection plus the
caller's `AuthContext`.

## Tool catalogue

| Tool | `requires` | Service called | Purpose |
| --- | --- | --- | --- |
| `ping` | `:none` | — | Server identity + the mounted role. Always visible to a real principal. MCP-session probe; assistant registrars exclude it. |
| `list_domains` | `:read` | `projections` scan | Live `core.Domain` rows (drafts excluded). Not grant-filtered by design — see Visibility. |
| `list_doctypes` | `:read` | `projections` scan | Doctypes of one domain. |
| `get_schema` | `:read` | `Doctype::DefinitionStore` | Full doctype definition: fields, actions, scopes, `member_of` (the parent doctype, on a child), and the host's `sidecars` map (segment → sidecar doctype + reference column, emitted only when non-empty). Read before any write. |
| `whoami` | `:none` | `IAM::Helpers.build_permission_manifest` | The caller's identity and access: `{account: {id, display_name}, role, permissions, scopes, visible_tags}` — the same manifest `/Api/iam/me` serves. Fields whose `tags` fall outside `visible_tags` are omitted from all results. |
| `list_documents` | `:read` | `Document::List.call` | `field__op` filter grammar, sort, page, items capped by `max_result_rows`; oversized payload sets `meta.truncated` + `next_cursor`. `meta.total` never counts the has-more probe row: on a truncated page it is the rows the page returned; on the final page it is the exact count of matching rows from the page offset onward (the full match count when `page` is 1). `truncated: true` + `next_cursor` (the next page number) means another page exists. Validates filter keys against the doctype first → `InvalidParams`, and the operator against the field's declared `filters` set (`Document::FilterCompiler.allowed_operators`) → `InvalidParams` — an unservable operator fails loud instead of compiling to `FALSE` or being dropped. Optional `parent_id` scopes the list to one parent's children — child doctypes only, and the parent must be readable (same gate as the nested REST route; no read grant on the parent doctype → `RbacDenied`; a missing parent, or one a grant holder cannot see → non-disclosing `NotFound`). Every row's `meta` carries `display_name` — the row's computed human label, `null` when the doctype declares no template. Optional `expand` (reference field names) attaches a `resolved` map (D1 side map — rows keep their ids; when the byte cap cuts rows, the resolved entries only those rows referenced are cut with them); optional `fields` projects each row's content; optional `scope` applies one of the doctype's named scopes as a query filter (`$self` and context sets bind to the calling account; RBAC clauses are untouched — a query-time scope only narrows). |
| `aggregate_documents` | `:read` | `Document::List.call(aggregate:, field:)` | `count` (empty items, capped total), or `sum`/`avg`/`min`/`max` over a top-level `integer`/`duration`/`money` field (`field` required except count). Money returns the `{currency => amount}` bag. Same filter grammar and `parent_id` parent gate as `list_documents`; RBAC scope and field visibility apply; optional `scope` applies a named scope as a query filter. |
| `get_document` | `:read` | `Document::Read.call` | One document by id. Meta carries `parent_id` for a child document and `display_name` — the computed human label, `null` when the doctype declares no template. Optional `expand` (reference field names) attaches a `resolved` map (`urn → {id, domain, doc_type, display_name, data}`) next to `data`; optional `fields` projects the content to the named fields. No read grant on the doctype → `RbacDenied`; a tombstone, or a document a grant holder cannot see → non-disclosing `NotFound`. |
| `create_document` | `:write` | `Document::Create.call` | Full-content create inside a transaction with `Event::Publisher.flush`. Optional `parent_id` creates a child under a readable parent — the same gate as the nested REST route (child doctype with `member_of` only; missing or denied parent → non-disclosing `NotFound`; a child doctype without `parent_id` is refused, mirroring the flat-create guard). The parent row is re-checked live under the create transaction's lock (`lock_live_projection_for_update`, B-276), so a parent deleted between the gate and the create — or a system-bypass caller, whose parent gate skips the row check — fails with `NotFound` instead of landing an orphan. A sidecar doctype is refused with the flat-route hint before validation runs — the flat-create block lives in `Document::Create` itself, so every flat path (agent tools, compound creates) reports it instead of the missing-`target` schema error. Validation failures → `InvalidParams` whose message names the failing fields and whose `data.details` carries the structured per-field errors. |
| `update_document` | `:write` | `Document::Update.call` | JSON merge patch (RFC 7386) under `lock_with_chain`: new keys are set, a `null` value removes the key from the document (the way to clear a field — it lands as an `unset` diff entry, never `set: null`). Same transaction + flush. |
| `delete_document` | `:write` | `Document::Delete.call` | Soft delete / tombstone. Returns `{data: null, meta: {deleted: true, mid}}`. |
| `batch` | `:write` | `Create`/`Update`/`Delete`/`Action` in one transaction | Ordered atomic writes: `{op: create\|update\|delete\|action, …}` bodies identical to the single tools. Every op is validated before the transaction opens; a service failure rolls the whole batch back and raises `InvalidParams` naming the op index (`data.op_index`, `data.reason: batch_op_failed`). The direct-write ops share one causal trace; an action op keeps the action's own cause (same rule as `call_action`). One `Event::Publisher.flush` after the commit. Op count capped by `mcp.max_batch_ops` → `Capped`. |
| `call_action` | `:action` | `Document::Action.call` | Named doctype action with typed `args`. Unknown action → `NotFound`; bad args → `InvalidParams` with the action's arg diagnostics. |
| `create_sidecar` | `:write` | `Document::SidecarHandler.create` | Host-scoped sidecar create — the MCP shape of `POST /Api/:domain/:doctype/:id/:segment`, generic over every sidecar doctype. Args: host `domain`/`doctype`/`doc_id`, the `segment` (a key of the host's `sidecars` map — an unknown one → `InvalidParams` naming the declared segments), and `content` (the sidecar body; the host's reference column is set by the route and must be omitted). The two REST gates run in the handler: host read (no read grant on the host doctype → `RbacDenied`; a missing host, or one a grant holder cannot see → `NotFound`) plus the nested create grant (read-only role → `RbacDenied`); flat grants on the sidecar doctype do not participate. The sidecar's Lua create hook forces its ownership anchor (`author`, `uploaded_by`); the caller's cause rides into the mutation. |
| `list_sidecars` | `:read` | `Document::SidecarHandler.list` | Host-scoped sidecar list — one host's segment, paged, with the same envelope and `total` semantics as `list_documents`. The nested read grant applies (a host read grant implies it); flat-only grants → `RbacDenied` (the nested read grant is class-level). |
| `list_mutations` | `:read` | `Audit::List.call` | Document history, or — with no `doc_id` — the whole workspace (global mode; needs the wildcard `*.*` read grant, `domain`/`doctype` act as filters, never as gates). Filters (`__op` suffixes): `action`, `actioner_id`, `app`, `channel`, `kind`, `trace` (`eq`/`ne`), `emitted_at` (`gte`/`lte`). Validates filter keys first → `InvalidParams`, and the operator against the per-column set → `InvalidParams` — an unservable operator fails loud instead of being dropped. |
| `resolve_refs` | `:read` | `Document::Resolve.call` | Batch URN resolution: one stub row per found document (`{data: content, meta}` — `meta.display_name` carries the label), tombstoned/denied/unknown URNs omitted (non-disclosing). Input list capped by `max_result_rows` → `Capped`; optional `fields` projects the content. Serves the inline links of longtext fields and `links` entries. |
| `get_links` | `:read` | `Document::Read.call` | Projection `links` column (outbound links — the URNs this document points to; the inverse query is `get_backrefs`). Document references only — `urn:facet:artifact:<id>` links and `file`-field values are never included (an artifact is not a document and is deliberately not parseable as one); use `list_artifact_refs` for those. Read-gated. |
| `get_backrefs` | `:read` | `Document::Backrefs.call` | The live documents that point at one document — the inverse of `get_links`, served by the partial GIN index on `links`. Delegates to the shared service (`src/document/backrefs.cr`, also behind the HTTP `/backrefs` endpoint). Per readable doctype, the `links @>` query AND-composes that doctype's `list_where_clauses`; unreadable doctypes are skipped silently, tombstoned referrers are excluded (the partial index), and a `?state=`-pinned URN is a distinct reference that never matches the live target. Target read gate first (no read grant on the target doctype → `RbacDenied`; a missing target, or one a grant holder cannot see → non-disclosing `NotFound`). `capped` reports honestly when the result set reaches the `max_result_rows` cap. |
| `search_documents` | `:read` | `Document::List.call` per readable doctype | Cross-doctype search: the bare `search` filter fanned out over every readable doctype (optional `domain` narrows; per-doctype matches capped at 5). A doctype that declares no `search` template still matches through its display label — the write path stages the folded `display_name` as a fallback corpus (B-115; see [`search.md`](search.md)). Returns `{domain, doc_type, id, display_name}` stub rows grouped per doctype, capped by `max_result_rows` / `max_response_bytes`. Unreadable doctypes are skipped; RBAC scope clauses still apply inside each list. |
| `request_artifact_upload` | `:write` | `Artifact::UploadGrants.mint` | One-time signed upload capability for a file artifact. Returns `{upload_url, method, field, filename}` + `meta {expires_at, max_bytes}`; the agent's HTTP client POSTs the multipart `file` part to the URL (no bytes ride the tool arguments, so the MCP envelope caps never bound a file), then puts the returned artifact id into a document (a `file` field value or a `urn:facet:artifact:<id>` longtext link — the re-attach flow appends the owner row). Optional `size_bytes` is checked against `max_upload_bytes` up front → `InvalidParams`. The URL is single-use, TTL-bound (`artifact.upload_grant_ttl_seconds`), and bound to the calling principal; consume revalidates account + role live. See [`artifact.md`](artifact.md) → Signed upload capability. |
| `get_artifact` | `:read` | `Artifact::Grants.mint_ephemeral` | Short-lived signed download URL for one artifact the caller can read (provenance-based; unknown → `NotFound`, tombstone → `NotFound` with the deleted note, denial → `RbacDenied`). Returns `{id, filename, mime_type, size, download_url}` + `meta {expires_at}` — the agent fetches the bytes with a plain HTTP GET. TTL follows the media-aware grant rules (1 h documents/images, 6 h audio/video); re-call the tool for a fresh URL. |
| `list_artifact_refs` | `:read` | `Artifact::Refs.call` | The live documents that currently reference one artifact — both `file`-field placements and inline `urn:facet:artifact:<id>` longtext links (the `artifact_references` rows). Artifact gate first: unknown, tombstoned, ownerless, or denied → one non-disclosing `NotFound` (stricter than `get_artifact`, whose denial surfaces as `RbacDenied`). Referrers are filtered per record: each `(domain, doc_type)` group is AND-composed with that doctype's `list_where_clauses`, so a referrer can never leak past the caller's list visibility; unreadable groups are skipped silently, so an empty list means "no references you can see". No total over all references (it would leak unreadable cardinality) — `meta.total` counts returned rows; `capped` reports the `max_result_rows` stop honestly. Rows carry `{id, domain, doc_type, display_name, field, last_reference_at}`. The operator counterpart is the unfiltered `read *.*`-gated `GET /Api/Artifacts/:id/references` (`Artifact::Admin.references`). |

## Visibility, caps, errors

Visibility is a convenience for the agent, never a boundary. `list_for`
checks each entry's `requires` tag against the active role's permission map
(`:action` matches any non-reserved action line). Enforcement always runs at
call time in `ReadEnforcer` / `WriteEnforcer`, exactly as on REST.

The discover tools (`list_domains`, `list_doctypes`, `get_schema`) are not
grant-filtered. The domain catalogue and the schema metadata are not user
data: they describe what the installation can store, not what the caller
may read. A caller with one read grant sees every live domain and doctype.
Every `list_documents` / `get_document` call still runs through
`ReadEnforcer`, so the metadata never widens access to a row.

Response caps: `items` is clamped to `mcp.max_result_rows` at query time; the
serialized envelope is checked against `mcp.max_response_bytes` — an
oversized result is cut, with `meta.truncated: true` and a `next_cursor`
(the next page number) instead of a failure.

| Error class | Meaning | MCP JSON-RPC code |
| --- | --- | --- |
| `InvalidParams` | bad arguments (unknown field, bad shape, bad aggregate); the message names the offending field or argument, and a 422 from a service carries the structured details in `data.details`. Unknown argument keys (keys no handler reads) are rejected centrally in `Registry.execute` — `InvalidParams` naming the key and the accepted set — before dispatch, on every surface | `-32602` |
| `RbacDenied` | role lacks the permission, or holds no grant on the doctype at all — the class-level denial every read and write gate answers (never names the failed line) | `-32603` |
| `NotFound` | unknown domain/doctype/document/action; a document a grant holder cannot see (non-disclosing); tombstones (non-disclosing) | `-32602` |
| `Capped` | result exceeded a governance cap | `-32603` |
| `ToolError` | fallback | `-32603` |

Every raise site carries a machine-readable `data` payload. The stable
shape is `{reason: …}` plus error-specific keys:

| `reason` | Class | Extra keys |
| --- | --- | --- |
| `invalid_params` | `InvalidParams` | `argument` — the malformed argument name |
| `unknown_argument` | `InvalidParams` | `argument`, `tool` — a key no handler reads (rejected centrally in `Registry.execute`) |
| `unknown_field` | `InvalidParams` | `field` — a filter field the doctype (or the audit column set) does not declare |
| `unsupported_operator` | `InvalidParams` | `field`, `operator` — an operator the grammar does not serve for that field |
| `unknown_tool` | `NotFound` | `tool` |
| `not_found` | `NotFound` | optional `deleted: true` on a tombstone |
| `rbac_denied` | `RbacDenied` | — (never names the failed line) |
| `capped` | `Capped` | `cap` — the governance cap value |

A 422 from a write service carries its structured per-field errors in
`data.details` — each entry is `{field, message, code, params}` (`field`
and `params` nil for non-field errors such as script rejections or RBAC).

The toolset rule for agent surfaces: a tool defined in the catalogue is
available to every surface; mounting all entries except `ping` is the
default, and an exclusion is a deliberate decision recorded with the
consuming surface.

One tool is deliberately not a catalogue entry: `read_skill`, the
skill-file loader, is mounted per surface (`src/mcp/skills.cr` for MCP;
the workspace registrar for the chat) because the surface is a property
of the mount. It serves the shared corpus in `src/agent_tools/skills/` —
markdown references for the catalogue's tools — and every file's
front-matter carries a required `surfaces` allow-list (`workspace`,
`mcp`). The loader filter is hard: a surface cannot resolve a skill not
tagged for it, and an untagged corpus (the domain-builder's,
`src/assistant/domain_builder/skills/`) resolves on no shared surface.
The corpus spec (`spec/agent_tools/skills_spec.cr`) pins the contract: a
file without `surfaces`, or naming an unknown surface, fails the suite.
MCP answers `read_skill` with the `{skill, title, body}` envelope; the
assistants return the raw markdown body (their tool runner avoids
double JSON-escaping).

No catalogue entry may take the `read_skill` name — the registry spec
(`spec/agent_tools/tools_spec.cr`) pins it — so a surface's intercept
can never silently shadow a registry tool.

Attribution follows the same shape: the direct write
tools (including `create_sidecar`) stamp the calling surface's cause
(`request` by default, `assistant` for the workspace registrar), while
`call_action` keeps the action's own cause — the action name is the more
precise provenance.
