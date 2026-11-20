# Agent Conversations

**Files:** `db/migrations/0005_assistant.sql`, `src/assistant/conversation.cr`, `src/assistant/turn.cr`, `src/assistant/resume.cr`, `src/assistant/usage.cr`, `src/assistant/routes.cr`, `src/assistant/config.cr`, `src/assistant/stream/cancel_bus.cr`, `src/assistant/stream/session.cr`, `src/http/server.cr` (route registration + `DomainGate` bypass)

Persistent storage for AI Assistant conversations. Each conversation is one `Agent` session; each turn is one `Agent#ask` invocation. The structure is designed so that the full conversation history can be reconstructed byte-for-byte for replay, which keeps the provider's prompt KV cache hot (the cache keys on `prompt_cache_key` + the exact message prefix).

This is a standalone schema — it does **not** use the doctype/projections/mutations system.

---

## Services

The storage layer exposes three stateless services that compose cleanly
with `agent-cr`'s `Agent#dump` / `Agent#load` semantics. They persist
**primitives** — higher-level orchestration (HTTP routes, auto-wiring into
the agent loop) lives elsewhere and decides *when* to persist.

### `Assistant::Conversation` (`src/assistant/conversation.cr`)

| Method | Returns | Description |
|---|---|---|
| `.create(db, session_id, cache_key, system_prompt, context, enabled_tools)` | `Result::Created \| Error` | Inserts a conversation row. `session_id`/`cache_key` come from the live `Agent`; `context` and `enabled_tools` are jsonb strings. No model/config snapshot — the connection resolves live per turn |
| `.find(db, id)` | `Record?` | Fetches a conversation by primary key |
| `.touch(db, id)` | `Nil` | Updates `updated_at` — called by `Turn.create` |
| `.set_archived(db, id, archived)` | `Bool` | Stamps (`true`) or clears (`false`) `archived_at`. Answers `false` for an unknown id. Archiving is list-organisation only — see Archiving below |
| `.unarchive(db, id)` | `Nil` | Clears `archived_at` when set, no write for a live row. Called by `Turn.open` / `Turn.create` — activity on a conversation unarchives it |
| `.list(db, filters, sort, items, offset)` | `Array(Record)` | Lists conversations with filtering, sorting, and pagination. Default sort is `-updated_at`. Live rows only unless a filter asks otherwise (see below) |
| `.count(db, filters, items)` | `Int64` | Returns a count of conversations matching `filters`, capped at `items + 1` so the caller can compute `meta.more` without a full table scan. Applies the same archive visibility as `.list` |

#### Filtering and sorting on `.list`

The list endpoint follows the same conventions as `Document::List` (see [`doc/backend/filter-set.md`](filter-set.md)):

- **Filters** use the standard `field__op` convention, `{ "field__op": value }`.

| Filter family | Example | Semantics |
|---|---|---|
| `context.<key>__eq` | `{ "context.kind__eq": "test" }` | `context @> '{"key":"value"}'::jsonb` (jsonb containment). Multiple `context.*` filters are merged into a single jsonb object and applied as one predicate |
| `<column>__op` (text columns: `id`, `session_id`, `cache_key`) | `{ "session_id__eq": "s1" }` | `column = $1` / `IS DISTINCT FROM` / `ILIKE` |
| `<column>__op` (timestamp columns: `created_at`, `updated_at`) | `{ "updated_at__gte": "2025-01-01T00:00:00Z" }` | `column >= $1::timestamp` (supports `eq`/`ne`/`gt`/`gte`/`lt`/`lte`) |
| `archived__eq` | `{ "archived__eq": true }` | `true` → archived rows only. Without it (or with any other value) the list shows live rows only — archived conversations stay hidden until a caller asks for them |

Unknown filter keys are silently ignored, matching `Document::List`.

- **Sort** keys are validated against `{ id, created_at, updated_at }` and may be prefixed with `-` for descending. Default: `[-updated_at]`. Sending `sort=-created_at` produces `created_at DESC`.

#### Archiving

`archived_at` (nullable, tz-naive UTC) is a list-organisation state, not a
lifecycle: an archived conversation stays readable and streamable, and the
next turn clears the flag (`Turn.open` / `Turn.create` call `unarchive`). The
list hides archived rows by default; the rail's "show archived" toggle flips
to them with the `archived__eq=true` filter. Archiving does not touch
`updated_at` — that column stays "last turn activity". The HTTP surface is
`PATCH /Api/assistant/conversations/:id` with `{archived: true \| false}`.

#### `updated_at` bumping

`Turn.create` and `Turn.open` call `Conversation.touch`, so the parent's
`updated_at` is always in step with the latest turn. This is why the list
endpoint defaults to `-updated_at`: the conversation with the most recently
added turn surfaces first.

### `Assistant::Turn` (`src/assistant/turn.cr`)

| Method | Returns | Description |
|---|---|---|
| `.open(db, conversation_id, request_messages_json, turn_token = nil)` | `Result::Created \| Result::Conflict \| Error` | Opens a turn: inserts the `running` row with the request messages. `turn_token` is the streaming cancel token (the route generates it and passes the same value to `Stream::Session`). `idx` is computed `WITH next_idx AS (SELECT COALESCE(MAX(idx),0)+1 …)` in the same statement. The insert races on the partial unique index `idx_agent_turns_one_running` — the database decides, so a `Conflict` answer is authoritative |
| `.complete(db, turn_id, response_messages_json, usage_json, status, finish_reason, error)` | `Bool` | Flips the row to its terminal state. Targets the row by `id` alone, so a row swept to `interrupted` in the meantime is overwritten by the real outcome |
| `.create(db, conversation_id, request_messages_json, response_messages_json, usage_json, finish_reason, error)` | `Result::Created \| Error` | Inserts an already-terminal turn row (manual `POST /:id/turns`). The status derives from `error`: `"cancelled"` → `cancelled`, any other error → `error`, otherwise `done`. Callers should hold a transaction so the `MAX(idx)+1` read-then-write is atomic |
| `.create_terminal(tx, conversation_id, request_messages_json, usage_json, error)` | `Result::Created \| Error` | Inserts a standalone `error` turn inside an open transaction — the `Session#fail_terminal` fallback when `Turn.open` never produced a row |
| `.running_turn(db, conversation_id)` | `Record?` | The conversation's running row, or `nil`. The one-running invariant makes a single-row read sufficient |
| `.running?(db, conversation_id)` | `Bool` | True while the conversation has a `running` turn — the conversation `active` flag. One-row index probe on the partial unique index |
| `.running_conversation_ids(db)` | `Set(String)` | Every conversation id with a `running` turn — the batch read behind the conversation list's per-row `active` flag |
| `.latest(db, conversation_id)` | `Summary?` | The latest row (by `idx`) as a `Summary` (includes `turn_token` plus the row's `request_messages` + `response_messages`) — the catch-up poll's endpoint payload. The messages let a reloaded surface render the turn's progress while it runs |
| `.checkpoint(db, turn_id, response_messages_json)` | `Bool` | Writes the committed exchange into the `running` row mid-turn. The update targets `status = 'running'` rows only, so a late checkpoint can never clobber a terminal row. Called by `Stream::Session` on a ~2 s cadence |
| `.list(db, conversation_id)` | `Array(Record)` | Turns ordered by `idx` ascending |
| `.sweep_stale_running(db, timeout_seconds)` | `Int32` | Marks every `running` row older than the timeout `error` with message `interrupted`. Idempotent; called by `Cron::AssistantTurnSweep` |

#### Turn status lifecycle

The row exists from the moment the agent starts working, which makes an in-flight turn observable — the concurrent-stream guard, the catch-up poll, and the audit trail all read it.

| Status | Set by | Meaning |
|---|---|---|
| `running` | `Turn.open` (stream route, before SSE headers) | The agent is working. At most one per conversation (`idx_agent_turns_one_running`) |
| `done` | `Turn.complete` | Normal completion; `finish_reason` set |
| `cancelled` | `Turn.complete` | User cancel; `response_messages` keeps the partial reply, `error` is `"cancelled"`. A terminal refusal lands here too — when the model repeats a final refused tool call, `TerminalRefusalStop` cancels the response and the turn exits through this same path. Deliberate: no status, meta, or SSE field marks the refusal. The turn's tool trace is the only differentiator — the terminal envelope rides a `tool_call` chunk with `status: "error"` |
| `capped` | `Turn.complete` | The tool loop hit the agent's iteration cap; `response_messages` keeps the partial exchange, `error` carries the raw cap message. Replays on `Resume` |
| `error` | `Turn.complete` / sweep | Provider error, unexpected exception, or a process death caught by the sweep (`interrupted`); `response_messages` stays empty when no response was consumable |

### `Assistant::Resume` (`src/assistant/resume.cr`)

| Method | Returns | Description |
|---|---|---|
| `.call(db, conversation_id)` | `Result::Restored \| Error` | Rebuilds `history` by concatenating `request_messages` ++ `response_messages` across terminal turns and returns a ready-to-use `session_json` for `Agent#load`. The assistant connection is NOT reconstructed here — the caller builds it from the effective settings at turn start (`SystemSettings::AssistantView`) |

`Resume` includes only turns with a terminal, consumable outcome — `done`,
`cancelled` (partial response), and `capped` (the partial exchange the agent
committed before the tool-loop cap; the next ask continues from it).
`running` rows have no response yet; `error` rows are failed attempts —
including truncated turns that keep a partial `response_messages` — and the
provider never answered them as a consumable turn. Both are skipped so the
replay prefix stays clean and the KV-cache hash is stable.

`Resume` does **not** reconstruct tool callbacks — the caller registers them
on the new `Agent` from `context`, mirroring how `Agent#load` already requires
the app to re-register tools before loading.

### `Assistant::Routes` (`src/assistant/routes.cr`)

HTTP routes for assistant conversation storage. Pure CRUD — they do not call
live LLMs. Registered from `HTTP::Server.routes` (mirrors `IAM::Routes.register`).
All routes live under `/Api/assistant/...`, which is carven out of `DomainGate`
(the gate rejects unknown domains, so the assistant namespace must be
explicitly bypassed like `/Api/Audit` and `/Api/iam/`).

| Method | Route | Description |
|---|---|---|
- **`POST /Api/assistant/conversations`** | Create a conversation. Body: `{context?, enabled_tools?, language?}`. The backend owns the connection (endpoint, key, model), the system prompt, session_id, and cache_key; the prompt is captured from the effective settings at create, plus the `## Language` directive when the body carries a `language` tag
| `GET` / `QUERY` | `/Api/assistant/conversations` | List conversations, filtered + sorted + paginated via `ListRequest`. Default sort is `-updated_at`. Each row carries a derived `active` flag — true while the conversation has a `running` turn (`Turn.running_conversation_ids`, one batch read). Supports `filters[context.<key>__eq]=...` for jsonb context filtering, plus standard column filters on `id`/`session_id`/`cache_key`/`model`/`created_at`/`updated_at`. A real principal's list is scoped to rows it owns: a reserved-kind filter is forced to the caller's owner id, and a list that names no kind is scoped the same way; non-reserved kinds stay shared |
| `GET` | `/Api/assistant/conversations/:id` | Fetch a single conversation (404 if not found). The payload carries the derived `active` flag (`Turn.running?`) |
| `PATCH` | `/Api/assistant/conversations/:id` | Archive or unarchive. Body: `{archived: true \| false}` (missing or non-boolean → 422). CSRF-checked, owner-gated like every single-conversation surface; returns `{data: <conversation>}` |
| `GET` | `/Api/assistant/conversations/:id/turns` | List turns of a conversation (`idx` ASC). Each row carries its `turn_token` when the stream route opened it. Like get / stream, owner-gated: a conversation whose context names a reserved kind admits only its owner (404 when the id is unknown) |
| `GET` | `/Api/assistant/conversations/:id/turns/latest` | Latest turn summary (`Summary`; includes `turn_token` plus the row's `request_messages` + `response_messages`), or `{data: null}` for a conversation with no turns. Owner-gated like the list. The catch-up poll reads it — a reloaded surface also reads the running row's `turn_token` here to re-arm its cancel button, and renders the row's messages while the turn runs |
| `POST` | `/Api/assistant/conversations/:id/turns` | Record a turn. Body: `{request_messages, response_messages, usage, finish_reason?, error?}`. Run inside a transaction (per `Turn.create`'s contract). Owner-gated like the turns list — a turn injects replay context, so a non-owner must not write it |
| `POST` | `/Api/assistant/conversations/:id/stream` | SSE streaming endpoint. Body: `{content, attachments?}`. Generates the turn cancel token, opens the `running` turn row (token persisted) before the SSE headers (so 404/500 stay clean JSON and a conflicting request is a clean 409), then sets `text/event-stream` + `X-Accel-Buffering: no` and emits `meta`/`chunk`/`done`/`error`/`cancelled` events. The `meta` event carries the same token the row persisted. Validates conversation existence before setting SSE headers so 404 is a clean JSON response |
| `POST` | `/Api/assistant/cancel/:turn_token` | Publishes a cancel signal to `assistant:cancel:<turn_token>`. Returns `200 {cancelled: true}` regardless of whether a live subscriber exists (the cancel key TTL self-cleans; a late subscriber picks it up via a pre-loop GET). The token is an unguessable ULID the owner learns through the `meta` event or the turns API |

#### Response shape

All responses use the same `{data, meta}` shape as the document routes:

- **Single resource** — `{data: <record>}` (201 for creates, 200 for reads)
- **Collection** — `{data: [<record>, ...], meta: {count, more}}` (200)
- **Errors** — `{error: "..."}` (409 when another turn is already running on
  the conversation, 422 for validation, 404 for not found, 500 for DB errors)

`count` reports `offset + min(actual_total, items)` when there are more rows
beyond the current page; otherwise it reports `offset + actual_total`. The
`more` flag is `true` when `actual_total > offset + items`.

#### Validation rules

- `session_id`, `cache_key` are **server-generated** on conversation create — the request body can only include `context` and `enabled_tools` (both optional, defaulting to `{}` and `[]`). The response carries no `model` or `config` — the connection resolves live per turn.
- On turn create, `request_messages`, `response_messages`, and `usage` are
  required JSON fields (missing → 422). `finish_reason` and `error` are
  optional strings; at least one is expected in practice.

### `Assistant::Config` snapshot helpers

The snapshot helpers (`to_config_snapshot` / `Config.from_snapshot`) were
removed with the pin/snapshot contract: the connection resolves live per
turn from the effective runtime settings, so there is no snapshot to build
or reconstruct. `Config#to_agent_config` remains — the turn start builds
the view through `SystemSettings::AssistantView`.

---

## Tables

### `agent_conversations`

One row per `Agent` session. Holds the stable identity (`session_id`, `cache_key`) and a snapshot of the config that produced the conversation.

| Column | Type | Description |
|---|---|---|
| `id` | `text` (ULID, PK) | Conversation identifier |
| `session_id` | `text` | `Agent#session_id`; consumed by `Agent#load` |
| `cache_key` | `text` | The OpenAI `prompt_cache_key`. Must stay stable across all turns of the conversation — changing it invalidates the provider KV cache |
| `system_prompt` | `text` | Conversation-stored prompt, so the replay prefix is byte-identical. The main assistant captures the setting at create; the workspace and builder assistants build their prompts from context |
| `context` | `jsonb` | Recontextualization data — describes what the conversation is for. E.g. `{"kind":"doctype-design","domain":"hr","doctype":"Employee"}`, `{"kind":"general-assistance","account_id":"…"}` |
| `enabled_tools` | `jsonb` | Array of tool **names** that were enabled (mirrors `Agent#dump`). Tool callbacks are app code and re-registered at load time, driven by `context` |
| `archived_at` | `timestamp` (nullable) | Archive stamp; `NULL` for a live conversation. See Archiving above — list-organisation only, cleared by the next turn |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | |

There is **no** `model` or `config` column: the pin/snapshot contract ended
with runtime settings. The connection (endpoint, key, model, sampling)
resolves from the effective settings at every turn start — see
[`system-settings.md`](system-settings.md) and
[`workspace-assistant.md`](workspace-assistant.md) → Connection resolution.
The per-turn model lives on the `assistant_usage` ledger.

### `agent_turns`

One row per `Agent#ask` invocation. The exact input/output message sequence is stored as JSONB so that concatenating turns in `idx` order reproduces the agent's full `history` array — the same array `Agent#dump` would emit.

| Column | Type | Description |
|---|---|---|
| `id` | `text` (ULID, PK) | Turn identifier |
| `conversation_id` | `text` (FK → `agent_conversations.id`, `ON DELETE CASCADE`) | Parent conversation |
| `idx` | `integer` | Sequential per-conversation (1, 2, 3, …). Unique within `(conversation_id, idx)` |
| `request_messages` | `jsonb` | Exact input messages appended this turn (the `AskRequest.new_messages` array, serialized as `Agent::Message`) |
| `response_messages` | `jsonb` | Exact output messages produced this turn (assistant message(s) + tool-result messages, in order) |
| `status` | `text` | Turn lifecycle: `running` → `done` \| `cancelled` \| `error`. See the status lifecycle table above |
| `usage` | `jsonb` | Final `Agent::Usage`: `prompt_tokens`, `completion_tokens`, `total_tokens` |
| `finish_reason` | `text` | `"stop"`, `"length"`, `"tool_calls"`, … Nullable on error |
| `error` | `text` | Populated when the turn failed (`Response#finish_with_error`, a cancel — `"cancelled"` — or the sweep's `"interrupted"`) |
| `turn_token` | `text` (nullable) | Streaming cancel token. The stream route generates it before `Turn.open` and hands the same value to `Stream::Session`, so the row and the live cancel channel (`assistant:cancel:<token>`) agree from the start. Surfaced on the turns API, so a client that reloads mid-turn can still cancel. `NULL` for manual `POST /:id/turns` rows |
| `created_at` | `timestamp` | Turn **start** time — the row is written when the stream opens, not when it ends |

Indexes: `idx_agent_turns_conversation_idx` on `(conversation_id, idx)`, and the
partial unique `idx_agent_turns_one_running` on `(conversation_id) WHERE
status = 'running'`, which enforces the one-running-turn invariant.

### `idx` assignment

`idx` is **not** auto-assigned by a trigger (unlike `mutations.idx`). It is assigned in Crystal — `SELECT COALESCE(MAX(idx), 0) + 1 FROM agent_turns WHERE conversation_id = ?` — inside the same statement that inserts the turn. The one-running invariant plus agent-cr's single-fiber request loop serialise turns, so concurrency conflicts cannot reorder `idx`.

### `assistant_usage`

One row per billed streaming turn, written by `Stream::Session` at the
turn's terminal path when the session carries an account id and the turn
carries billable counts — success turns with the provider-reported
counts, cancelled turns with reported counts or an anti-siphon estimate,
and terminal-error turns with reported counts only (nothing was
delivered, so there is nothing to siphon). Zero-count turns insert no
row. The table carries **no foreign keys**: rows outlive conversations,
so deleting a conversation never erases billing history (`turn_id` and
`conversation_id` are loose references; `agent_turns.usage` can re-derive
a lost reported row — an estimated row has no turn-side mirror by
design).

| Column | Type | Description |
|---|---|---|
| `id` | `text` (ULID, PK) | Ledger row identifier |
| `account_id` | `text` NOT NULL | The bare `iam.Account` id the turn is billed to |
| `conversation_id` | `text` NOT NULL | Parent conversation (no FK) |
| `turn_id` | `text` NOT NULL | The persisted `agent_turns` row (no FK) |
| `model` | `text` | Model snapshot of the resumed conversation; nullable |
| `input_tokens` | `bigint` NOT NULL, default `0` | Prompt tokens of the turn |
| `output_tokens` | `bigint` NOT NULL, default `0` | Completion tokens of the turn |
| `estimated` | `boolean` NOT NULL, default `false` | `true` when the counts are the Session's anti-siphon estimate for a cancelled turn the provider never reported on (see [`workspace-assistant.md`](workspace-assistant.md) → Usage ledger) |
| `recorded_at` | `timestamp` NOT NULL, default `now()` | UTC write time; the windowing column |

Index: `assistant_usage_account_recorded_idx` on `(account_id, recorded_at)` — the windowed per-account sum (`Assistant::Usage.total_for_account`).

The read/write service is `Assistant::Usage` (`src/assistant/usage.cr`) — `Usage.insert(...)` and `Usage.total_for_account(db, account_id, since, to)` → `{input, output, total}`. See [`workspace-assistant.md`](workspace-assistant.md) for the attribution rules and the limit seam that sums it.

Retention: `Cron::AssistantUsagePrune` deletes rows whose conversation has
been quiet past `assistant.usage_retention_days` (default `0` — never).
See [`workspace-assistant.md`](workspace-assistant.md) → Retention.

---

## Replay / resume

### Replay / resume

To resume a conversation, call `Assistant::Resume.call(db, conversation_id)`. It returns a `Session` carrying the reconstructed `history` array and a ready-to-use `session_json`. Build the `Agent::Config` from the effective settings (`SystemSettings::AssistantView.build(db, conversation.system_prompt)`), construct a fresh `Agent` with `config.to_agent_config`, re-register the tool callbacks (driven by `context`), then call `agent.load(session.session_json)`. The replayed history is byte-identical to the original, so the provider hashes the same prefix under the same `cache_key` → KV cache hit.

---

## Design notes

- **No intermediate-iteration rows.** Within a single turn, the agent may make several HTTP calls during a tool loop (`process_request_loop` in `agent-cr`). Only the *final* message sequence for the turn is stored; the internal iterations are deterministic from the tool definitions + model output and are not separately persisted.
- **Partial turns / errors.** Terminal-error turns keep their row (`status =
  'error'`) for observability, but contribute nothing to the replay:
  `Resume` skips them, so a failed attempt never enters the model's
  context. A truncated turn keeps its partial `response_messages` (the
  output or tool results that landed before the drop) for the audit trail;
  a provider error that hit before output keeps an empty array. Neither
  replays. A capped turn also keeps its partial exchange, and it replays —
  the committed tool-call work is real context the next ask continues from.
- **Request/response message split.** `request_messages` owns the turn's own
  user messages; `response_messages` never contains them. agent-cr appends
  the request's user messages to `agent.history` at `ask` start, so a raw
  history slice starts with them — the session strips them
  (`drop_request_messages`) before it persists any slice, terminal or
  checkpointed. `Resume` concatenates both columns; without the strip the
  user message would replay twice.
- **Slice anchors, not indexes.** The persisted slices derive from the
  turn's own messages in the *current* history, not from a pre-ask index.
  agent-cr's `trim_history!` (a finite `assistant.max_history`) fires once
  per turn right before the response finishes and drops a prefix of the
  history, so a pre-ask index goes stale: the slice would lose the turn's
  leading messages or raise. On the paths where the request messages stay
  in history (done, cancelled, capped, clean-close truncation), the anchor
  is the turn's user message — the last user-role message in the array;
  when the trim consumed it, every older message went with it and the
  surviving array is all this turn's. On the paths where agent-cr rolled
  the request messages back (the hard provider drop, and the checkpoint
  that can race one), the anchor is the pre-ask history size, clamped to
  the array — the drop path never trims, and an older turn's user message
  must never become the anchor.
- **Tool callbacks are app code.** Only tool *names` are persisted (`enabled_tools`); re-registration happens at load time, consistent with `Agent#dump`.
- **Attachments** (image / audio / file `ContentPart`s) are stored inline in the message JSONB as base64 data URIs — not as rows in the `artifacts` system.
- **Secrets.** `api_key` is never persisted anywhere: it resolves from the
  effective settings (secret store slot, else the file) at every turn start
  via `SystemSettings.reveal_secret`. Nothing on the conversation row, the
  turn rows, or any read API carries credential material.

---

## Streaming turns (`Assistant::Stream`)

The streaming subsystem drives a live `Agent#ask` call and drains
`Response#stream` onto a Kemal response as Server-Sent Events. It is
self-contained (no WebSocket dependency) and multi-process safe via Redis
Pub/Sub.

**Files:** `src/assistant/stream/cancel_bus.cr`, `src/assistant/stream/session.cr`.

### `Assistant::Stream::Session` (`src/assistant/stream/session.cr`)

Orchestrates one streaming turn: builds/resumes the `Agent`, dispatches
`#ask`, drains the chunk stream onto an IO as SSE events, checkpoints the
committed exchange into the `running` row on a ~2 s cadence, completes the
`Turn` row (opened by the route) at every exit path (done / cancel / cap /
error), writes the usage-ledger row for a billable turn, and tears down the
Redis cancel subscription.

| Method | Description |
|---|---|
| `.new(db, conversation_id, content, attachments?, api_key?, account_id?, tool_registrar, argument_tools)` | Constructs a session. The optional `tool_registrar` block is called with the freshly-built `Agent` so the caller can register tools via `Agent#register_tool` before `ask`. `account_id` attributes the turn on the usage ledger — `nil` (system bypass, anonymous caller) means the turn writes no `assistant_usage` row. `argument_tools` names the UI tools whose raw `arguments` forward on the `tool_call` chunk |
| `#run(io, redis_url, cancel_ttl, turn_id)` | Runs a streaming turn for the pre-opened `running` row, writing SSE events to `io`. Completes the row on every exit path with the terminal status. Returns a `Result` (`turn_id`, `finish_reason`, `error`, `cancelled`) |

`run` arms the cancel subscriber **before** the `meta` event and before
`agent.ask`, so a cancel that races the request start is still observed. The
subscriber fiber and the main fiber coordinate through one
`Sync::Exclusive(CancelState)` holding the published `Agent::Response?` and a
`requested` flag: the subscriber cancels the response once it is published,
and before that it sets the flag — the main fiber re-reads the flag under the
same lock the moment `ask` returns and cancels the response then. Both
mutations share one lock, so no interleaving drops the signal.
`Response#cancel` is a mutex-protected flag flip, fiber-safe by design in
`agent-cr`; the stream parser checks it before every blocking read.

#### Client disconnect

The turn is server-owned work; the SSE sink is one consumer of it. A dead
sink — the browser refreshed, the phone switched networks — never terminates
the turn:

- Every write runs through a guarded path that flips an `io_dead` flag on
  the first failure (a flush failure raises `HTTP::Server::ClientError`, a
  later write on the closed output raises `IO::Error`, and a
  TLS-terminated listener raises `OpenSSL::SSL::Error` — no `IO::Error`
  subclass, so the guard names it too) and turns every later write into a
  no-op.
- The drain loop keeps consuming provider chunks; the agent loop, tool
  calls included, runs to completion; the full result lands in the turn row
  with its terminal status. A reconnecting client reads it through
  `listTurns` (page reload, conversation reselect) or the catch-up poll
  (`turns/latest`).
- `@io_lock` (a `Sync::Mutex`) serialises each frame — the three writer
  fibers (main drain, agent run-loop via `ToolTraceHandler`, heartbeat)
  cannot interleave partial frames.

#### Heartbeat

A dedicated fiber emits an SSE comment (`: ping`) every 15 seconds so idle
stretches of the tool loop do not trip proxy idle timeouts (Caddy) or
carrier NAT drops on mobile networks. The fiber exits within ~1s of the
drain ending; it never joins against the main fiber.

### `Assistant::Stream::CancelBus` (`src/assistant/stream/cancel_bus.cr`)

Redis Pub/Sub wrapper for cross-process cancel fan-out. One streaming turn
owns one channel: `assistant:cancel:<turn_token>`.

| Method | Description |
|---|---|
| `.publish(turn_token, redis_url, ttl_seconds)` | `SET assistant:cancel:<token> 1 EX <ttl>` then `PUBLISH assistant:cancel:<token> 1`. The SET makes the cancel robust to a late subscriber (a publish that raced ahead of the subscription) |
| `.subscribe(turn_token, redis_url, &on_cancel)` | Subscribes in a dedicated fiber. After `SUBSCRIBE` is flushed, issues a `GET` on the cancel key — this catches a publish that raced the subscription registration. Returns a `SubscriptionHandle`; closing it (from the route's `ensure`) closes the Redis client and unblocks the subscriber fiber |
| `.channel(turn_token)` / `.cancel_key(turn_token)` | Builders for the channel and key names |

### SSE event format

Response headers (set by the route before the first flush):

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
X-Accel-Buffering: no
```

| Event | Data | When |
|---|---|---|
| `meta` | `{"turn_token":"..."}` | Immediately after headers, before the first chunk |
| `chunk` | `{"kind":"content"\|"reasoning","text":"..."}` | Per `Response#stream` content/reasoning chunk |
| `chunk` | `{"kind":"tool_call","name":"...","status":"running","detail":"..."}` | When a registered tool callback is about to execute (before invocation) |
| `chunk` | `{"kind":"tool_call","name":"...","status":"ok","result":"..."}` | On successful tool callback return |
| `chunk` | `{"kind":"tool_call","name":"...","status":"error","result":"..."}` | On callback exception (agent-cr wraps the message as `"Error executing tool '...'"`) |
| `done` | `{"turn_id":"...","finish_reason":"stop"\|"length"}` | On `Response#finish` |
| `error` | `{"message":"..."}` | On `Response#finish_with_error`, the tool-loop cap, or an unexpected exception |
| `cancelled` | `{}` | On cancel detected, before close |
| `: ping` | — (comment) | Heartbeat comment every 15s; ignored by event-source parsers |

`tool_call` events are emitted by the `ToolTraceHandler` registered on
every turn's `Agent`. The handler hooks into agent-cr's `ToolCallContext`
stage, which fires around each registered tool callback invocation. `detail`
is a best-effort `key=value, key=value` rendering of the arguments; `result`
is the callback's return value (or, on error, agent-cr's wrapped error
string). A tool whose name is in the session's `argument_tools` set
(UI tools, per conversation kind) additionally carries its raw `arguments`
JSON on both halves of the call — the chat UI renders cards from them or
navigates; non-UI tools never carry `arguments` on the wire. Tool calls
whose arguments fail to parse as JSON or fail schema
validation bypass the handler chain and therefore emit no `tool_call`
events — the agent returns the error to the model and re-asks.

### Turn persistence semantics

`agent-cr` appends to `agent.history` inside `process_request_loop`:
the request's `new_messages` at the start, the assistant message after the
HTTP call, and tool-result messages per tool-call iteration.

- **Success**: the running row (opened by the route) is completed with
  `status = 'done'`, `request_messages = [Message.user(content)]`,
  `response_messages` = the turn's assistant and tool messages sliced from
  the agent history minus the turn's own user messages
  (`drop_request_messages` — see the design note on the request/response
  split). The slice anchors on the turn's user message in the current
  history, so agent-cr's mid-turn `trim_history!` (finite
  `assistant.max_history`) cannot shift it. This captures the assistant
  message + any tool-result messages in order.
- **Cancel**: `agent-cr` preserves the partial turn in `agent.history` — the
  streamed assistant reply and any tool results committed before the cancel
  (the user message was already appended at the start of the request). The
  persisted `response_messages` is that partial history minus the turn's own
  user messages, so `Resume` restores the context and the next
  `#ask` can pick up where the cancelled turn left off. `status` is
  `cancelled`, `error` is `"cancelled"`, `finish_reason` is `nil`, and
  `usage` is a zeroed `Agent::Usage`.
- **Terminal refusal**: the model repeated a final refused tool call. The
  `RefusalGuard`'s terminal envelope is model-facing text; when the same call
  re-appears, `Stream::TerminalRefusalStop` cancels the response, so the turn
  takes the Cancel path above — `status` stays `cancelled`, `error` is
  `"cancelled"`, and the SSE `cancelled` event carries `{}`. Nothing on the
  row or the wire names the refusal; the tool trace is the differentiator
  (the terminal envelope rides a `tool_call` chunk with `status: "error"`).
  This is deliberate — see `src/assistant/stream/terminal_refusal_stop.cr`.
- **Error** (provider error, unexpected exception): `agent-cr` rolls back the
  request messages, so `agent.history.size == boundary` again. The persisted
  `response_messages` is `[]` (empty), `status` is `error`, and `error` is
  the actual error message. `finish_reason` is `nil`.
- **Tool-loop cap**: when agent-cr consumes its iteration limit
  (`Agent::ToolLoopError`), the turn ends `capped`, not `error`. agent-cr
  does not roll the history back on this path — every iteration completed,
  so the slice ends on a complete assistant + tool-results pair and is a
  valid provider prefix. The persisted `response_messages` keeps that
  partial exchange (minus the turn's own user messages), `status` is
  `capped`, and `error` carries the raw cap message. The client still
  receives a terminal `error` SSE event with that message. The turn
  replays on `Resume`.
- **Client disconnect**: not an error. Writes become no-ops (see Client
  disconnect above); the turn proceeds down the success / cancel / error
  path that the provider's outcome dictates, and the terminal status — the
  truth — lands in the row.
- **Interrupted process**: when the server dies mid-turn, no exit path runs
  and the row stays `running`. `Cron::AssistantTurnSweep` marks rows older
  than `assistant.turn_timeout_seconds` `error` with message
  `interrupted` — an honest corpse the catch-up poll and the audit trail
  can read. A very late completion (the turn actually finished after the
  sweep) overwrites the swept state, because `Turn.complete` targets the
  row by `id` alone.
- **Mid-turn checkpoint**: while the row is `running`, the drain loop
  persists the committed exchange into it every `CHECKPOINT_INTERVAL`
  (2 s) through `Turn.checkpoint`. A checkpoint skips when nothing new
  committed since the last write, and when the slice ends on a dangling
  assistant tool_calls message (its results are not appended yet — an
  invalid provider prefix). The write targets `running` rows only and runs
  on the drain fiber ahead of the terminal persists, so it can never race
  a `Turn.complete`. Checkpoints are best-effort: a failed write logs and
  the turn carries on. A reloaded client reads the row's messages through
  the catch-up poll and renders progressive output instead of a bare
  thinking placeholder.
- **Usage ledger.** Every terminal path whose session carries an
  `account_id` bills the ledger: success turns with the reported counts,
  cancelled and capped turns with the reported counts or (when the provider
  reported nothing — the usual abort shape) an `estimated` anti-siphon row,
  and terminal-error turns with reported counts only. Zero-count turns
  insert nothing. A ledger failure logs and keeps the turn row. See
  [`workspace-assistant.md`](workspace-assistant.md) → Usage ledger for
  the counting rules.
