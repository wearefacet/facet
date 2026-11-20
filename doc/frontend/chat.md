# Chat — AI conversation components

Components for AI chat surfaces: markdown-rendering message bubbles (with streaming support), a tool-call trace bar, a composer input, a thread container, a reusable chat core (`ChatPanel`), the two mounts (`FloatingAssistant` for the builder, `WorkspaceAssistant` for the main application) inside the shared floating-window shell (`AssistantWindow`), and the workspace document surfaces (document rows, document cards, stats tiles).

The driver layer, the chat core, and the markdown layer are also extracted into the standalone `@facetapp/chat` npm package, which embeds the assistant into host applications as two custom elements — see [`packages/chat.md`](../packages/chat.md). This page documents the in-app components; the package evolves its own copy.

## Source files

| File                                                                    | Purpose                                                                                                                                                                                                                                                                        |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `frontend/src/lib/components/features/chat/markdown-renderer.ts`        | Markdown-to-segments renderer using `marked.lexer` + an allowlisted token walker; `highlight.js` for code colorization.                                                                                                                                                        |
| `frontend/src/lib/components/features/chat/Markdown.svelte`             | Renders markdown segments to HTML; renders fenced code blocks with highlight.js and `mermaid` blocks via `MermaidDiagram`. Re-compiles reactively so streaming works.                                                                                                          |
| `frontend/src/lib/components/primitives/content/MermaidDiagram.svelte`  | Lazy-loads `mermaid` and renders a diagram source to SVG. Shows a placeholder during streaming and an error card on parse failure. Shared with the longtext editor's mermaid node view (`primitives/content/mermaid-fence.ts`).                                                |
| `frontend/src/lib/components/features/chat/ChatBubble.svelte`           | A single message bubble. User → right-aligned bubble; agent → flush-left with name/tag header.                                                                                                                                                                                 |
| `frontend/src/lib/components/features/chat/ToolCallBar.svelte`          | Mono-font trace bar showing the last tool the agent called, with a status pill.                                                                                                                                                                                                |
| `frontend/src/lib/components/features/chat/ChatTurnPanel.svelte`        | One assistant turn: the agent header once, then the ordered parts — text bubbles, reasoning blocks, tool bars, preview cards, and the workspace surfaces (rows, cards, stats). The header carries the answer copy affordance.                                                  |
| `frontend/src/lib/components/features/chat/ViewPreviewCard.svelte`      | Inline preview card rendered for `preview_view` UI-tool calls: shows a document view template or a collection surface (table/calendar) against fake data. Under-renders its body while off-screen (IntersectionObserver) and has a full-page expand overlay.                   |
| `frontend/src/lib/components/features/chat/DocumentCard.svelte`         | One document inside the chat — compact row or card. Resolves the record via the data driver (60s cache), the doctype via `DoctypeRegistry`, and card mode also the doctype's document-view template. Loading and error states; click → host hook (peek drawer) or `goto`.      |
| `frontend/src/lib/components/features/chat/StatsCard.svelte`            | Metric tiles for a resolved `aggregate_documents` call — one tile per currency of a money bag, one tile otherwise. The value renders as received (a computed metric, not display data).                                                                                        |
| `frontend/src/lib/components/features/chat/ChatPanel.svelte`            | Reusable chat core: conversation rail, thread, composer, and the turn logic (part accumulation, UI-tool chunk handling, cancel, replay load). One component, two hosts.                                                                                                        |
| `frontend/src/lib/components/features/chat/UsageMeter.svelte`           | One-line usage meter above the composer: rolling-window percent bar + label. Hidden when the account is unlimited (`budget: null`).                                                                                                                                            |
| `frontend/src/lib/components/features/chat/AssistantWindow.svelte`      | Floating assistant window — the shared shell (draggable header, Maximize/Collapse/Close, edge resize, persisted window state) around a `ChatPanel` mount. Both assistant surfaces use it, so the window looks and behaves the same in the builder and in the main application. |
| `frontend/src/lib/components/features/chat/WorkspaceAssistant.svelte`   | The workspace assistant surface: `ChatPanel` scoped to `{kind: 'workspace', created_by}` inside the shared `AssistantWindow`. Creates conversations on the dedicated route and runs workspace `navigate` targets with `goto`.                                                  |
| `frontend/src/lib/components/features/chat/ThoughtBlock.svelte`         | Collapsible reasoning block: streams the model's thinking open while it arrives, then folds away into a reopenable "Thought" header once it completes. The header carries the per-block copy affordance.                                                                       |
| `frontend/src/lib/components/features/chat/ChatInput.svelte`            | Composer textarea with auto-grow, vertical resize, and Ctrl/Cmd+Enter to send.                                                                                                                                                                                                 |
| `frontend/src/lib/components/features/chat/ChatScroll.svelte`           | Scrollable container that auto-sticks to the bottom when new content arrives, but only if the user is already anchored there.                                                                                                                                                  |
| `frontend/src/lib/components/features/chat/ChatThread.svelte`           | Layout primitive: a flex column that lays out bubbles with the design's `gap: 18px` rhythm and an optional daymark divider.                                                                                                                                                    |
| `frontend/src/lib/components/features/chat/ConversationList.svelte`     | Scrollable list of conversations with infinite pagination, context filtering, archive state (header toggle swaps live ↔ archived; row hover action), and a `+ New` action. Driven by `AssistantDriver.listConversations` + `setConversationArchived`.                          |
| `frontend/src/lib/components/features/builder/FloatingAssistant.svelte` | The builder mount: the draft-scoped glue (conversation factory, page context, `go_to_page`, draft badge/daymark) around the shared `AssistantWindow` + `ChatPanel`.                                                                                                            |

The pure logic the parts machinery lives in `frontend/src/lib/assistant/`: `tool-call-helpers.ts` (parts model + chunk application), `reconstruct-turns.ts` (replay), `ui-tools.ts` (UI-tool parsers). |

## Public API

### `Markdown`

```svelte
<Markdown content={mdString} streaming={false} />
```

| Prop        | Type      | Default | Description                                                                                                                  |
| ----------- | --------- | ------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `content`   | `string`  | `''`    | Markdown source. Re-parsed on every change.                                                                                  |
| `streaming` | `boolean` | `false` | Shows a blinking caret at the end of the content; also passed to `MermaidDiagram` so diagrams wait for the stream to finish. |

**Supported markdown features:** paragraphs, headings, lists, links, images, tables (GFM, with column alignment), blockquotes, inline code, fenced code blocks, hr, breaks. **Fenced code blocks** are colorized with `highlight.js` (common languages bundle); an unknown language falls back to auto-detection, then to plain text. **`mermaid` fenced blocks** are rendered as diagrams via `MermaidDiagram`. **Raw HTML is disallowed** — any HTML/tag token falls back to escaped text. The rendering logic lives in `markdown-renderer.ts` (`renderMarkdown`, `highlightCode`, `Segment`).

### `ChatBubble`

```svelte
<ChatBubble role="agent" name="Steve" tag="schema agent" content={md} streaming={true} />
```

| Prop        | Type                | Default | Description                                                                         |
| ----------- | ------------------- | ------- | ----------------------------------------------------------------------------------- |
| `role`      | `'user' \| 'agent'` | —       | Layout: `user` is right-aligned with a bubble; `agent` is flush-left with a header. |
| `name`      | `string`            | —       | Agent display name (ignored for `user`).                                            |
| `tag`       | `string`            | —       | Agent tag pill, e.g. `"schema agent"` (ignored for `user`).                         |
| `content`   | `string`            | `''`    | Markdown content, rendered via `Markdown`.                                          |
| `streaming` | `boolean`           | `false` | Passed to `Markdown` to show the caret and defer mermaid rendering.                 |
| `children`  | `Snippet`           | —       | Alternative to `content`: render arbitrary Svelte content inside the bubble.        |

### `ToolCallBar`

```svelte
<ToolCallBar name="inspect_domain" detail="inspected domain crm" result="6 doctypes" status="ok" />
```

| Prop     | Type                           | Default | Description                                                                                          |
| -------- | ------------------------------ | ------- | ---------------------------------------------------------------------------------------------------- |
| `name`   | `string`                       | —       | Tool name. If it starts with `search` or `inspect`, a search icon is shown; otherwise a wrench icon. |
| `detail` | `string`                       | —       | Human-readable summary of what the tool did.                                                         |
| `result` | `string`                       | —       | Result summary shown on the right (e.g. `"6 doctypes"`).                                             |
| `status` | `'running' \| 'ok' \| 'error'` | `'ok'`  | Status of the call. `running` shows a spinner; `ok` a check; `error` an alert.                       |

### `ThoughtBlock`

```svelte
<ThoughtBlock content={reasoning} active={streaming} />
```

| Prop      | Type      | Default | Description                                                                                                                                                                         |
| --------- | --------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `content` | `string`  | `''`    | Reasoning markdown content, rendered via `Markdown`. Re-parsed on every change so streaming works.                                                                                  |
| `active`  | `boolean` | `false` | True while the reasoning is still streaming. Forces the block open; on the transition to `false` the block collapses once (the completed thought folds away), but stays reopenable. |

A `<details>` disclosure rendered with a quiet mono-font "Thought" header (chevron + optional streaming dot) and an expandable body. Used by `ChatTurnPanel` to render `reasoning` parts. It is distinct from `ToolCallBar` — a thought is private model deliberation, not an executed tool call.

Once the block finished streaming, a quiet icon button (revealed on hover or focus) copies this block's reasoning markdown alone. It anchors over the header from a wrapper outside the `<details>` — a button inside the `<summary>` is nested-interactive (axe), and a summary child would be hidden while the block is collapsed — so the copy stays reachable while collapsed and never toggles the disclosure.

### `ViewPreviewCard`

```svelte
<ViewPreviewCard preview={{ spec, status }} />
```

| Prop      | Type                                                                       | Default | Description                                                                                                                                                    |
| --------- | -------------------------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `preview` | `ViewPreview \| { spec: ViewPreviewSpec \| null, status: ToolCallStatus }` | —       | Parsed `preview_view` arguments plus the call status. `spec: null` (invalid payload) or `status: 'error'` renders an error note; `running` renders a skeleton. |

The card **is** the tool-call UI for `preview_view` — these calls never render a `ToolCallBar`. For `kind: 'document'` it renders the template tree through `DocumentViewTemplate` against a fake document; for `kind: 'collection'` it renders a static fake table (columns from `config.columns`) or a `MonthGrid` calendar. Field values come from the model's `sample_data` merged over deterministic generated fallbacks (`$lib/assistant/ui-tools.ts`).

Two behaviours keep long sessions cheap:

- **Under-render.** The heavy body mounts only while the card intersects the viewport (`IntersectionObserver`, 200px pre-roll); a skeleton shows otherwise.
- **Expand.** A button opens the same body as a fixed full-page overlay (`Esc`/backdrop/button closes it).

The parsing/validation layer is `frontend/src/lib/assistant/ui-tools.ts` — it owns `UI_TOOL_NAMES`, `parseViewPreview`, `parseGoToPage`, `parseNavigateTarget`, and the fake-data generators. URL building lives at the navigation site: each assistant mount runs a per-case `resolve()` switch, so the draft domain comes from the UI, never from the tool payload. Replay path: `reconstructTurns` rebuilds preview parts from the persisted `tool_calls[].arguments`, so previews survive a session reload. `go_to_page` navigates only on the live stream (`isNavigateChunk` in the `ChatPanel` chunk loop), never on replay.

### `ChatInput`

```svelte
<ChatInput bind:value placeholder="Type…" onsend={(text) => send(text)}>
  <!-- optional footer row: context chips, model chip, attach button -->
</ChatInput>
```

| Prop          | Type                     | Default             | Description                                                                                  |
| ------------- | ------------------------ | ------------------- | -------------------------------------------------------------------------------------------- |
| `value`       | `string`                 | `''`                | Two-way bindable input text.                                                                 |
| `placeholder` | `string`                 | `'Type a message…'` | Placeholder.                                                                                 |
| `disabled`    | `boolean`                | `false`             | Disables input and send.                                                                     |
| `onsend`      | `(text: string) => void` | —                   | Called with the trimmed text on Ctrl/Cmd+Enter or send-button click. Clears the input after. |
| `children`    | `Snippet`                | —                   | Optional footer row rendered below the textarea.                                             |

**Keyboard:** plain Enter inserts a newline (the textarea grows to fit, up to 200px, then scrolls; the user can drag the vertical resize handle up to 320px). Ctrl+Enter or Cmd+Enter sends.

### `ChatScroll`

```svelte
<ChatScroll>
  <ChatThread>...</ChatThread>
</ChatScroll>
```

| Prop       | Type      | Default | Description                                                                    |
| ---------- | --------- | ------- | ------------------------------------------------------------------------------ |
| `children` | `Snippet` | —       | Scrollable conversation content. Usually a `<ChatThread>` with bubbles inside. |

**Auto-stick-to-bottom behaviour:** the container tracks whether the user is anchored to the bottom (within a 40px threshold). When new content arrives — a new bubble appended, or streaming tokens growing the last bubble — the view scrolls to the bottom **only if the user was already there**. If the user has scrolled up to read earlier history, the view stays put. Scrolling back down to the bottom re-establishes the anchor. On mount, the view jumps to the bottom instantly.

Content changes are observed with a `MutationObserver` (`childList`, `subtree`, `characterData`), so streaming token arrivals are caught without the caller threading a `messages` array through.

### `ChatThread`

```svelte
<ChatThread daymark="New domain · logistics">
  <ChatBubble ... />
  <ToolCallBar ... />
</ChatThread>
```

| Prop       | Type      | Default | Description                                 |
| ---------- | --------- | ------- | ------------------------------------------- |
| `daymark`  | `string`  | —       | Optional divider label rendered at the top. |
| `children` | `Snippet` | —       | The conversation content.                   |

### `ChatTurnPanel`

```svelte
<ChatTurnPanel name="Steve" tag="schema agent" parts={parts} streaming={false} streamActive={false} {documentDriver} />
```

| Prop             | Type          | Default                  | Description                                                                                                            |
| ---------------- | ------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `name`           | `string`      | `'Steve'`                | Agent header, rendered once per turn.                                                                                  |
| `tag`            | `string`      | the `schema agent` pill  | Tag pill next to the name.                                                                                             |
| `parts`          | `AgentPart[]` | `[]`                     | Ordered blocks — `text`, `reasoning`, `tool_call`, `preview`, `rows`, `stats`, `documents` — in stream-emission order. |
| `streaming`      | `boolean`     | `false`                  | True while the turn streams; keeps the thinking indicator and the streaming caret on the trailing text part.           |
| `streamActive`   | `boolean`     | `false`                  | Same signal for the reasoning blocks' fold-away timing.                                                                |
| `documentDriver` | `DataDriver`  | `DocumentDataDriver('')` | Feeds the workspace surfaces (rows, cards). Stories inject a mock.                                                     |

**Copy affordances.** Once the turn is complete (`streaming` false) and it has answer text, the header shows a quiet icon button (revealed on turn hover or focus) that copies the turn's answer — the joined `text` parts only, never the reasoning blocks, the tool trace, or the workspace surfaces. Each `ThoughtBlock` carries its own per-block copy of its reasoning. Both write markdown source to the clipboard through the shared `CopyButton` primitive (`iconOnly` mode) and flip to a check icon while copied.

### `MermaidDiagram`

```svelte
<MermaidDiagram source={mermaidSource} streaming={false} />
```

| Prop        | Type      | Default | Description                                                                                                                    |
| ----------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `source`    | `string`  | —       | Mermaid diagram source (the contents of a ` ```mermaid ` fenced block).                                                        |
| `streaming` | `boolean` | `false` | When true, shows a placeholder instead of rendering — mermaid needs a complete graph. Renders once `streaming` flips to false. |

The `mermaid` library is lazy-loaded on first render and initialised with `securityLevel: 'strict'` (no scripts in the SVG). Each diagram gets a unique id for mermaid's internal cache. Parse errors render an error card with the message. Normally you don't use this directly — `Markdown` renders mermaid blocks for you.

### `ConversationList`

```svelte
<ConversationList
  {driver}
  context={{ kind: 'demo' }}
  pageSize={30}
  reloadKey={listVersion}
  selectedId={conversation?.id}
  onselect={(c) => loadConversation(c)}
  onnew={() => createConversation()}
/>
```

| Prop         | Type                        | Default | Description                                                                                                                                                      |
| ------------ | --------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `driver`     | `AssistantDriver`           | —       | Driver used to call `listConversations`.                                                                                                                         |
| `context`    | `Record<string, unknown>`   | `{}`    | Each key becomes a `context.<key>__eq` filter, scoping the list to conversations matching this context.                                                          |
| `selectedId` | `string \| undefined`       | —       | Conversation id to render as the active row.                                                                                                                     |
| `pageSize`   | `number`                    | `50`    | Items per page; the list auto-loads the next page when the user nears the bottom (`meta.more` from `listConversations`).                                         |
| `reloadKey`  | `number`                    | `0`     | Bump to force a reload from page 1. Use after a turn lands (the backend's `Turn.create` touches `updated_at`, so the conversation should re-surface at the top). |
| `activeId`   | `string \| undefined`       | —       | Id of the conversation whose turn is generating right now — shows the running marker even before a refetch picks up the server-side flag.                        |
| `onselect`   | `(c: Conversation) => void` | —       | Called when the user clicks a conversation row.                                                                                                                  |
| `onnew`      | `() => void`                | —       | When provided, renders a `+ New` button in the header; called on click.                                                                                          |

**Infinite pagination:** the list tracks `meta.more` from each `listConversations` call and fetches the next page when the user scrolls within 80px of the bottom. Pages are de-duplicated by conversation id to handle sort ties across page boundaries.

**Archiving:** the default list is live-only. A small archive icon in the rail header toggles between the live list and the archived list (an `archived__eq=true` filter); the toggle is in-memory view state and resets on reload. A hover/focus-revealed action on each row archives or unarchives through `AssistantDriver.setConversationArchived` (`PATCH /Api/assistant/conversations/:id`). The open conversation stays open when its row is archived. A new turn unarchives server-side, so the row re-joins the live list on its next activity. Backend contract: [`doc/backend/agent-conversations.md`](../backend/agent-conversations.md) → Archiving.

**Running marker:** a conversation with a generating turn (`active` on the record — the backend derives it from the running turn row — or the `activeId` prop) renders a pulsing dot at the row's right edge, so in-flight generations are visible at a glance.

### `ChatPanel`

```svelte
<ChatPanel
  {driver}
  context={{ kind: 'workspace', created_by: accountId }}
  createConversation={() => driver.createWorkspaceConversation()}
  navigateWorkspace={openTarget}
  documentDriver={new DocumentDataDriver('')}
  agentName={assistantName}
  agentTag="workspace"
/>
```

| Prop                                                                 | Type                                   | Default                  | Description                                                                                                                                                                             |
| -------------------------------------------------------------------- | -------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `driver`                                                             | `AssistantDriver`                      | —                        | Backend driver for conversations, turns, and streaming.                                                                                                                                 |
| `context`                                                            | `Record<string, unknown>`              | `{}`                     | Scopes every rail fetch and the reset-on-change key. Each context carries its own conversation set.                                                                                     |
| `createConversation`                                                 | `() => Promise<Conversation>`          | —                        | Conversation factory for the `+ New` action — the surface's own route.                                                                                                                  |
| `pageContext`                                                        | `() => string`                         | —                        | Returns the `[Page context: …]` prefix sent above each message. Omit on surfaces with no page awareness (the workspace mount omits it).                                                 |
| `navigate`                                                           | `(args: GoToPageArgs) => void`         | —                        | Runs the builder `go_to_page` UI tool on the live stream.                                                                                                                               |
| `navigateWorkspace`                                                  | `(target: NavigateTargetArgs) => void` | —                        | Runs the workspace `navigate` UI tool on the live stream.                                                                                                                               |
| `documentDriver`                                                     | `DataDriver`                           | `DocumentDataDriver('')` | Feeds the workspace surfaces (rows, cards). Stories inject a mock.                                                                                                                      |
| `configured`                                                         | `boolean`                              | `true`                   | Whether an AI provider is configured for the installation (`me.assistant.configured`). `false` keeps the window and history browsable, but disables conversation creation and the composer with a message that names system settings as the fix. |
| `daymark` / `contextHint` / `agentName` / `agentTag` / `placeholder` | `string`                               | —                        | Thread divider, composer chip, turn header, tag pill, composer placeholder. The configured assistant name (`assistant.name` on `core.SystemSettings`) rides `agentName` on both mounts. |
| `railWidth`                                                          | `number` (bindable)                    | `RAIL_WIDTH_DEFAULT`     | Conversation-rail width; persists only when the host binds it.                                                                                                                          |

The panel owns the full turn logic: `handleSend` (with the `[Page context: …]` prefix), streaming part accumulation via `applyChunkToParts`, live navigation chunks (`isNavigateChunk` / `isWorkspaceNavigateChunk`), cancel of the in-flight turn, and history load via `reconstructTurns` (through `turnsFromRows`, which renders a `running` row from its persisted messages plus a live thinking placeholder, and renders terminal `error` and `capped` turns as the user bubble, the partial exchange, plus a plain error segment). Rail-width bounds live in `features/chat/assistantWindowState.ts`.

Two budget behaviours ride on the panel. The usage meter: `getUsage` is fetched once on mount and `UsageMeter` renders above the composer whenever the payload carries a budget (`budget !== null`) — unlimited accounts see nothing. The `429` send denial: when `streamAsk` throws `HttpAssistantError(429)` (the backend answers the budget check with a JSON `429` before the SSE headers), `handleSend` renders the localized `assistant_usage_limit_reached` message as the error line instead of the raw status text.

### `UsageMeter`

```svelte
<UsageMeter used={62000} budget={100000} windowDays={30} />
```

| Prop         | Type     | Description                                                                     |
| ------------ | -------- | ------------------------------------------------------------------------------- |
| `used`       | `number` | Total tokens recorded inside the rolling window.                                |
| `budget`     | `number` | The effective budget (`null` never reaches the component — the panel hides it). |
| `windowDays` | `number` | Window length from the backend (30).                                            |

One informational line above the composer — a thin fill bar plus `{percent}% of the {days}-day budget used`, clamped at 100%. The panel fetches once per mount (window open); a failed fetch hides the meter, it never blocks the chat.

### `AssistantWindow`

The floating window both mounts share:

```svelte
<AssistantWindow title="Assistant" badge={draftDomain} onclose={close}>
	<ChatPanel … />
</AssistantWindow>
```

| Prop       | Type         | Default                              | Description                                                   |
| ---------- | ------------ | ------------------------------------ | ------------------------------------------------------------- |
| `title`    | `string`     | `'Assistant'`                        | Header title.                                                 |
| `badge`    | `string`     | — omit when the surface has no scope | Mono badge in the header; the builder shows the draft domain. |
| `onclose`  | `() => void` | —                                    | Close (X) button handler.                                     |
| `children` | `Snippet`    | —                                    | The window body — a `ChatPanel` mount.                        |

The shell owns the window chrome and behaviours: drag by the header, edge/corner resize (top / left / top-left), collapse to a title bar, maximize to the viewport, and persistence in `sessionStorage` — collapsed, maximized, and window size under `facet.assistant.*` (position is deliberately not persisted; see `assistantWindowState.ts`). The window is `position: fixed` with a bottom-right default inset and `z-index: 1000`.

Collapse hides the body with `display: none` only — the body stays mounted, so the hosted `ChatPanel` keeps its state across minimize + restore: selected conversation, loaded turns, composer text, and a live stream. Close (X) removes the window, so the host loses that state again.

Collapse wins over maximize: minimizing a maximized window docks the title bar at the bottom edge, and expanding again returns to the maximized box. Maximize and restore always show the full window — a click never leaves the title bar over an empty box. The floating window covers page content by design (QA B-369, accepted 2026-11-13): collapse, move, or close the window to reach the controls beneath it.

### `WorkspaceAssistant`

```svelte
<WorkspaceAssistant accountId={data.account.id} onclose={() => (assistantOpen = false)} />
```

| Prop             | Type              | Default                             | Description                                                                  |
| ---------------- | ----------------- | ----------------------------------- | ---------------------------------------------------------------------------- |
| `accountId`      | `string`          | —                                   | Signed-in account id — scopes the list and new conversations to their owner. |
| `name`           | `string`          | the localized `'Assistant'`         | The configured assistant name — window header and turn header.               |
| `driver`         | `AssistantDriver` | `new HttpAssistantDriver()`         | Stories inject the mock.                                                     |
| `documentDriver` | `DataDriver`      | — omit for ChatPanel's HTTP default | Data driver for the document surfaces.                                       |
| `onclose`        | `() => void`      | —                                   | Close (X) button handler.                                                    |

The root layout (`frontend/src/routes/+layout.svelte`) renders `AssistantHost` (`frontend/src/lib/components/primitives/surfaces/AssistantHost.svelte`) on authenticated routes. The host picks the mount: the builder route shows `FloatingAssistant`, the live routes show `WorkspaceAssistant`; both render the same `AssistantWindow` shell, so they behave identically (drag, resize, collapse, maximize). While a preview session is active, the live routes mount the builder assistant too — the user is looking at the draft's live URL but is still iterating on the draft, and the preview token would fail the workspace surface's role gates anyway (the capability principal carries no active role). The builder surface binds to the preview domain (`draftDomain` resolves from the preview session when the route param is absent), and its page-context chip reads the live path shape (`/{draft}/{Doctype}/{id}`). The host passes the configured assistant name to both — one name for the workspace and builder surfaces (`assistant.name` on `core.SystemSettings`, served by `GET /Api/iam/me`, shown in the window headers, the turn headers, and the top-bar pill). A `null` surface (Configure, consent, unauthenticated) mounts nothing. One open state drives both mounts, held by `assistantOpen.svelte.ts` (`initAssistantOpen()` hydrates the SSR-safe sessionStorage-backed flag under `facet.assistant.open` post-mount; `getAssistantOpen()` / `setAssistantOpen()` read and write it). The top-bar toggle (in `Topbar`/`AppShell`) renders only when `assistantAccess` is true. The window is `position: fixed`, so it overlays the `AppShell` grid rather than re-gridding it.

### `DocumentCard`

```svelte
<DocumentCard ref={{ domain, doctype, id }} display="card" {driver} onopen={openPeek} />
```

| Prop      | Type                       | Default | Description                                                        |
| --------- | -------------------------- | ------- | ------------------------------------------------------------------ |
| `ref`     | `DocumentRow`              | —       | Document identity — `{domain, doctype, id}` from the tool payload. |
| `display` | `'card' \| 'inline'`       | —       | `inline` renders one compact row; `card` an inspectable card.      |
| `driver`  | `DataDriver`               | —       | Data driver — `DocumentDataDriver` in the app, a mock in stories.  |
| `onopen`  | `(r: DocumentRow) => void` | —       | Host hook (peek drawer). When absent, click navigates with `goto`. |

The payload carries document identity only — every display value resolves here from the data source: the record via `driver…doc(id).show()` (60s client cache; the backend resolves the qualified or bare id shape), the doctype definition via `DoctypeRegistry`, and card mode the doctype's `card` kind template rendered through `DocumentViewTemplate` in a bounded container. Card mode loads no other kind: the full-page `view` and `quickView` templates never mount in a card, so a doctype without a `card` view shows the identity body (display name + updated time). The card body scrolls vertically only (`overflow-x: hidden`). Loading shows a skeleton; an unresolvable document shows an error row.

### `StatsCard`

```svelte
<StatsCard stats={stats} />
```

| Prop    | Type    | Description                                                                                                                                                                    |
| ------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `stats` | `Stats` | `{aggregate, field?, value, count}` — `value` is a number, a decimal/duration string, a per-currency bag `{currency => amount}` for `money` fields, or `null` on an empty set. |

Renders the aggregate as metric tiles: one tile per currency when the value is a bag, one tile otherwise. The headline names the field (or "Matching documents" for `count`); the caption names the aggregate and the contributing-row count. The value renders as received — the aggregate is a computed metric, not display data.

## Streaming pattern

Streaming works because `Markdown`'s `content` prop is reactive: every token arrival updates `content`, which re-runs `marked.lexer` and re-renders. The `streaming` prop shows a blinking caret until the stream completes.

**Thinking vs. content.** The SSE `chunk` event distinguishes `content` (the visible answer) from `reasoning` (the model's deliberation). `applyChunkToParts` keeps them separate: `content` accumulates into `text` parts and `reasoning` into `reasoning` parts. `ChatTurnPanel` renders a `reasoning` part as a `ThoughtBlock`, which stays open while it streams and folds away once the answer begins or the turn ends. The same split applies on reload: `reconstructTurns` emits a leading `reasoning` part from a stored assistant message's `reasoning` field when present.

**Stable keys for turns.** A conversation surface that streams must key its `{#each turns as t (t.id)}` by a stable per-turn `id`, not by object identity (`(t)`). During streaming the turn array is re-created on every chunk (`turns = turns.map((t, i) => …)`), producing new object references each time; keying by identity then tears down and recreates every `ChatTurnPanel` on each chunk — dropping the agent-step bars and causing the redraw/perf problem. Assign a monotonic `id` when a turn is created (user or agent) and when turns are reconstructed from history, exactly as the Chat stories do.

### Workspace tool chunks

The workspace surface renders tool results as content, not as a raw trace. `applyChunkToParts` maps the `tool_call` chunks to `AgentPart` variants (all in `tool-call-helpers.ts`):

| Chunk                                                  | Resulting part                                                                                                                                                               | Renderer                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `list_documents` `ok`                                  | `rows` — compact document identity rows plus the capped `meta` total                                                                                                         | `DocumentCard` `display="inline"` in a bordered stack |
| `aggregate_documents` `ok`                             | `stats` — the aggregate value and contributing-row count                                                                                                                     | `StatsCard` tiles                                     |
| `show_documents` (running → ok; `arguments` forwarded) | `documents` — parsed arguments narrowed to the ack's `rendered` ids; a running part shows skeletons                                                                          | `DocumentCard` grid (`card`) or stack (`inline`)      |
| `navigate` `ok` (`arguments` forwarded)                | No part — `isWorkspaceNavigateChunk` in `ChatPanel` calls the host's `navigateWorkspace`, which resolves the URL per target case with a literal `resolve()` and calls `goto` | —                                                     |

A chunk whose `result` fails to parse into a part falls back to the plain `tool_call` bar, so the raw trace stays visible. The rows/stats display data re-resolves through the `documentDriver` — the payload carries identity, never display values. `navigate` runs only on the live stream; replay never re-navigates.

A typical integration:

```svelte
<script lang="ts">
	let content = $state('');
	let streaming = $state(true);

	$effect(() => {
		const es = new EventSource('/Api/chat/stream');
		es.onmessage = (e) => { content += e.data; };
		es.addEventListener('done', () => { streaming = false; es.close(); });
		return () => es.close();
	});
</script>

<ChatBubble role="agent" name="Steve" {content} {streaming} />
```

### Replay

`reconstructTurns` (`frontend/src/lib/assistant/reconstruct-turns.ts`) rebuilds the part list from persisted turns, so a reload renders the same surfaces as the live stream:

- Part order mirrors the stream: a stored assistant message's `reasoning` field leads, then text, then tool calls in order.
- `preview_view` and `show_documents` rebuild from the persisted `tool_calls[].arguments`; the ack result narrows a `show_documents` part to the ids the backend accepted.
- `list_documents` and `aggregate_documents` keep no persisted arguments (only UI tools carry them) — the `rows` / `stats` parts rebuild from the persisted tool-result envelope instead.
- Failed calls (`Error executing tool …`) and unparseable results fall back to the plain `tool_call` bar.
- A cancelled turn renders its partial content above a `> Cancelled.` marker, matching the live-stream notice. The flag comes from the row's `status === 'cancelled'` (the backend's turn lifecycle column), not from the legacy `error` value.
- A terminal `error` turn renders the user bubble plus a plain `> Error: …` segment.
- A `capped` turn (the backend hit the tool-loop iteration limit) renders like `error`: the trace rebuilds from the row's `response_messages`, with the raw cap message as the error line. The turn itself replays server-side — the next ask continues from the committed work.
- A `running` row renders from its persisted `request_messages` + `response_messages` (the backend checkpoints the committed exchange into the row while it generates) followed by a live thinking placeholder — the surface shows the same picture the live stream would, as far as the agent has committed. Selecting such a conversation locks the composer and starts the catch-up poll (below).

Both paths agree by construction: the replay transforms mirror the live-chunk transforms in `applyChunkToParts`.

### Catch-up poll

When the SSE stream breaks mid-turn (page refresh, network blip, phone switching networks), the backend keeps running the turn — the row sits at `status: 'running'`. Two paths lead to the same watcher in `ChatPanel`:

- **Broken stream.** `handleSend` detects the break (the `fetch` iterator ends without a terminal SSE event) and starts the watch.
- **Reload mid-turn.** `handleSelect` finds a `running` row in the loaded history — the row also carries the cancel token, so the composer's stop button works against the in-flight turn.

`runCatchup` (`frontend/src/lib/assistant/catchup.ts`) polls `GET /:id/turns/latest` every 3 s for up to 3 minutes until the conversation's latest turn reaches a terminal status, then refetches `listTurns` and rebuilds the thread from server truth. Each poll that finds the row still running fires `onTick(summary)` (`CatchupOptions.onTick`): the panel's watch rebuilds only the trailing suffix from the row's messages — call sites pass the base length (the turns before the watched turn), so earlier turns keep their identity — and re-points the still-generating marker at the current placeholder id. The backend checkpoints the committed exchange into the running row ~every 2 s, so a reloaded surface renders progressive output instead of a bare thinking placeholder. The user catches up without a reload; a timeout — or the status endpoint failing — leaves the partial state plus a `> Still generating. Reopen the chat to catch up.` note. `busy` stays true for the whole watch — a send into the conversation would 409 anyway (one running turn per conversation, enforced by the backend). The conversation rail marks the generating conversation with a pulsing running dot (see `ConversationList` → Running marker).

The watch never holds the panel hostage. Only an attached live stream blocks navigation (its chunk writes target the thread by index); a watch only polls server-side state, so selecting another conversation stays possible and cancels the watch — the generating conversation keeps its rail dot, and selecting it again starts a fresh watch. Re-clicking the selected row is a no-op.

## Drivers

The `AssistantDriver` interface (`frontend/src/lib/assistant/AssistantDriver.ts`) abstracts the backend interaction. Two implementations exist:

| Driver                | File                                                     | Purpose                                                                                                                |
| --------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `HttpAssistantDriver` | `frontend/src/lib/assistant/http-assistant-driver.ts`    | Talks to the real backend over `fetch` + SSE. Used by both mounts — the builder's and the workspace's floating window. |
| `MockAssistantDriver` | `frontend/src/lib/assistant/mock/MockAssistantDriver.ts` | In-memory, scripted responses for Storybook and component tests.                                                       |

The interface exposes one create method per conversation kind:
`createConversation` (generic), `createDomainBuilderConversation`, and
`createWorkspaceConversation` (no argument — the backend derives the owner
and the tool set; a caller without an enabling role gets a `403`), plus
`getUsage` — the rolling-window meter payload from
`GET /Api/assistant/usage`. The HTTP
driver injects the user's current paraglide locale into every create body
(`language` field; an explicit `language` on the input wins) — the backend
bakes it into the system prompt as a `## Language` directive so the
assistant writes in the user's language unless the user explicitly asks
for another one. The mock
ships a workspace fixture script (`workspaceScript` in
`mock/scripts.ts`) that drives `list_documents` → `show_documents` cards →
`navigate` → `aggregate_documents`, so the workspace stories run the same
sequence the renderers consume, offline; its constructor takes an options
bag whose `usage` overrides the default unlimited meter payload.

`HttpAssistantDriver.streamAsk` consumes the `fetch` response body as a `ReadableStream<Uint8Array>` and parses SSE frames into typed `AssistantSseEvent`s via `parseSseStream` (exported alongside the driver). Unlike `EventSource`, this works with `POST` requests and custom bodies, which the assistant streaming endpoint requires. On a non-2xx response the driver reads the backend's `{error: "…"}` body (`readErrorMessage`, exported from `assistant/errors.ts` next to `HttpAssistantError`) and throws `HttpAssistantError` with that text as the message — the status line stays the fallback when the body is not JSON.

The mock mirrors the backend's derived status: `listConversations` / `getConversation` compute `active` from the running-turn row, and the mock's stream session persists its cancel token on the running row — so the reload stories run the same sequences as the real surface. The session also checkpoints the scripted exchange into the running row per chunk, and a `ScriptedOutcome` of `{kind: 'capped'}` ends the turn like the backend's cap path — the partial exchange stays, the row goes `capped`, and the client sees the normal `error` SSE event. Two test helpers seed the reload-mid-turn state: `seedRunningTurn(conversationId, content, token)` opens a running row, `settleRunningTurn(conversationId, reply)` completes it the way the backend would.

## Storybook

Stories live alongside each component (`*.stories.svelte`). The `ChatBubble.AgentStreaming` and `ChatThread.Conversation` stories simulate token-by-token arrival with `setInterval` so the streaming UX is visible without a backend.
