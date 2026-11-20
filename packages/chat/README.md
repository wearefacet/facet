# @facetapp/chat

Embeddable assistant chat for [Facet](https://github.com/wearefacet/facet). The package ships the chat as two custom elements — `<facet-assistant>` (inline panel) and `<facet-assistant-window>` (floating window) — the `FacetAssistant` facade that mounts them in one call, and the driver layer that talks to Facet's `/Api/assistant/...` HTTP surface (with an in-memory mock for tests and offline work).

## Quickstart

```
pnpm add @facetapp/chat
```

```js
import { FacetAssistant } from '@facetapp/chat';

FacetAssistant.open({
	baseUrl: 'https://facet.company.tld',
	fetch: hostFetch, // your authed fetch — see "Host auth"
	appId: 'core.app_123' // the app this assistant is scoped to
});
```

That is the whole setup. The first `open()` call stores the config and shows the assistant window, docked bottom-right. `FacetAssistant.close()` hides it; `FacetAssistant.destroy()` removes it.

## Facade

`FacetAssistant` is the one entry most hosts need:

| Method                   | What it does                                                                                                                                                                       |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configure(config)`      | Stores the config (merges over the previous one) and applies it to the live mounts. Mounts nothing.                                                                                |
| `open(config?)`          | Shows the floating window. The first call configures the facade. Later calls are idempotent — the same window re-opens.                                                            |
| `mount(target, config?)` | Mounts the inline panel into a host container (a CSS selector or an element) and returns the `<facet-assistant>` element. The panel fills the container; your CSS owns the layout. |
| `close()`                | Hides the active mount — closes the window, or hides the inline panel.                                                                                                             |
| `toggle()`               | Flips the visibility of the active mount.                                                                                                                                          |
| `destroy()`              | Removes every mount, clears the config, and clears the persisted window state.                                                                                                     |

One chat runs at a time. `open()` activates the window; `mount()` activates the inline panel. Activating one removes the other, so there is never a second driver or a second event stream.

With `bubble: true` in the config, a round launcher button shows in the bottom-right corner while the window is closed. One click opens the window again; the window's own close (X) returns to the launcher.

```js
FacetAssistant.open({ baseUrl: '…', fetch: hostFetch, appId: '…', bubble: true });
```

## Inline mount

```js
import { FacetAssistant } from '@facetapp/chat';

FacetAssistant.mount('#chat-root', { baseUrl: '…', fetch: hostFetch, appId: '…' });
```

The panel fills `#chat-root`. The host owns the layout — size the container, and the chat fills it. Nothing persists: `close()` hides the panel for the session only.

## Custom elements (no facade)

Importing the package registers both elements. Use them directly when you want full control:

```js
import '@facetapp/chat';

const el = document.querySelector('facet-assistant');
el.baseUrl = 'https://facet.company.tld';
el.fetch = hostFetch; // the host's authed fetch
el.appId = 'core.app_123';
```

`<facet-assistant>` fills its container; the host owns the layout. `<facet-assistant-window>` floats bottom-right with drag, maximize, collapse, and edge resize; its open state persists under the `facet.assistant.app.open` session key (open by default, with `open()` / `close()` / `toggle()` methods on the element). Set `bubble = true` (property or attribute) on the window element for the launcher button.

Both elements scope themselves to one app's assistant: the conversation rail lists with the `context.kind__eq=app` + `context.app_id__eq` filters, new conversations go through `POST /Api/assistant/app/conversations`, the usage meter shows whenever the caller has a finite budget, and a `403` renders a dedicated denial state. The backend owns the model, the prompt, and the tool set.

## Config

The facade config, the `open()` / `mount()` argument, and the element properties carry the same fields:

| Option     | Type                     | Default               | What it does                                                                 |
| ---------- | ------------------------ | --------------------- | ---------------------------------------------------------------------------- |
| `baseUrl`  | `string`                 | —                     | Facet origin (+ optional path prefix) for the default HTTP driver. Required. |
| `fetch`    | `typeof fetch`           | global `fetch`        | The host's authed fetch. See "Host auth".                                    |
| `appId`    | `string`                 | —                     | The `app.App` id this assistant is scoped to. Drives the rail filter.        |
| `language` | `string`                 | —                     | BCP-47 tag. Baked into the backend's `## Language` prompt block.             |
| `name`     | `string`                 | `'Assistant'`         | Display name in the window header and the turn headers.                      |
| `driver`   | `AssistantDriver`        | `HttpAssistantDriver` | Transport override.                                                          |
| `tokens`   | `Record<string, string>` | —                     | `--facet-*` design-token overrides, set on the mounted elements.             |
| `bubble`   | `boolean`                | `false`               | Floating mount only: show the launcher while the window is closed.           |

## Host auth

The package never sees credentials and never touches tokens. You pass a `fetch` that adds your own auth headers, and every driver call goes through it:

```js
async function hostFetch(input, init = {}) {
	const token = await getAppToken(); // your OAuth app token (DPoP-bound)
	return fetch(input, {
		...init,
		headers: {
			...init.headers,
			Authorization: `DPoP ${token}`,
			DPoP: await makeDpopProof(input, init), // one proof per request
			'X-Requested-With': 'XMLHttpRequest' // Facet's CSRF header
		}
	});
}

FacetAssistant.open({
	baseUrl: 'https://facet.company.tld',
	fetch: hostFetch,
	appId: 'core.app_123'
});
```

`X-Requested-With` must ride every state-changing call — Facet rejects POST/PATCH without it (`403`). The driver sends POST for create / stream / cancel / record and PATCH for archive; the DPoP proof must cover the request method and URL. Read Facet's OAuth documentation for the token and proof details.

## Error and empty states

| State                        | What the user sees                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `403` on conversation create | "Assistant unavailable" panel. The app's assistant is off, or the role lacks assistant access. The composer hides. |
| `429` on stream              | Budget notice on the turn — the 30-day token budget is spent.                                                      |
| Stream or network error      | An error line on the turn. The composer stays usable.                                                              |
| No conversations             | "No conversations yet." (archived view: "No archived conversations.")                                              |
| Empty thread                 | "Send a message to start this conversation."                                                                       |

## Theming

Design tokens cross the shadow boundary as CSS custom properties — every token is `--facet-*` prefixed, so they cannot collide with the host page. Override them on the element, or pass them through the facade's `tokens` option:

```css
facet-assistant {
	--facet-accent: #008f79;
}
facet-assistant[data-theme='dark'] {
	/* the dark token set applies automatically */
}
```

```js
FacetAssistant.open({ ..., tokens: { '--facet-accent': '#008f79' } });
```

## Mermaid diagrams

`mermaid` is an optional peer dependency. Install it in the host project and fenced ` ```mermaid ` blocks render as diagrams; without it they render as plain code blocks. The package bundle never includes mermaid.

## Driver + mock

```ts
import { HttpAssistantDriver, createMockAssistant } from '@facetapp/chat';

// Real backend. The injected fetch carries the host's authentication.
const driver = new HttpAssistantDriver('https://facet.company.tld', hostFetch);

// In-memory mock with the default scripted replies.
const driver = createMockAssistant();

const conversation = await driver.createAppConversation({ language: 'fr-CA' });
for await (const event of driver.streamAsk(conversation.id, { content: 'List active shipments' })) {
	// meta → chunk* → done | error | cancelled
}
```

The mock's replies come from ordered scripts — the first whose `match` predicate accepts the message is played. Prepend your own with `addScript`. Pass a custom transport to the facade with `driver:` when the host needs one.

## License

BUSL-1.1 — see [LICENSE](./LICENSE).
