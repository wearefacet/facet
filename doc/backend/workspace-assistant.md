# Workspace Assistant

The workspace assistant is the main-application chat surface. It reads,
creates, updates, and deletes live documents, runs named actions, computes
aggregates, and opens pages for the signed-in user. Every tool call runs
with the caller's own `RBAC::AuthContext`, so scoping, field visibility,
and denials are the same as on a REST call by that account. Availability is
one of the role's `connectivity` channels (`connectivity` must list
`assistant`), and the backend re-checks it on every streamed message.

**Source files:** `src/assistant/workspace.cr` (namespace root),
`src/assistant/workspace/context.cr`,
`src/assistant/workspace/system_prompt.cr` + `system_prompt.md`,
`src/assistant/workspace/skills.cr` + `skills/*.md`,
`src/assistant/workspace/registrar.cr`, `src/assistant/workspace/routes.cr`,
`src/assistant/routes.cr` (stream branch, ownership gates).

Shared services under `src/assistant/`:

| File | Module | Role |
|---|---|---|
| `src/assistant/access.cr` | `Assistant::Access` | Availability gate over role flags |
| `src/assistant/usage.cr` | `Assistant::Usage` | Per-account token ledger |
| `src/assistant/limits.cr` | `Assistant::Limits` | Usage-limit seam in the stream route |
| `src/assistant/tools.cr` | `Assistant::Tools` | Shared tool envelope + registry-schema adapter |
| `src/skill_files.cr` | `SkillFiles` | Skill-file loader (front-matter `.md`) |

Conversation and turn persistence is common to every assistant surface —
see [`agent-conversations.md`](agent-conversations.md). The document tools
come from the shared catalogue — see [`agent-tools.md`](agent-tools.md).
The same gates and streaming machinery also serve the per-app assistant
(the `app` conversation kind), which host applications embed through the
`@facetapp/chat` package — see [`app-system.md`](app-system.md) → Per-app
assistant and [`packages/chat.md`](../packages/chat.md).
The chat UI side is the `WorkspaceAssistant` floating window — see
[`../frontend/chat.md`](../frontend/chat.md).

## Conversation kind and ownership

A workspace conversation stores
`{"kind": "workspace", "created_by": <account id>}` in
`agent_conversations.context` (`Workspace::Context`).

- `"workspace"` is a reserved context kind, next to `"domain-builder"`
  (`Assistant::Routes::RESERVED_CONTEXT_KINDS`). The generic
  `POST /Api/assistant/conversations` route rejects it with `422`; only the
  dedicated create route writes it.
- The create route accepts a body with no fields. The backend owns the
  model, endpoint, system prompt, tool set, and context; the owner is always
  the caller, never a request-supplied value.
- The get, stream, list, and turns surfaces admit only the owner (or the
  system bypass). `ownership_check` compares `context.created_by` with the
  caller; a missing or non-string owner fails closed. On the list surface,
  the caller's account id is forced onto `context.created_by__eq`
  (`scope_list_to_owner`), so the kind filter and the owner filter
  AND-combine into one jsonb containment clause.

## Routes

| Method | Route | Description |
|---|---|---|
| `POST` | `/Api/assistant/workspace/conversations` | Create the conversation. Persists the workspace context, the built system prompt, and the workspace tool set. Returns `201` with the conversation record. |
| `GET` | `/Api/assistant/workspace/conversations/:id` | Not a read route. Answers the opaque `404 "Not found"` so the path never reaches the REST catch-all, which would resolve `assistant.workspace` as a document doctype (`"Unknown doctype: assistant.workspace"`). Reads go through the shared `GET /Api/assistant/conversations/:id`. |
| `GET` | `/Api/assistant/conversations` | Shared list. A real principal's list is scoped to rows it owns: a reserved-kind filter is forced to the caller's owner id, and a list that names no kind is scoped the same way. Non-reserved kinds stay shared. |
| `GET` | `/Api/assistant/conversations/:id` | Shared read; owner-only for a workspace conversation. |
| `GET` | `/Api/assistant/conversations/:id/turns` | Shared turns list; owner-only for a workspace conversation (`404` when the id is unknown). |
| `POST` | `/Api/assistant/conversations/:id/turns` | Shared turn write; owner-only for a workspace conversation — a turn injects replay context, so the next stream would resume from it. |
| `POST` | `/Api/assistant/conversations/:id/stream` | Shared streaming route. Resolves the kind, runs the workspace gates, wires `Workspace::Registrar.register` plus `argument_tools = {"navigate", "show_documents"}`. |
| `POST` | `/Api/assistant/cancel/:turn_token` | Shared cancel. |
| `GET` | `/Api/assistant/usage` | The caller's rolling-window usage meter: `{total, budget, window_start, window_days}` from one `Usage.total_for_account` call plus `Access.effective_budget`. `budget: null` means unlimited. Authenticated callers only (`401` for the bypass / anonymous principals). |

## Gates

The workspace create route checks CSRF → authentication → access, in that order.
The stream route checks CSRF → existence (`404`) → ownership → access gates →
usage limit, in that order, and writes every denial as a JSON response before
the SSE headers go out.

| Gate | Where | Denial |
|---|---|---|
| CSRF | every state-changing route | `403` when `X-Requested-With` is missing |
| Authentication | workspace create route | `401` when the request carries no real account id |
| Ownership | get / stream / list / turns | `403` when `context.created_by` does not name the caller; fail closed. Runs for reserved-kind conversations only — a non-reserved kind passes untouched |
| Access (create) | workspace create route | `403` when `Access.allowed?` is false; no row is written |
| Access (per message) | stream route, `workspace` kind only | `403` when the caller's active role's connectivity excludes the `assistant` channel; a role flip applies on the next message |
| App gate | stream route, `app` kind only | `403` from `App::Gate` when the token does not name the conversation's app, the app is not live, or the active role lacks `assistant_access`; re-reads the app on every message |
| Usage limit | stream route | `Limits.allow?` runs before the SSE headers; the route answers `false` with a JSON `429` |

The access gates are kind-scoped. The workspace access gate runs only when the
conversation's context resolves to the `workspace` kind; the app gate runs only
for the `app` kind. Both helpers return `true` untouched when their context is
nil, so no other kind hits them. The kind-less generic surface
(`POST /Api/assistant/conversations` with no `kind`) is ungated by design: on
its stream only the usage-limit seam runs. No tools mount for it either —
`build_tool_registrar` installs an empty registrar when no builder, workspace,
or app context is present.

## Access service

`Assistant::Access` (`src/assistant/access.cr`) rides the one-active-role
invariant: RBAC runs exactly one active role per request and roles never
merge (see [`rbac.md`](rbac.md)), so the gate reads the `assistant`
connectivity channel off that role alone. The former ANY-over-held-roles
aggregation is retired.

| Method | Returns |
|---|---|
| `Access.role_enabled?(content)` | True when the role projection's content lists `assistant` in its `connectivity` array; a missing or malformed field reads as off. |
| `Access.allowed_for_role?(db, role_id)` | `true` when the named role (`iam.Roles.<name>`) lists `assistant` in its `connectivity` array. A missing projection fails closed. |
| `Access.allowed?(db, auth_context)` | System bypass: `true`. Every other principal without a loaded active role (anonymous, preview): `false`. A real principal: its active role's channel list — `ActiveRole.role_id` holds the bare name, the gate qualifies it to `iam.Roles.<name>`. |
| `Access.effective_budget(db, account_id)` | `nil` (unlimited) when any enabling role has no `assistant_token_budget`; otherwise the maximum budget among the enabling roles |

Access and budget are asymmetric on purpose: access asks "may this active
role open the assistant" (one role, per request), budget asks "how much
may this account spend" (MAX over held roles). A role that merely enables
the assistant never changes the budget, and switching the active role
never moves it. A malformed budget value reads as unset (fail-open —
unreachable through the mutation path since the field gained `min: 0`).

## Tools

`Workspace::Registrar.register(agent, db, context, auth_context)` mounts
the tool set on the streaming turn's `Agent`. The `db` connection is
captured by the UI-tool callbacks; the streaming route runs the whole turn
inside `Database.with_db`, so it stays valid for the turn's lifetime.

| Tool | Kind | Callback |
|---|---|---|
| every `AgentTools::Registry` entry except `ping` | document | Delegates to `AgentTools::Registry.execute(auth_context, name, args_json)`. A `ToolError` renders as the error envelope with the registry's structured payload as `details`. Schema, description, caps, and RBAC all come from the catalogue — see [`agent-tools.md`](agent-tools.md). |
| `read_skill` | skill | Returns a workspace skill's raw markdown body. Unknown name → error envelope. |
| `navigate` | UI | Validates the target shape; a document target additionally requires read access (`projection` exists, not a tombstone, `ReadEnforcer` allows). The frontend builds the URL from the forwarded arguments. |
| `show_documents` | UI | Partitions the requested ids into `rendered` (readable) and `skipped`. A skip covers missing, tombstoned, and denied alike — the reason is never disclosed. `display` is `card` (default) or `inline`. `ids` must be a non-empty array of string ids (the schema declares `items: string` + `minItems: 1`); a malformed `ids` argument fails with the received shape named in the error text (for example `empty array`, `non-string item at index 0 (number)`). |

Toolset parity: the mounted document tools are exactly
`AgentTools::Registry.entries` minus `ping`, so the workspace agent sees
the same toolset an MCP client of the same role sees, and new registry
entries land here automatically. The full name list is
`Registrar.tool_names` (document tools + `read_skill` + the two UI
tools); the create route persists it onto `agent_conversations.enabled_tools`
so `Agent#load` can re-enable it on resume.

UI-tool names are listed in `Registrar::UI_TOOL_NAMES`. The streaming route
forwards their raw `arguments` on the `tool_call` chunk
(`Stream::ToolTraceHandler` + `argument_tools`); non-UI tools never carry
`arguments` on the wire. All callbacks return the shared `Assistant::Tools`
envelope (`{"ok":true,"data":...}` / `{"ok":false,"error":...}`), except
`read_skill`, whose success path returns the raw markdown body — same rule
as the domain builder.

Document tools run under the caller's identity. Their mutations carry the
account's own channel like a REST write, and each delegated call also rides
a root `assistant` cause into the write services (`Document::Create` /
`Update` / `Delete`), so `mutations.cause_kind = "assistant"` marks an
LLM-driven write and audit viewers can tell it from a plain session edit.
`call_action` is the exception, same rule as on MCP: the action name is
the more precise provenance, so those mutations keep their `action` cause.

## Prompt

`Workspace::SystemPrompt.build` concatenates two parts:

- The static body, embedded at compile time from `system_prompt.md` —
  identity, the `get_schema`-first etiquette (naming the write tools
  `create_document`, `update_document`, `call_action`), RBAC honesty (a
  denial is final), delete discipline, and when to use `show_documents` /
  `navigate` / `aggregate_documents`.
- One static runtime suffix — a short `## Session context` block that tells
  the model the client's advisory `Page context` line is not intent.

The create route also reads the operator's custom instructions
(`Assistant::CustomPrompt.block` — the `assistant.system_prompt` setting,
then the file value) inside its transaction and passes the formatted
`## Custom instructions` block to `build`, which appends it at the very end.
The user-language directive (`## Language`, from the create body's
`language` field — see [`assistant.md`](assistant.md) → Language) lands
between the Session context and the custom block. Both are baked into the
row at creation; a settings change reaches only new conversations. See
[`assistant.md`](assistant.md) → Custom instructions.

Without a custom block — and across conversations created under the same
one — the prompt is byte-identical, so the prefix the provider KV-cache
hashes stays hot across turns and conversations.

## Connection resolution (effective settings)

The model connection is not pinned per conversation. Every streaming turn
resolves it from the effective runtime settings
(`SystemSettings::AssistantView.build` in `Stream::Session#build_agent`):
`api_endpoint`, `api_key` (revealed from the secret store), `model`, and the
sampling knobs (`max_tokens`, `temperature`, `max_history`,
`auto_execute_tools`). A settings save reaches existing conversations on
their next turn; endpoint, key, and model resolve together because they are
provider-coupled. Same-provider model switches are the verified path; a
cross-provider switch stays a documented limit (see
[`system-settings.md`](system-settings.md) → Hot-reload mechanics). The
conversation-stored system prompt wins over the setting; the per-turn model
lands on the `assistant_usage` ledger row.

## Skills

The skill corpus lives with the shared tool catalogue in
`src/agent_tools/skills/`; every file's YAML front-matter carries a
required `surfaces` allow-list — the agent surfaces whose `read_skill`
serves it (`workspace`, `mcp`). The workspace serves six files; the
model loads them on demand through `read_skill`.

| Name | Contents |
|---|---|
| `filter-grammar` | The `field__op` filter grammar for `list_documents` and `aggregate_documents` — operators per field type, special keys, sorting, paging, caps. |
| `documents-workflow` | The discover → inspect → query → act loop for document work, with the label, refusal, and delete discipline. |
| `aggregate-reference` | The `aggregate_documents` kinds — the money per-currency bag, empty sets, caps, field-visibility refusals. |
| `relations` | Child documents through `parent_id`, qualified reference values, and the membership recipe for many-to-many links. |
| `longtext` | Writing longtext fields — document capsules, file links, and images through `urn:facet:` markdown links, the traps (bare URNs, state pins), and the verify step. |
| `chat-etiquette` | Chat-only etiquette — `show_documents` / `navigate` use. Tagged `workspace` only, so an MCP session cannot resolve it. |

`Workspace::Skills` (`src/assistant/workspace/skills.cr`) filters the
corpus to the workspace surface; loading and front-matter parsing live
in the shared `Facet::SkillFiles` loader (`src/skill_files.cr`). Two
specs pin the contract: the corpus spec (`spec/agent_tools/skills_spec.cr`)
fails when a file omits `surfaces` or names an unknown surface, and the
prompt spec pins this prompt's skill bullets against the corpus.

## Usage ledger

Every streamed turn of a billable account writes one `assistant_usage`
row — success, cancelled, and terminal-error turns alike. `Assistant::Routes.handle_stream`
computes the caller's billable account id (`nil` for the system bypass
and the anonymous principal), and `Stream::Session` inserts the row at the
turn's terminal path:

- **Success** — the provider-reported counts, unestimated.
- **Cancelled** — the response's reported counts when the provider
  delivered them before the abort; otherwise an **estimate** (see below).
- **Terminal error** — reported counts only. No output was delivered, so
  there is nothing to siphon, and estimating would overcharge turns that
  failed before the provider processed the prompt.

Zero-usage turns insert nothing. A ledger failure logs and keeps the turn
row — `agent_turns.usage` stays the source of truth. Rows the provider
never reported on are marked `estimated` on the ledger row (the turn row
keeps the reported zeros).

The anti-siphon estimate covers the hole where a client cancels mid-stream
and receives the partial answer: OpenAI-style providers report usage only
in the final chunk, which an abort never delivers, so agent-cr finishes a
cancelled turn with zeroed metadata. The Session then bills ~4
chars/token (`Stream::Session::CHARS_PER_TOKEN` — the only heuristic in
the feature): streamed content + reasoning characters as output, the
serialized prompt (full history, user message included) as input.

A workspace conversation can only be streamed by its owner, so every row
attributes to the account that caused the turn.

| Method | Description |
|---|---|
| `Usage.insert(db, account_id, conversation_id, turn_id, model, input_tokens, output_tokens, estimated = false, recorded_at = nil)` | Writes one ledger row. `recorded_at` defaults to `now()`; the explicit form lets specs place rows inside or outside a query window. Callers run on their own connection. |
| `Usage.total_for_account(db, account_id, since, to)` | Sums `{input, output, total}` over a `recorded_at` window. `since` is inclusive, `to` exclusive; bounds convert to UTC. An unknown account returns zeros. |
| `Limits.allow?(db, account_id)` | The enforcement seam. `handle_stream` calls it before the SSE headers and answers `false` with a JSON `429`. A rolling 30-day window of total tokens (`Usage.total_for_account`, `recorded_at >= now - 30 days`, open upper bound) compared against `Access.effective_budget`: `total >= budget` denies, so a budget of `0` means "no tokens" and an unset budget skips the sum. Domain-builder turns share the ledger and the rule. |
| `Limits::WINDOW_DAYS` | The rolling window length (30). `assistant.usage_retention_days` must be `0` or above this value — the prune warns when it is not. |

The `assistant_usage` table (migration `db/migrations/0005_assistant.sql`)
carries no foreign keys: rows outlive conversations, so deleting a
conversation never erases billing history. Column reference in
[`agent-conversations.md`](agent-conversations.md).

### Retention

`Cron::AssistantUsagePrune` (`src/cron/assistant_usage_prune.cr`, task id
`assistant.usage_prune`, schedule `assistant.usage_prune_cron`) bounds the
ledger. A row is prunable when both hold:

- It is older than `assistant.usage_retention_days` (`recorded_at` check).
- Its conversation has not been updated within that window, or its
  conversation row is gone. The anchor is conversation staleness
  (`agent_conversations.updated_at`), so every row of a live conversation
  stays however old, and a quiet conversation's rows go prunable
  together. The ledger carries no FK, so rows of a deleted conversation
  survive until they age past the window.

The `recorded_at` age floor keeps every usage query window up to the
retention window correct: the rolling 30-day token budget
(`Assistant::Limits` via the role `assistant_token_budget` field) reads at
most 30 days back, so a window of 31 or more days never deletes a row a
budget check can still see. A window of 1–30 days under-counts every live
budget; `AssistantUsagePrune.call` logs a warning when the configured
window lands inside the budget's query range — warn, never clamp: the
config stays the source of truth.

`usage_retention_days` defaults to `0` — never prune. The ledger grows
unbounded until an operator opts in; the daily pass then runs as a silent
no-op until the window is set.

| Method | Description |
|---|---|
| `AssistantUsagePrune.call` | Runs one prune pass with the window from config. A window of `0` or less returns before opening a connection. |
| `AssistantUsagePrune.prune(db, retention_days)` | Deletes prunable rows in `LIMIT`-bounded batches (batch size 1000). Returns the count of rows deleted. A window of `0` or less deletes nothing. |

## Availability payload and role fields

`GET /Api/iam/me` returns `assistant: {access: bool, token_budget: int?, name: string}`
and `connectivity: [string]` (the active role's channel list, `[]` for a
missing role — the frontend hides the affordances the channels govern).
The meanings are asymmetric (see the Access service above): `access` is
the **active role's** `connectivity ∋ 'assistant'` answer (read off the
role content `/me` already loads for the permission manifest — one role
query), while `token_budget` is the **largest budget over the account's
held roles** (`Access.effective_budget`). `name` is the instance's
assistant display name (`assistant.name` on `core.SystemSettings`; the
file tier always yields a value, default `Assistant`). The frontend gates
the assistant toggle on the channel, the usage meter on the budget, and
renders `name` on every assistant surface — the workspace and builder
windows and the top-bar pill.

The role doctype definition carries the two fields
(`data/seeds/iam.Roles/definition.yml`):

| Field | Type | Meaning |
|---|---|---|
| `connectivity` | array of string, default `[]` | The programmatic channels the role may use — closed vocabulary: `mcp`, `webhook`, `api`, `assistant`. Requests whose active role lists `assistant` may use the workspace assistant; an empty list is a workplace-only (browser) role. Browser access is never governed here. The `iam.Roles` hook validates the vocabulary on create and update. |
| `assistant_token_budget` | integer, `min: 0`, optional | Token cap over a rolling 30-day window for accounts this role enables; empty = unlimited. The role form edits it behind an explicit **Unlimited** switch (checked → the field unsets to `null`). The budget applies only when the role also lists `assistant` in `connectivity`. |

The seeded roles carry all four channels
(`data/seeds/iam.Roles/documents.yml`) — seeds are fixtures and
demonstrate everything; `anonymous` stays `[]`.
