# Chat — `@facetapp/chat`

The embeddable assistant chat for Facet apps: a package a host application installs to mount a chat scoped to one `app.App` assistant. It is a standalone package, separate from the SvelteKit frontend and the Crystal backend; it ships the chat as two Svelte 5 custom elements, a one-call JS facade, the HTTP/SSE driver, and an in-memory mock.

> **Source-only for now.** `@facetapp/chat` is not on the npm registry yet — `npm view @facetapp/chat` answers `404`. The install line in [`packages/chat/README.md`](../../packages/chat/README.md) resolves once a maintainer publishes the package by tag (see [`release.md`](release.md)). Until then, consume the source under `packages/chat/` directly.

Publishing the package to npm is a separate concern: see [`release.md`](release.md). User-facing documentation lives in [`packages/chat/README.md`](../../packages/chat/README.md) — it ships in the npm tarball. This doc covers the module layout and the contracts behind it.

## Source files

All paths are relative to `packages/chat/`:

| File | Role |
| ---- | ---- |
| `src/index.ts` | Public surface — importing the package registers both custom elements and exports the facade, the element classes, the driver layer, and the mock. |
| `src/facade.ts` | `FacetAssistant` — `configure` / `open` / `mount` / `close` / `toggle` / `destroy` over the two mounts. |
| `src/messages.ts` | Plain-English UI copy. v1 ships English; the `language` option feeds the backend prompt, not this copy. |
| `src/element/facet-assistant.svelte.ts` | `<facet-assistant>` — the inline mount. Property/attribute config, shadow root, no persistence. |
| `src/element/facet-assistant-window.svelte.ts` | `<facet-assistant-window>` — the floating mount. Persists open state under `facet.assistant.app.open`; `bubble` mode renders the launcher while closed. |
| `src/element/ChatMount.svelte` | Shared view for both elements — app scoping (rail filter, app create route, usage meter, denial state) around the chat core. |
| `src/element/shadow-styles.ts` | Injects the shadow-root sheet once per element. |
| `src/styles/shadow.css` | Design tokens (`--facet-*`, light on `:host`, dark on `:host([data-theme='dark'])`) + the inner reset. |
| `src/chat/ChatPanel.svelte` | Reusable chat core: conversation rail, thread, composer, turn logic. |
| `src/chat/AssistantWindow.svelte` | Floating window shell — drag, maximize, collapse, edge resize, persisted state. |
| `src/chat/AssistantLauncher.svelte` | Round launcher button shown while the window is closed (bubble mode). |
| `src/chat/tool-call-helpers.ts` | Parts model + SSE chunk application. |
| `src/chat/reconstruct-turns.ts` | Replay of stored turns into parts. |
| `src/chat/ui-tools.ts` | UI-tool chunk parsers. |
| `src/chat/assistantWindowState.ts` | Session-storage persistence, package-owned `facet.assistant.app.*` keys. |
| `src/chat/*.svelte` | Surface parts — bubbles, input, scroll, thread, turn panel, rail, thought block, tool bar, usage meter, rows/stats cards, copy + relative-time helpers. |
| `src/markdown/` | Markdown renderer (allowlisted `marked` walker + highlight.js), `Markdown.svelte`, `MermaidDiagram.svelte` (optional peer dependency). |
| `src/driver/AssistantDriver.ts` | The transport contract — one method per backend route. |
| `src/driver/http-assistant-driver.ts` | Real backend driver — fetch + SSE (`parseSseStream`, `buildListQuery`, `appConversationFilters`). |
| `src/driver/errors.ts` | `HttpAssistantError` + `readErrorMessage`. |
| `src/driver/catchup.ts` | Reopen catch-up poll against the latest-turn summary. |
| `src/driver/mock/` | `MockAssistantDriver` — scripted in-memory replies for tests and offline development. |

The chat core and the driver were extracted from the main application's chat components (`doc/frontend/chat.md`); the main app keeps its own workspace assistant and mounts nothing from the package.

## Public API

### Facade

```ts
import { FacetAssistant } from '@facetapp/chat';

FacetAssistant.open({ baseUrl, fetch, appId, language?, name?, tokens?, bubble? });
FacetAssistant.mount(target, config?); // → the <facet-assistant> element
FacetAssistant.configure(config);
FacetAssistant.close();
FacetAssistant.toggle();
FacetAssistant.destroy();
```

One config serves both mounts (`FacetAssistantConfig`); fields not set fall back to the elements' defaults. The facade tracks one **active mount**: `open()` activates the floating window, `mount()` activates the inline panel, and activating one removes the other — one chat instance at a time. `close` / `toggle` act on the active mount; `destroy` tears everything down and clears the persisted window state.

| Method | Behaviour |
| --- | --- |
| `configure(config)` | Merges the config over the stored one and applies it to the live mounts. Mounts nothing. |
| `open(config?)` | Configures on the first call, then shows the floating window. Idempotent. |
| `mount(target, config?)` | Mounts the inline panel into a selector or element; returns the element. Moving to a new container keeps the same element. |
| `close()` | Closes the window (persisted), or hides the inline panel. |
| `toggle()` | Flips the visibility of the active mount. |
| `destroy()` | Removes every mount, clears the config, clears `facet.assistant.app.*` session keys. |

### Elements

| Element | Mount | Notes |
| --- | --- | --- |
| `<facet-assistant>` | Inline — the panel fills the host container | Properties: `baseUrl`, `appId`, `language`, `name`, `fetch`, `driver`. `base-url` / `app-id` / `language` / `name` also read as attributes at connect time. Nothing persists. |
| `<facet-assistant-window>` | Floating — docked bottom-right | Same properties plus `bubble`; `open()` / `close()` / `toggle()` / `isOpen` persist under the package-owned key `facet.assistant.app.open`. |

Importing the package registers both elements. Theming crosses the shadow boundary as `--facet-*` custom properties; a dark theme is one attribute away (`data-theme='dark'`).

### Drivers

| Driver | File | Purpose |
| --- | --- | --- |
| `HttpAssistantDriver` | `src/driver/http-assistant-driver.ts` | The real backend over fetch + SSE. Constructor takes `baseUrl` + an injectable `fetch`. |
| `MockAssistantDriver` | `src/driver/mock/MockAssistantDriver.ts` | In-memory, scripted responses. Exported as `createMockAssistant()`. |

The `AssistantDriver` interface maps one method per backend route; hosts that need a custom transport implement it and pass it as `driver`. The driver types (`Conversation`, `Turn`, `AssistantSseEvent`, `AssistantUsage`, …) are part of the public surface.

## Backend contract

| Call | Backend surface |
| ---- | ---- |
| Create a conversation | `POST /Api/assistant/app/conversations` — body `{language?}`; the backend derives `kind: 'app'` + `app_id` from the authenticated caller |
| Rail list | `GET /Api/assistant/conversations` with `filters[context.kind__eq]=app` + `filters[context.app_id__eq]=…` |
| Stream a turn | `POST /Api/assistant/conversations/:id/stream` — body `{content, attachments?}` (SSE: `meta` → `chunk*` → `done` / `error` / `cancelled`) |
| Cancel | `POST /Api/assistant/cancel/:turn_token` |
| Get / turns / record / archive | The shared `/Api/assistant/conversations/...` surfaces; reserved-kind rows are owner-scoped |
| Usage | `GET /Api/assistant/usage` |

Every tool call in the `chunk*` phase carries a `tool_call` chunk pair (`running` → `ok` / `error`) — including calls the backend rejected before execution (invalid JSON or schema-invalid arguments). A rejected call resolves as an `error` bar; no call is invisible.

State-changing calls require the `X-Requested-With` CSRF header — the host's injected `fetch` adds it (README → Host auth). The per-app gates live in `App::Gate` (`src/assistant/app/gate.cr`): the app must exist, `assistant_enabled` must be on, the caller must be app-scoped, and the active role's connectivity must list the `assistant` channel. See [`backend/assistant.md`](../backend/assistant.md) → the `app` kind.

## Testing

Vitest with happy-dom, `pnpm test` inside `packages/chat`. The suites mirror the layers:

| Suite | Covers |
| ---- | ---- |
| `test/driver/*.test.ts` | SSE framing, cancel, catch-up, list query with the app filter, error mapping, injected-fetch contract, mock scripts |
| `test/chat/*.test.ts` | Parts machinery, replay, UI-tool parsers |
| `test/elements/*.test.ts` | Both mounts as DOM tests against the mock — streaming turn, cancel, markdown, history replay, archive round-trip, denial state, persisted open state, mermaid fallback |
| `test/facade.test.ts` | Idempotent open, mount + destroy cleanup, bubble mount, toggle targeting the active mount |
| `test/elements/dist-smoke.test.ts` | The built `dist/index.js` — element registration + a mounted panel (skipped until `pnpm build` ran) |

The `app-head-to-toe` e2e scenario (`e2e/tests/app-head-to-toe.e2e.ts`) runs the package against the live stack: the runner image bundles `dist/index.js` into a browser-ready ESM (`e2e/scripts/bundle-assistant.mjs`), deploys it inside the hosted mini-app, and drives the floating window — the rail round trip over DPoP, the disabled-app denial, the enable through the settings tab, and the conversation create. It never streams a turn: the stack config points the assistant provider at a dead stub on purpose (harness decision D11).

Package gates: `pnpm check` (svelte-check), `pnpm test`, `pnpm build`, `pnpm lint` (prettier).

The package stays on TypeScript 6: `svelte-check` does not support TypeScript 7 standalone (it needs a dual TypeScript 6 + 7 install plus the experimental `--tsgo` flag). Nothing shipped depends on TypeScript — it is a dev dependency — so `api` and `cli` upgrade to TypeScript 7 while `chat` waits for standalone svelte-check support.
