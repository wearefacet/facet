# Assistant

The AI Assistant system wraps the `agent-cr` shard to provide an LLM-powered conversational agent within Facet.

## Files

- `src/assistant.cr` — Namespace root.
- `src/assistant/config.cr` — `Facet::Assistant::Config` struct.
- `src/assistant/tools.cr` — `Facet::Assistant::Tools` shared tool envelope (`ok` / `error`), the `tool_mutation` write wrapper, and the registry-schema adapter.
- `src/skill_files.cr` — `Facet::SkillFiles` generic loader for skill `.md` corpora.
- `src/assistant/access.cr` — `Facet::Assistant::Access` workspace availability gate.
- `src/assistant/custom_prompt.cr` — `Facet::Assistant::CustomPrompt` the operator's custom-instructions block.
- `src/assistant/language.cr` — `Facet::Assistant::Language` the user-language directive block.
- `src/assistant/usage.cr` — `Facet::Assistant::Usage` per-account token ledger.
- `src/assistant/limits.cr` — `Facet::Assistant::Limits` usage-limit seam.
- `src/assistant/conversation.cr` — `Facet::Assistant::Conversation` storage service (`agent_conversations` table).
- `src/assistant/turn.cr` — `Facet::Assistant::Turn` storage service (`agent_turns` table).
- `src/assistant/resume.cr` — `Facet::Assistant::Resume` service (reconstruct an `Agent` session from stored rows).
- `src/assistant/stream/cancel_bus.cr` — `Facet::Assistant::Stream::CancelBus` Redis Pub/Sub cancel fan-out.
- `src/assistant/stream/session.cr` — `Facet::Assistant::Stream::Session` one-turn SSE streaming orchestrator.
- `src/assistant/routes.cr` — `Facet::Assistant::Routes` HTTP routes (`/Api/assistant/...`).
- `src/assistant/app/context.cr` — `App::Context` the `app` conversation kind (`KIND = "app"`; context built from the server-side caller, never the body).
- `src/assistant/app/gate.cr` — `App::Gate` per-app availability gate (live `assistant_enabled` read + the active role's `assistant` connectivity channel + app-scoped caller).
- `src/assistant/app/registrar.cr` — `App::Registrar` the app toolset (full `AgentTools::Registry` minus `ping`, no skills, no UI tools).
- `src/assistant/app/routes.cr` — `App::Routes` the dedicated create route.
- `src/assistant/app/system_prompt.cr` — `App::SystemPrompt` prompt assembly for the kind.

See [`agent-conversations.md`](agent-conversations.md) for the conversation persistence schema, the replay/resume procedure, and the HTTP route table.

## Conversation kinds

`agent_conversations.context` names what a conversation is for. Four kinds are in service:

| Kind | Creation route | Runs as | Documented in |
|---|---|---|---|
| *(no kind — generic)* | `POST /Api/assistant/conversations` | The caller's auth context, no document tools | This file (persistence in [`agent-conversations.md`](agent-conversations.md)) |
| `domain-builder` | `POST /Api/assistant/domain-builder/conversations` | System-tier principal, draft-domain tools | This file, below |
| `workspace` | `POST /Api/assistant/workspace/conversations` | The caller's auth context, shared catalogue tools | [`workspace-assistant.md`](workspace-assistant.md) |
| `app` | `POST /Api/assistant/app/conversations` | The calling app's auth context (grant-ceilinged), full catalogue tools | [`app-system.md`](app-system.md) → Per-app assistant, and [`packages/chat.md`](../packages/chat.md) for the embedding package |

The two named kinds own a dedicated creation route and an owner in `context.created_by`; the generic create route rejects them so a forged context cannot slip past the dedicated route's gate, and the read surfaces (get / stream / list / turns) scope them to the owner.

## Custom instructions

The `assistant.system_prompt` system setting carries the operator's custom instructions for the assistants. `Assistant::CustomPrompt.block` (`src/assistant/custom_prompt.cr`) resolves it — the settings document first, then the file value — and formats it as one markdown block, `## Custom instructions`, with the text under it. Nothing set appends nothing; a whitespace-only value means the same.

Both named kinds bake the block into the prompt at conversation creation. The create routes read the setting inside their transaction (`CustomPrompt.block(db)`) and pass the block to the prompt builder:

| Kind | Where the block lands |
|---|---|
| `workspace` | Appended after the static body and the Session context suffix (`Workspace::SystemPrompt.build(custom)`) |
| `domain-builder` | Appended after the template's "Session context" section — the very end of the prompt (`DomainBuilder::SystemPrompt.build(context, custom)`) |
| `app` | Appended at the end, after `## App instructions` (`App::SystemPrompt.build(custom)`; empty appends nothing) |

The generic kind does not take the block: the setting is that kind's whole persona (an API-only surface).

## Language

The client sends the user's current language as a BCP-47 tag in the `language` field of a conversation-create request; the frontend driver injects its i18n locale (`getLocale` from paraglide) when the caller omits it. `Assistant::Language.block` (`src/assistant/language.cr`) formats the tag as one markdown block, `## Language`, which states the language and tells the model to write all replies in it — unless the user explicitly asks for another language in the conversation. A tag that is absent, blank, or not a valid BCP-47 tag appends nothing.

All three named kinds take the block. They place it after the Session context and before the custom-instructions block; the generic kind appends it after its `assistant.system_prompt` setting text. Like the custom block, the language block is baked once at creation and never re-read on later turns.

Cache semantics: the full prompt — template, session context, custom block — is baked once at creation and stored on the row; turn starts reuse the stored row (`AssistantView.build` passes `session.conversation.system_prompt`). A settings change reaches only **new** conversations. Within a conversation the prompt is byte-stable across turns, so the provider KV prefix stays hot; across conversations the static template stays byte-identical.

## Public API

### `Facet::Assistant::Config`

Configuration struct that maps to `Agent::Config`. Holds the API endpoint, model, system prompt, and agent behaviour settings.

| Property | Type | Default | Description |
|---|---|---|---|
| `name` | `String` | `"Assistant"` | Display name shown on every assistant surface. The runtime settings document pins it (`assistant.name`); the file and this default are the fallback tiers |
| `api_endpoint` | `String` | `"https://Api.openai.com/v1"` | OpenAI-compatible API endpoint |
| `api_key` | `String?` | `nil` | API key for authentication |
| `model` | `String` | `"gpt-4o"` | Model identifier |
| `system_prompt` | `String?` | `nil` | System prompt / persona |
| `max_history` | `Int32?` | `nil` | Max conversation turns (nil = unlimited) |
| `max_tokens` | `Int32?` | `nil` | Max completion tokens |
| `temperature` | `Float64?` | `nil` | Sampling temperature (0.0–2.0) |
| `auto_execute_tools` | `Bool` | `true` | Auto-resolve registered tool calls |
| `cancel_ttl_seconds` | `Int32` | `15` | TTL (seconds) for Redis cancel keys emitted by the streaming cancel bus |

#### `.to_agent_config`

Returns an `Agent::Config` instance populated from the assistant config, suitable for constructing an `Agent`.

```crystal
config = Facet::Assistant::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  model: "gpt-4o",
  system_prompt: "You are a helpful data assistant."
)
agent = Agent.new(config.to_agent_config)
```

## Configured state — running without the assistant

The assistant is optional. The three connection keys read the file through `!env?` (`src/util/yaml_tag.cr`), so an installation that exports no `FACET_AI_API_ENDPOINT` / `FACET_AI_API_KEY` / `FACET_AI_MODEL` boots normally: the endpoint and model fall back to their defaults and the key stays `nil`. An installation can also enable the assistant at runtime — the sealed `assistant.api_key` slot (plus endpoint and model pins) in the system settings document wins over the file, with no restart.

"Configured" means one thing everywhere: an API key resolves through the same order `AssistantView.build` uses (sealed slot, then file). `SystemSettings::AssistantView.configured?` (`src/system_settings/views.cr`) is that check.

| Surface | Behaviour when not configured |
|---|---|
| `GET /Api/iam/me` | The assistant block carries `configured: false` beside `access`. The two flags are independent: `access` asks what the active role may open, `configured` asks whether the installation has a provider at all |
| Frontend dock | Stays visible when the role has access. Conversation creation and the composer disable with a message that tells the user no AI assistant is configured and names system settings as the fix. The `ChatPanel.stories.svelte` `Unconfigured` story pins this |
| `POST /Api/SystemSettings/assistant/test` | Answers `422` naming `assistant.api_key` before any wire call — the operator-facing probe for the settings page |

Conversation-create and turn routes keep no separate gate: without a key, the provider call fails at the transport and the turn settles as an error row, the same path a revoked key takes.

## Tool-call arguments

The tool callbacks receive the model's raw `arguments` JSON, parsed and
passed through as-is. Optional arguments follow JSON-Schema semantics:
absent means the documented default (no filter, page 1, the row cap), and
the server never invents a value the model did not send. A filter key that
names no rows is also not an error — it returns an empty result.

Two schema and message guarantees keep a retrying model effective:

- Array properties declare `items` (and `minItems` where the callback
  requires a non-empty array).
- A rejected argument names what arrived: `got nothing` (the key is
  absent), `got null`, `got empty array`, `got non-string item at index 0
  (number)`, and so on.

The `items` declaration is load-bearing. On a prompt dominated by large
tool-result payloads, a tool-calling model degenerates: array arguments
for an untyped `array` property arrive as `[]` or whitespace-only arrays,
and even required scalar arguments can go missing — while the model's own
reasoning says it passed them. The trigger is payload volume, not message
count: the same conversation with stubbed tool results emits every
argument correctly, and the same volume without `items` keeps emitting
empty arrays across retries (the model cannot see the gap between what it
meant and what it emitted, so it never self-corrects). Declaring `items`
removed the degeneration in a like-for-like replay of a recorded failure.

To audit what the server actually received, read the persisted turn:
`agent_turns.response_messages` stores the assistant `tool_calls` with the
exact `arguments`; for pre-assembly evidence, the streaming chunks carry
the raw argument deltas. Keep list payloads small (`mcp.max_result_rows`,
`max_response_bytes`) — large result sets are the trigger, and a big
history is the normal state of a working assistant conversation.

## Streaming turns

`Stream::Session` runs one turn over SSE. The event sequence is `meta`
(cancel token) → `chunk*` (content, reasoning, `tool_call` trace) → one
terminal `done` / `error` / `cancelled` event. The cancel token is
generated by the stream route before the turn row opens; the row persists
it (`agent_turns.turn_token`) and the `meta` event carries it, so a client
that reloads mid-turn can read the token back from the turns API and still
cancel the in-flight turn. Every terminal path completes the `agent_turns`
row opened at turn start; see [`agent-conversations.md`](agent-conversations.md)
for the row schema and the status table.

**Usage metering.** The ledger bills every turn that delivered output: a
turn whose provider reported token counts bills them unestimated, and a
turn with no report — the common streaming case, since the provider
request does not ask for usage reports — bills the streamed-chars
estimate (marked `estimated`). This keeps the role token budget effective
against providers that report nothing on streamed responses. Terminal
failures that delivered nothing still bill reported counts only.

**Truncated streams.** A provider stream that closes before any chunk
carries a `finish_reason` is a truncation, not a success. Two wire shapes
land on the truncation exit path: a clean close (the drain loop ends, the
final state carries a nil `finish_reason` with no error and no cancel),
and a hard mid-stream drop (a socket close mid-body — agent-cr surfaces
it as a `ConnectionError` carrying the raw IO message). A drop takes the
truncation exit when streamed content reached the client, and also when
the turn committed tool-call history (`agent.history` past the turn
boundary) with no text chunk — a tool-call-only drop is still a partial
exchange. A drop with nothing delivered and no committed history stays a
provider error, and other mid-turn errors such as an idle timeout keep
their own classes. Either way: the partial exchange
persists in `response_messages` for the audit trail, the ledger bills
through the cancel path (reported counts, else the streamed-chars
estimate), and the client receives a terminal `error` event instead of
`done`. The turn row is `status = "error"`, `finish_reason` nil, `error`
set to `truncated: provider stream ended before the response completed` —
the `truncated: ` prefix distinguishes it in the audit trail from provider
errors and the sweep's `interrupted`.

**Capped turns.** The tool-loop cap is its own class: when agent-cr raises
`Agent::ToolLoopError`, the turn ends `status = "capped"`, not `error`.
agent-cr does not roll back history on this path — every iteration
completed — so the partial exchange persists in `response_messages`, the
raw cap message lands in `error`, and the ledger bills through the
anti-siphon path (reported counts, else the streamed-chars estimate). The
client sees the same terminal `error` SSE event as before, carrying the
raw cap message. Unlike an `error` row, a capped turn replays: the next
ask continues from the committed tool-call work.

An `error` row does **not** feed `Resume`: only `done`, `cancelled`, and
`capped` turns replay (see [`agent-conversations.md`](agent-conversations.md)
→ `Assistant::Resume`). A truncated row therefore keeps its partial for
inspection but never enters the model's next context. An `error` row with
non-empty `response_messages` means the failure hit after output or tool
results started (truncation); an empty one means it hit before (provider
error, unexpected exception, sweep).

**Mid-turn checkpoints.** While the turn runs, the session persists the
committed exchange into the `running` row every `CHECKPOINT_INTERVAL`
(2 s) as the drain loop receives chunks. Three guards keep a checkpoint
honest: the snapshot must have grown since the last write, the throttle
window must have passed, and the slice must not end on a dangling
assistant tool_calls message (its results are not appended yet — an
invalid provider prefix). `Turn.checkpoint` updates `running` rows only,
so a late checkpoint never clobbers a terminal row. The `turns/latest`
payload carries the row's messages, so a reloaded client renders
progressive output instead of a bare thinking placeholder.

**Request-message split.** Every persisted slice — terminal or checkpoint —
drops the turn's own user messages (`drop_request_messages`). agent-cr
appends the user message to `agent.history` at `ask` start, and `Resume`
already concatenates `request_messages`; keeping both would replay the user
message twice.

**Slice anchors.** The persisted slices anchor on the turn's own messages,
not on a pre-ask index. agent-cr's `trim_history!` (a finite
`assistant.max_history`) fires once per turn right before the response
finishes and drops a prefix of the history, so a pre-ask index goes stale:
the slice would lose the turn's leading messages, or raise `IndexError`
when the trim dropped more messages than the turn appended. Where the
request messages stay in history, the anchor is the turn's user message
(the last user-role message — when the trim consumed it, every older
message went with it). Where agent-cr rolled the request messages back
(a hard provider drop, and the checkpoint that can race one), the anchor
is the pre-ask history size, clamped to the array — the drop path never
trims, and an older turn's user message must never become the anchor.

**Tool-call trace.** Every executed tool call emits `tool_call` chunks
(`status: "running"`, then `"ok"` or `"error"`) so the client renders the
live trace bar. Calls rejected before the callback runs — invalid JSON
arguments or schema-validation failures — flow through agent-cr's handler
chain too, so they emit the same `running` → `error` pair. The error
result string (`Error parsing arguments for tool '…'`, `Error validating
arguments for tool '…'`, `Error executing tool '…'`) is both the
model-visible tool result and the chunk's `result` field. A model
retrying a schema-rejected call is user-visible as repeated error rows in
the trace instead of a silent loop to the iteration limit.

**Repeated refusals.** The app and workspace registrars count identical
refused tool calls per turn with `RefusalGuard`
(`src/assistant/refusal_guard.cr`). The first two identical refusals
return the normal error envelope. The third returns a terminal envelope
whose text tells the model the refusal is final. agent-cr does not read
the `terminal` flag, so the session also registers a
`TerminalRefusalStop` handler
(`src/assistant/stream/terminal_refusal_stop.cr`) on each turn's agent.
A first terminal envelope for a call is recorded, and the model gets one
more provider call to comply. A second terminal envelope for the same
call cancels the response, and the turn ends through the standard
cancelled path (`status = "cancelled"`, partial history kept for
resume). The extra provider cost is bounded: at most one call follows
the first terminal envelope for a call.

## Dependencies

- **`agent-cr`** (shard) — Core agent loop with streaming, tool calling, history management, and handler middleware. See <https://github.com/anykeyh/agent.cr>.

## pgvector prerequisite

The `vector` extension (pgvector) is the prerequisite for document embeddings for retrieval-augmented generation (RAG) in assistant conversations. The assistant system owns this prerequisite. It is recommended, not enforced: `db/migrations/0001_document_store.sql` enables the extension only when the server provides it, so a stock `postgres` image deploys fine and RAG features stay disabled until the extension is installed. No `vector` column exists today; the RAG work will add its columns as an additive migration (no data risk).

`compose.test.yml` and `e2e/compose.yml` keep their `pgvector/pgvector` images so the development and test stacks run the RAG-ready configuration.

## Domain Builder Assistant

The domain builder is the first specialised assistant mode: it runs inside a draft domain and can create, update, validate, and smoke-test doctype definitions, document view templates, and sample documents via tool callbacks. It is the LLM-powered path for the create → check → update → re-check loop.

### Files

- `src/assistant/domain_builder.cr` — Namespace root.
- `src/assistant/domain_builder/context.cr` — `Context` struct (typed view of the conversation's `context` jsonb).
- `src/assistant/domain_builder/auth.cr` — `Auth` module (system-tier `AuthContext` for the assistant).
- `src/assistant/domain_builder/system_prompt.cr` — `SystemPrompt` builder (interpolates draft domain, target name, description).
- `src/assistant/domain_builder/skills.cr` — `Skills` loader (reads `.md` skill files from `src/assistant/domain_builder/skills/`).
- `src/assistant/domain_builder/tools.cr` — `Registrar` module (registers all 25 tools onto an `Agent`).
- `src/assistant/domain_builder/tools/read_tools.cr` — 12 read-only tool callbacks.
- `src/assistant/domain_builder/tools/write_tools.cr` — 11 draft-scoped write tool callbacks.
- `src/assistant/domain_builder/tools/ui_tools.cr` — 2 frontend-rendered UI tool callbacks.
- `src/assistant/domain_builder/routes.cr` — HTTP route for conversation creation.
- `src/assistant/domain_builder/skills/*.md` — 16 good-practice skill files.

See [`domain-builder-skills.md`](domain-builder-skills.md) for the skill-file inventory and the fixture reference for authoring document view templates.

### Auth model

The assistant runs as a **system-tier principal** (`AuthContext.system("system:assistant")`). RBAC is fully bypassed (every enforcer returns `true` when `auth_context.system?`); the draft-domain scoping is enforced inside each write tool callback via the `ensure_*` helpers in `Registrar`.

Write-tool mutations are attributed to the **conversation owner**. Each write tool builds its auth context with `Auth.auth_context_for(context)`, which wraps the owner's account id (stored in `context.created_by` at conversation creation) in a system-tier context — so `actioner_id` on the mutation row is the account that asked for the change, while the RBAC bypass and draft scoping stay unchanged. Every write-tool mutation also carries the root `assistant` cause named `domain-builder` (`Registrar::WRITE_CAUSE`); the seeded default CollectionView joins the same causal cluster via `cause_parent`. The audit surfaces therefore render these rows as the owner's account via an `Assistant · domain-builder` cause chip, not as `system:assistant` via `internal`. Conversations whose stored context lacks `created_by` fall back to the bare `system:assistant` principal.

Conversation creation is gated by `write core.DocType` AND `write core.Domain` on the **originating account's** real `AuthContext` (checked in the HTTP route via `RBAC::WriteEnforcer.authorize_create`).

**Preview-capability callers.** While a preview session is active, the frontend's `apiFetch` overlays the preview Bearer on every request, so the create call arrives as a `Principal::Preview` bound to one draft. The route authorises on the capability itself — it was issued only after the caller's real identity proved `update core.Domain` on that draft (the preview-session gate) — and binds the conversation to the token's `preview_domain`: an absent `draft_domain` binds to it, a matching one passes, a mismatching one answers `403`. A preview caller never mints a fresh draft. `created_by` stays the caller's real account id (the preview principal carries it), so attribution and the ownership gates are unchanged. The schema edits the tools make still ride the system-tier registrar; the preview token itself remains data-only on the REST surface.

### HTTP route

| Method | Path | Description |
|---|---|---|
| `POST` | `/Api/assistant/domain-builder/conversations` | Create a conversation + draft domain. Body: `{target_name?, description?, draft_domain?, language?}`. Returns `201` with the conversation record. A preview-capability caller (see Auth model) is bound to the token's draft instead. |

The streaming endpoint is the same `POST /Api/assistant/conversations/:id/stream` as for any other conversation. The streaming route detects a domain-builder conversation via `Context.from_conversation_context(conversation.context)` and, on a hit, wires `Registrar.register` as the `tool_registrar`.

### Prompt

`DomainBuilder::SystemPrompt.build` embeds `system_prompt.md` at compile time and substitutes the session context (draft domain, target name, description) at the end. The template carries a capability map — what the builder can write (draft-scoped), what it can read (any domain), what it cannot do (publish the draft, edit grants or context sets) — the full 16-skill list, and the create → check → update → re-check workflow with the collection-view steps. `spec/assistant/domain_builder/system_prompt_spec.cr` pins the prompt's skill list against `Skills.names` — a new skill file without a prompt entry fails the suite. The user-language block and the operator's custom-instructions block append after the session context — language first, custom instructions last (see [Custom instructions](#custom-instructions) and [Language](#language)).

### Tools (25)

All tool callbacks return a JSON string in the shared `Facet::Assistant::Tools` envelope (`src/assistant/tools.cr`). Success: `{"ok":true,"data":...}`. Error: `{"ok":false,"error":"...","details":[...]}`.

**Exception:** `read_skill` returns the skill's raw markdown body on success (no envelope) — the body already begins with a `# Title` heading. Returning it raw avoids JSON-escaping the markdown. Errors still use the standard envelope.

| Name | Scope | Description |
|---|---|---|
| `list_domains` | read | List all live `core.Domain` projections. |
| `list_doctypes` | read | List doctype summary rows for a domain (default: draft). |
| `get_doctype` | read | Full doctype definition via `DefinitionStore.fetch_uncached` (cross-domain). |
| `get_domain` | read | Full `core.Domain` projection content. |
| `list_documents` | read | `Document::List.call` in draft domain. |
| `get_document` | read | `Document::Read.call` in draft domain. |
| `list_document_views` | read | List `core.DocumentView` summary rows for a draft doctype. |
| `get_document_view` | read | Read a `core.DocumentView` template by doc_id (draft-scoped). |
| `list_collection_views` | read | List `core.CollectionView` summary rows for a draft doctype. |
| `get_collection_view` | read | Read a `core.CollectionView` by doc_id (draft-scoped). |
| `check_doctype` | read | `Doctype::Check.call`, returns issues array. Includes view checks: template validation of the doctype's `core.DocumentView` children (warnings) and missing standard view kinds (`view`, `form`, `quickView`, `inline`, `card` — informational notices, not counted as issues). |
| `read_skill` | read | Returns a skill `.md` body by name. |
| `create_doctype` | draft | `Doctype::Create.call` with draft guard on `definition.domain`. |
| `update_doctype` | draft | `Doctype::Update.call` with draft guard on existing projection. |
| `delete_doctype` | draft | `Document::Delete.call` on `core.DocType`. |
| `create_document_view` | draft | `Document::Create.call` on `core.DocumentView` with `parent_id` meta override. The template tree is validated by `Doctype::ViewTemplateValidator` — structural errors and binding errors (unknown/dotted input field paths, container-bound inputs) reject with a `details` array; warnings return in `data.warnings`. The auto `input` node is the preferred form binding — it renders the control from the field's declared type; specialized `input-*` nodes force overrides. |
| `update_document_view` | draft | `Document::Update.call` on `core.DocumentView`. The replacement template tree is validated the same way against the parent doctype definition. |
| `delete_document_view` | draft | `Document::Delete.call` on `core.DocumentView`. |
| `create_collection_view` | draft | `Document::Create.call` on `core.CollectionView` with `parent_id` meta override. |
| `update_collection_view` | draft | `Document::Update.call` on `core.CollectionView`. |
| `delete_collection_view` | draft | `Document::Delete.call` on `core.CollectionView`. |
| `create_document` | draft | `Document::Create.call` in draft domain (smoke test). |
| `delete_document` | draft | `Document::Delete.call` in draft domain. |
| `preview_view` | UI | Frontend-rendered: the callback validates and acks; the chat UI renders the DVT/collection preview from the chunk's `arguments` with fake data. Registered before the draft-domain check. |
| `go_to_page` | UI | Frontend-rendered: the callback validates `page`; the frontend navigates the builder from the chunk's `arguments`. Registered before the draft-domain check. |

UI-tool names are listed in `Registrar::UI_TOOL_NAMES`; the streaming session forwards their raw `arguments` JSON on the `tool_call` chunk (see `Stream::ToolTraceHandler#argument_tools`). Non-UI tools never carry `arguments` on the wire.

### Skills (16)

Plain `.md` files with YAML front-matter under `src/assistant/domain_builder/skills/`. Loading and front-matter parsing live in the shared `Facet::SkillFiles` loader (`src/skill_files.cr`); each corpus is read once on first use and held in memory.

| Name | Description |
|---|---|
| `doctype-anatomy` | DoctypeDefinition structure, identity rules, aggregate_root vs member_of, nav_visible sidebar flag, display/search fields |
| `field-types` | Every FieldType with when-to-use, constraints, nested schemas, computed fields, reference filters |
| `lifecycle-scripts` | Lua module pattern, ctx table, create/update/delete hooks, validate hook, computed fields, migrations |
| `lua-document-helpers` | `document.*` globals for inter-document operations from Lua scripts, `pcall` error handling |
| `lua-actor` | `ctx.actor` RBAC surface in Lua hooks, force-ownership-on-create pattern |
| `named-scopes` | Scopes declaration, where grammar ($self, literals, $<context_set>, $null) |
| `replication` | Replicate config, grants on core.Domain, reference-scoped semantics, draft inertness |
| `document-views` | core.DocumentView children, parent_doctype, kind enum, template node vocabulary |
| `dvt-layouts` | Document view template layout patterns for the view, form, quickView, and inline surfaces, plus the cross-cutting layout rules |
| `collection-views` | core.CollectionView children, meta.parent_id linkage, surface/config, general vs personal owner_id |
| `children-and-composition` | children declaration, parent→child convention, parent_id meta, cascade delete, sidebar visibility (nav_visible) |
| `rbac-context-sets` | context_sets on core.Domain, from/where/select, DAG resolution |
| `display-and-identity` | display_name and search templates (Jinja2), color, identifier sequential ids |
| `reference-patterns` | Qualified reference storage, owner_id convention, N-N membership pattern, reference filters |
| `validation-and-check` | Validation (hard) vs Check (soft) comparison, issue categories |
| `iteration-workflow` | The create → check → update → re-check loop, how to read error details |