---
title: Embed the assistant in your app
description: Embed the Facet assistant chat in your app with the @facetapp/chat package.
type: how-to
audience: [developer]
features: [APP-11, AI-03]
verified_at: eee55a2
sidebar:
  order: 1
---

`@facetapp/chat` mounts the Facet assistant inside your app, scoped to your
app's own assistant. The backend owns the model, the prompt, and the tools.
The package owns the UI: two custom elements, a one-call facade, and an HTTP
driver. Your app supplies the credentials through one function, and the
package never sees them.

> **For agents:** Gate: `const gate = await facet.assistant()` — `{access, configured, token_budget,
> name}`; hide the launcher when `gate.access` is false. Install: `pnpm add @facetapp/chat`. Auth:
> pass a `fetch` that adds `Authorization: DPoP <token>` (fresh `DPoP` proof per request when the
> token is bound) and `X-Requested-With: XMLHttpRequest` — POST/PATCH without it answers `403`.
> Mount: `FacetAssistant.open({ baseUrl, fetch: hostFetch, appId })` or
> `FacetAssistant.mount('#chat-root', config)`; `close()` hides, `destroy()` removes. Route:
> `POST /Api/assistant/app/conversations`, then stream (SSE).

## When to use this

Embed the assistant when:

- You give your app's accounts an assistant without building chat UI.
- You want the conversation rail, streaming, and tool rendering handled for
  you.
- You need a scripted mock for tests and offline work.

## Before you start

Three gates must pass before a conversation opens:

- The caller is app-scoped: an OAuth app token. See
  [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) and
  [DPoP token binding](/build/apps/connect/dpop/).
- The app's `assistant_enabled` flag is on. The app's admin sets it on the
  Settings tab; the save needs `update` on `app.App`. Optional
  `assistant_prompt` on the same tab adds app-specific instructions to the
  prompt.
- The caller's role connectivity lists the `assistant` channel.

A session on the Brightwater dev instance answers the gate like this (the
check-out app has its assistant off, so `access` is `false` for it):

```json
{
  "access": true,
  "configured": true,
  "token_budget": null,
  "name": "Assistant"
}
```

Check the gate from your app with the SDK:

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({
	slug: 'brw-checkout',
	redirectUri: 'http://localhost:5173/auth/callback',
	baseUrl: 'https://facet.localhost:3443'
});
const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

const gate = await facet.assistant(); // { access, configured, token_budget, name }
if (!gate.access) {
	// The chat would render its denial panel. Hide the launcher instead.
}
```

`token_budget` is `null` when the budget is unlimited.

## Steps

### 1. Install the package

```sh
pnpm add @facetapp/chat
```

The import registers two custom elements and exports the `FacetAssistant`
facade.

### 2. Pass an authed fetch

The package never touches tokens. You pass a `fetch` that adds your auth
headers, and every driver call goes through it:

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
```

`getAppToken` and `makeDpopProof` are yours to write — see
[DPoP token binding](/build/apps/connect/dpop/) for the proof contract. The
proof must cover the request method and URL. A token issued without a DPoP
proof is a bearer token; send it under `Authorization: Bearer <token>` with
no `DPoP` header.

`X-Requested-With` must ride every state-changing call. Facet rejects
POST/PATCH without it with `403`. The driver sends POST for create, stream,
cancel, and record, and PATCH for archive.

### 3. Open the floating window

```js
import { FacetAssistant } from '@facetapp/chat';

FacetAssistant.open({
	baseUrl: 'https://facet.localhost:3443',
	fetch: hostFetch,
	appId: '06H1FQF7NGDJJKSNHXPYT6627M', // the brw-checkout app record id
	bubble: true
});
```

The first call stores the config and shows the window, docked bottom-right.
`bubble: true` shows a round launcher button while the window is closed.
`FacetAssistant.close()` hides it; `FacetAssistant.destroy()` removes every
mount and clears the stored state.

### 4. Or mount inline

```js
FacetAssistant.mount('#chat-root', {
	baseUrl: 'https://facet.localhost:3443',
	fetch: hostFetch,
	appId: '06H1FQF7NGDJJKSNHXPYT6627M'
});
```

The panel fills `#chat-root`; your CSS owns the layout. Nothing persists:
`close()` hides the panel for the session only.

One chat runs at a time. `open()` activates the window; `mount()` activates
the inline panel. Activating one removes the other, so there is never a
second event stream.

### 5. Configure the mount

The facade config, the `open()` / `mount()` argument, and the element
properties carry the same fields:

| Option | Type | Default | Purpose |
| --- | --- | --- | --- |
| `baseUrl` | `string` | — | Facet origin, with an optional path prefix, for the HTTP driver. Required. |
| `fetch` | `typeof fetch` | global `fetch` | Your authed fetch — step 2. |
| `appId` | `string` | — | The `app.App` id this assistant is scoped to. Drives the rail filter. |
| `language` | `string` | — | BCP-47 tag. Baked into the backend prompt. |
| `name` | `string` | `'Assistant'` | Display name in the window header and the turn headers. |
| `driver` | `AssistantDriver` | `HttpAssistantDriver` | Transport override — see the example below. |
| `tokens` | `Record<string, string>` | — | `--facet-*` token overrides, set on the mounted elements. |
| `bubble` | `boolean` | `false` | Floating mount only: the launcher while the window is closed. |

## Explanation

### What the package handles

The chat scopes itself to one app. The conversation rail lists with the
`context.kind__eq=app` and `context.app_id__eq` filters. New conversations
go through `POST /Api/assistant/app/conversations`. The backend builds the
conversation context from the authenticated caller; the body carries the
language only.

Streaming rides server-sent events: a `meta` frame, then `chunk` frames,
then `done`, `error`, or `cancelled`. Every tool call renders, including
calls the backend rejected before execution. A rejected call resolves as an
error bar, so no call is invisible.

Denial and budget states are built in. A `403` on the conversation create
renders the "Assistant unavailable" panel and hides the composer. A `429`
on the stream renders the budget notice on the turn.

### Elements and theming

Importing the package registers `<facet-assistant>` (inline panel) and
`<facet-assistant-window>` (floating window). Use the elements directly when
you want full control. Theming crosses the shadow boundary as CSS custom
properties; every token is `--facet-*` prefixed:

```css
facet-assistant {
	--facet-accent: #008f79;
}
```

Mermaid diagrams are an optional peer dependency. Install `mermaid` in the
host project, and fenced `mermaid` blocks render as diagrams; without it
they render as code blocks.

## Example

The package ships a real driver and a scripted mock. This example streams
one turn against the mock, with no backend:

```ts
import { createMockAssistant, FacetAssistant } from '@facetapp/chat';

const driver = createMockAssistant(); // in-memory, scripted replies

const conversation = await driver.createAppConversation({ language: 'en-GB' });
for await (const event of driver.streamAsk(conversation.id, { content: 'List active bookings' })) {
	console.log(event); // meta → chunk* → done | error | cancelled
}

// Hand the mock to the facade to style and test the UI without a backend.
FacetAssistant.open({ baseUrl: 'https://facet.localhost:3443', driver, appId: '06H1FQF7NGDJJKSNHXPYT6627M' });
```

Against a real backend, construct the HTTP driver with your authed fetch and
pass it the same way:

```ts
import { HttpAssistantDriver } from '@facetapp/chat';

const driver = new HttpAssistantDriver('https://facet.localhost:3443', hostFetch);
```

## Troubleshooting

**The chat renders the "Assistant unavailable" panel.**

The app flag is off, the role lacks the `assistant` channel, or the caller
is not app-scoped. Check `await facet.assistant()` — the `access` field
mirrors the same gate. On the Brightwater dev instance the `brw-checkout`
app ships with `assistant_enabled: false`; its conversation create answers
`403` with `{"error":"You do not have access to the app assistant"}`.

**Every POST answers `403`.**

Your fetch dropped `X-Requested-With`. Facet rejects POST/PATCH without it.

**Turns fail instantly.**

Your fetch dropped the `Authorization` header or the `DPoP` proof. A DPoP
failure answers `401` with no detail about which check failed.

**The usage meter never shows.**

The caller has an unlimited budget. The meter shows only for a finite one.
`GET /Api/assistant/usage` answers `{total, estimated_total, budget,
window_start, window_days}` — a `budget` of `null` means unlimited.

## Related

- [The TypeScript SDK](/build/apps/data/sdk/) — the `facet.assistant()` gate.
- [DPoP token binding](/build/apps/connect/dpop/) — the token scheme and the proof contract.
- [How apps work on Facet](/build/apps/how-apps-work/) — app scoping and the grant ceiling on tool calls.
- [Governing the assistant](/admin/assistant/govern/) — budgets, names, and instructions in the main app.
- Internals on GitHub:
  [packages/chat/README.md](https://github.com/wearefacet/facet/blob/main/packages/chat/README.md).
- [The assistant: AI with your rights](/discover/how-it-works/assistant/)
