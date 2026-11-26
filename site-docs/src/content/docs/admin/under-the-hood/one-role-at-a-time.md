---
title: Why you act as one role at a time
description: Every request carries one identity and one role. See how each channel sets them, and why roles never merge.
type: explanation
audience: [developer, admin]
features: [RBC-10, IAM-14]
verified_at: eee55a2
sidebar:
  order: 2
---

A browser tab, an app, an agent and a command-line script can all call the
same API. Facet gives every request the same authorization shape: one
identity and exactly one role. Facet calls this pair the **auth context**.
Below are the ways of connecting, and what the one elected role costs.

*Every channel funnels into one shape: who is calling, and as which role.*

<!-- d2
direction: down
browser: "Browser session" {class: external}
app: "OAuth app token" {class: external}
mcp: "MCP agent" {class: external}
key: "API key fct_…" {class: external}
context: "One auth context: principal + one elected role" {class: info}
enforcers: "Enforcers check the context"

browser -> context
app -> context
mcp -> context
key -> context
context -> enforcers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e9cff36e-light.svg" alt="Browser session" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e9cff36e-dark.svg" alt="Browser session" loading="lazy" />
</div>

## The four channels

| Channel | Credential | The context holds |
| --- | --- | --- |
| Browser SPA (single-page application) | Session cookie, after sign-in | The account and the elected role |
| OAuth app (an open delegation protocol) | App token, issued after the user consents and elects one role | The account, the elected role, the app grant |
| MCP agent (Model Context Protocol) | Bearer token; the URL pins the role | The account and the pinned role |
| API key | Static key (`fct_…`); the key pins an account and a role | The account and the key's role; app-owned keys also carry the grant |

**One context per request.** Every request resolves to exactly one auth
context. The context holds the principal — who calls — and exactly one
elected role. For app calls it also holds the app grant. Roles never merge:
an account can hold three roles and still act under one of them per request.
A request authenticates through exactly one channel, and the context records
which one. The change log carries the channel into every audit row.

**The grant is a ceiling.** When an app calls, the enforcers check the grant
before the role's own permissions. The effective reach is the overlap: what
the role allows and what the grant names. Facet re-resolves the grant from
live app content on every request, so narrowing a grant takes effect on the
next call — no new token. An app-owned API key follows the same rule.

**Enforcement is the same everywhere.** The read and write enforcers sit
inside the document services, not in the HTTP layer. They read the auth
context, whoever built it. A denial looks the same on every channel —
browser, app, agent or key. See
[How access is enforced](/admin/under-the-hood/how-access-is-enforced/)
for the exact answers.

## Who is calling

`GET /Api/iam/me` tells a caller who it is and which role it acts under.
The response carries the account (id, display name, email), the elected
role (`active_role`), and the account's other roles (`available_roles`). It
also carries the permission manifest the frontend uses to gate navigation and
buttons, plus the `visible_tags` the role can read. A session caller, an app
token and an API key all get an answer. An app-scoped caller gets a manifest
cut to its grant: a doctype the grant does not name does not exist, from the
app's point of view.

:::note
A request with no credential at all runs under the seeded `anonymous` role —
its read grants define the public surface. A presented but invalid credential
always answers `401`. It never falls back to anonymous.
:::

## The trade-off

One elected role means no privilege aggregation. A caller cannot hold two
roles at once, so a wider reach needs a deliberate switch. The browser has a
role switch. An OAuth consent elects one role per session. An MCP URL pins
its role for the whole session. Each path is a choice a person makes, and the
audit log records the role that acted — that is the point.

## Related

- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — how the enforcers turn permissions into SQL.
- [Assign roles](/admin/people/assign-roles/) — how the account's roles are set and elected.
- [What an app is allowed to do](/build/apps/connect/what-an-app-can-do/) — the grant ceiling in detail.
- [Security & governance overview](/discover/security/) — the permission model summarized for auditors.
- [Reference](/reference/) — endpoint shapes, the identity endpoint included.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
- [Show only what the user can do](/build/apps/connect/permission-manifest/)
