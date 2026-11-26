---
type: explanation
title: Auth contexts
description: Every channel resolves to one auth context with one elected role, from the browser to the API key.
audience: [developer, admin]
features: [RBC-10, IAM-14]
sidebar:
  order: 2
verified_at: 7a6cb462
---

A browser tab, an app, an agent and a command-line script can all call the
same API. Facet gives every request the same authorization shape: one auth
context. Read this page to see what sits inside that context, and what the one
elected role costs.

## Explanation

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
which one. The mutation log carries the channel into every audit row.

**The grant is a ceiling.** When an app calls, the enforcers check the grant
before the role's own permissions. The effective reach is the overlap: what
the role allows and what the grant names. Facet re-resolves the grant from
live app content on every request, so narrowing a grant takes effect on the
next call — no new token. An app-owned API key follows the same rule.

**Enforcement is the same everywhere.** The read and write enforcers sit
inside the document services, not in the HTTP layer. They read the auth
context, whoever built it. A denied read answers the same non-disclosing
`404` on every channel — browser, app, agent or key.

### Who is calling

`GET /Api/iam/me` tells a caller who it is and which role it acts under.
The response carries the account (id, display name, email), the elected
role, and the account's other roles. It also carries the permission
manifest the frontend uses to gate navigation and buttons. A session caller,
an app token and an API key all get an answer. An app-scoped caller gets a
manifest cut to its grant: from the app's point of view, a doctype the grant
does not name does not exist.

:::note
A request with no credential at all runs under the seeded `anonymous` role —
its read grants define the public surface. A presented but invalid credential
always answers `401`. It never falls back to anonymous.
:::

**The trade-off.** One elected role means no privilege aggregation. A caller
cannot hold two roles at once, so a wider reach needs a deliberate switch:
the browser has a role switch, an OAuth consent elects one role per session,
and an MCP URL pins its role for the whole session.

## Related

- [Security & governance overview](/discover/security/) — the permission model summarized for auditors.
- [Build apps](/build/apps/) — register an app and send its users through role election.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — how the enforcers turn permissions into SQL.
- [Apps: grants ∩ roles](/build/apps/connect/what-an-app-can-do/) — the grant ceiling in detail.
- [Reference](/reference/) — endpoint shapes, the identity endpoint included.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
