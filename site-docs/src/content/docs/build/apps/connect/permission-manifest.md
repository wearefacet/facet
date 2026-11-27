---
type: how-to
title: Show only what the user can do
description: Read the caller's permission manifest and size your UI affordances with it.
audience: [developer]
features: [RBC-11, IAM-14]
sidebar:
  order: 5
verified_at: eee55a2
---

Every credential that can call the API can also read what it may attempt. The permission manifest on
`GET /Api/iam/me` lists the doctype paths, the actions, and the row scopes the credential reaches. Use
it to hide buttons and to size affordances. The manifest is advisory: the server re-checks every
request and never reads the manifest back.

> **For agents:** Endpoint: `GET /Api/iam/me` — returns `permissions` (map of `"domain.Doctype"` keys to
> action lists), `scopes` (doctype → action → scope aliases), `connectivity`, and `assistant`
> (`{access, token_budget, name}`). SDK: `await facet.whoami()` (cached) → `await facet.can('delete', 'rentals.Booking')`
> answers `'all' | 'scoped' | 'denied'`; `await facet.scopes('update', 'rentals.Booking')` reads the aliases;
> `await facet.refreshRights()` after a role switch or a grant change. Reserved keys `"*.*"`,
> `"{domain}.*"`, and `"*.*.except.<action>"` are matcher input, not doctypes.

## When to use this

Use the manifest when:

- You hide buttons or menu entries the caller cannot use.
- You show a limit hint when row scopes narrow an action.
- You adapt your app to the channels and the assistant the role allows.

## Before you start

- A credential that calls the API: a session token, an OAuth app token, or a static `fct_` key. All
  three read the manifest.
- The reach model behind the manifest: [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).
- How apps receive that reach: [How apps work on Facet](/build/apps/how-apps-work/).

## Steps

### 1. Read the manifest

Call the endpoint with your credential. A static key rides the bearer scheme:

```sh
curl -sk https://facet.localhost:3443/Api/iam/me \
  -H "Authorization: Bearer $FACET_API_KEY"
```

An app token rides the DPoP scheme with a proof on every call — see
[Bind tokens to your app (DPoP)](/build/apps/connect/dpop/). The response carries four fields beyond the account profile:

| Field | Content |
| --- | --- |
| `permissions` | A map of `"domain.Doctype"` keys to action lists. |
| `scopes` | A map of doctype to action to scope aliases. `[]` means unrestricted. |
| `connectivity` | The active role's channels: `mcp`, `webhook`, `api`, `assistant`. |
| `assistant` | `{access, token_budget, name}` — the chat gate, the budget (`null` = unlimited), and the display name. |

### 2. Recognise the key forms

The `permissions` map folds the role's permission lines. These rules produce every key:

- A concrete line on `rentals.Booking` lands under the literal key `"rentals.Booking"`.
- A domain-wide line on `equipment` lands under the domain-wildcard key `"equipment.*"`.
- A wildcard line keeps its action list on the literal `"*.*"`.
- A wildcard line with carve-outs folds them per action under `"*.*.except.<action>"`, for example
  `"*.*.except.create"`. The value lists the subtracted paths.
- A key appears only when its fold is non-empty. A doctype key never contains `*`.

The `scopes` map mirrors the row rules. `scopes["rentals.Booking"]["update"]` is `[]` when the update
right is unrestricted, or an alias list such as `["mine"]` when row scopes apply. Wildcard lines fold
under the `"*.*"` scopes key; domain-wide lines fold under the `"{domain}.*"` key.

This manifest is real. Lucía Ferrer holds Brightwater's `warehouse` role —
domain-wide lines on `equipment` and `core`, concrete read lines elsewhere:

```json
{
  "active_role": "iam.Roles.warehouse",
  "channel": "session",
  "connectivity": ["api", "mcp", "assistant"],
  "permissions": {
    "equipment.*": ["*"],
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "clients.Company": ["read"],
    "clients.Contact": ["read"],
    "core.Comment": ["*"],
    "core.Attachment": ["*"]
  }
}
```

The domain-wide line `{"on": "equipment", "action": "*"}` folded to the
`"equipment.*"` key. Ravi holds the seeded `admin` role; his manifest is
the whole thing: `"*.*": ["*"]`.

### 3. Match a key in the right order

If you write your own matcher, grant in this order and stop at the first hit:

1. Admin short-circuit: the `"*.*"` key with actions `["*"]` grants everything.
2. Exact key: `"rentals.Booking"` grants `rentals.Booking`. A key also reaches its descendants —
   `"rentals.Booking"` reaches `rentals.Booking.Line`-style child doctypes.
3. Domain-wildcard key: `"equipment.*"` grants every doctype in the domain. Carve-outs never suppress it.
4. Wildcard fallback: the `"*.*"` action list grants the path. But a `"*.*.except.<action>"` entry
   for the checked action subtracts it when it equals or prefix-matches the path. An entry on
   `core.DocType` also excludes `core.DocType.Comment`. An explicit key grant is never suppressed.

Read the scope aliases at the key that granted the action: the doctype key behind an exact hit,
`scopes["{domain}.*"]` behind a domain-wide grant, and `scopes["*.*"]` behind the fallback.

An editor-like role shows the carve-out form in one picture. It reads and
creates everywhere, cannot create system settings, and updates and deletes
companies:

```json
{
  "permissions": {
    "*.*": ["create", "read"],
    "*.*.except.create": ["core.SystemSettings"],
    "crm.Company": ["update", "delete"],
    "hr.*": ["read"]
  },
  "scopes": {
    "*.*": { "create": [], "read": [] },
    "crm.Company": { "update": ["mine"], "delete": [] },
    "hr.*": { "read": ["team"] }
  }
}
```

### 4. Use the SDK helpers

The SDK matches both manifest shapes for you:

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'brw-checkout', redirectUri: `${location.origin}/auth/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

await facet.whoami(); // GET /Api/iam/me — cached after the first call

facet.can('read', 'rentals.Booking'); // Promise<'all' | 'scoped' | 'denied'>
facet.scopes('update', 'rentals.Booking'); // Promise<string[]> — [] means unrestricted
await facet.refreshRights(); // re-fetch after a role switch or a grant change
```

`'all'` is unrestricted. `'scoped'` means the action exists but row scopes apply at the server — read
the aliases with `scopes`. `'denied'` means no manifest key reaches the path.

:::caution[Size affordances, never gate security]
The server re-checks every request and never reads the manifest back. Treat a denied call's `404` or
`403` as the authority. A `'scoped'` answer means the server narrows the rows; read the aliases with
`scopes` and name the limit in the UI.
:::

### 5. App-scoped callers read the effective manifest

An app token or an app-owned key reads the resolved intersection of grant and role, not the role's
own manifest:

- Keys are the concrete doctypes the grant names, plus the domain-wildcard form when a wildcard grant
  target collapses with a wildcard role permission.
- There is no `"*.*"` fallback.
- A carved-out doctype does not appear at all. The fold that covers its own path removes the action.
- A residual carve-out on descendants appears under the reserved `"crm.Company.except.update"` key
  form, for the matcher to subtract.

The check-out app's token answers with exactly the three granted doctypes —
even though Ravi, who signed in, holds the `admin` role:

```json
{
  "active_role": "iam.Roles.admin",
  "channel": "api",
  "permissions": {
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "equipment.Item": ["read", "create", "update"]
  }
}
```

The stock-sync key answers the same way for its pinned role:

```json
{
  "active_role": "iam.Roles.stock_sync",
  "channel": "api",
  "expires_at": null,
  "permissions": {
    "equipment.Item": ["read", "create", "update"]
  }
}
```

The SDK helpers match this shape too. From the app's perspective, a document its grant does not name
does not exist. See [How apps work on Facet](/build/apps/how-apps-work/) for the grant and role model.

## Example

This example sizes a toolbar from the manifest. It removes the toolbar when the read right is denied,
hides the delete button when the delete right is denied, and shows a hint when the update right is
scoped:

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'brw-checkout', redirectUri: `${location.origin}/auth/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

// On the redirect route, after sign-in:
await auth.handleCallback(location.href);

await facet.whoami(); // load and cache the manifest

const toolbar = document.querySelector('#booking-toolbar') as HTMLElement;
const deleteButton = toolbar.querySelector('#delete-booking') as HTMLButtonElement;
const hint = toolbar.querySelector('#scope-hint') as HTMLElement;

if ((await facet.can('read', 'rentals.Booking')) === 'denied') {
	toolbar.remove();
} else {
	deleteButton.hidden = (await facet.can('delete', 'rentals.Booking')) === 'denied';

	const updateScopes = await facet.scopes('update', 'rentals.Booking');
	hint.hidden = updateScopes.length === 0;
	if (updateScopes.length > 0) hint.textContent = 'You can change bookings you own.';
}
```

Against Ravi's app token in step 5, this keeps the toolbar visible (`read` sits on the exact key),
hides the delete button (no manifest key grants `delete` — the grant does not name it), and leaves
the hint hidden (the scopes are empty).

## Troubleshooting

**The affordance shows, but the call answers `403`.**

The manifest is advisory; the server denies. The reach moved — call `await facet.refreshRights()`
and re-render.

**A button is missing although the role grants the action.**

A wildcard carve-out covers the path, or the manifest is stale. Check the
`"*.*.except.<action>"` keys and call `refreshRights`.

**`*.*` is missing for an app token.**

The effective manifest never carries the wildcard fallback. That is correct — the grant is the
ceiling.

**An iteration over the manifest keys renders reserved keys.**

Never iterate either map to render one doctype. The reserved `"*.*"`, `"{domain}.*"`, and
`"*.*.except.create"` keys are not doctypes. Render from the doctype definitions instead.

## Related

- [How apps work on Facet](/build/apps/how-apps-work/) — the grant and role model behind the effective manifest.
- [The TypeScript SDK](/build/apps/data/sdk/) — the client that ships `whoami`, `can`, and `scopes`.
- [Roles and permissions](/admin/people/roles-and-permissions/) — the line grammar the manifest folds.
- [Show each role only its rows](/admin/people/row-scopes/) — what the scope aliases mean.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the concept.
- Internals on GitHub: [doc/backend/iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
- [Security and governance](/discover/security/)
- [Why you act as one role at a time](/admin/under-the-hood/one-role-at-a-time/)
