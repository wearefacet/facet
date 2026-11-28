---
type: overview
title: Build apps
description: Pick the way your app signs in — browser, backend service, or AI agent — and start with the right page.
audience: [developer]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Your team keeps its data in Facet. Now something else needs to reach it:
a web app for the warehouse, a nightly sync job, or an agent that answers
questions. Each of them signs in differently, and the difference decides
which pages you need. Pick the row that matches what you are building.

> **For agents:** read `/llms.txt` first, then fetch any page as raw markdown
> at `/build/apps/<page>.md` (byte-for-byte, front-matter kept). Minimal build
> sequence: register an app (`POST /Api/app/App`) → sign in (`/OAuth/authorize`
> → `/OAuth/token`, or an app-owned `fct_` key) → call `/Api/<domain>/<Doctype>`
> with `Authorization`. Start at [How apps work](/build/apps/how-apps-work/).

## Pick your path

| You are building… | It signs in with | Start with |
|---|---|---|
| A browser app for people — hosted on Facet or on your own host | OAuth 2.1 + PKCE as the signing user. The user elects one role on the consent screen. Tokens can be bound with DPoP. | [Quickstart](/build/apps/quickstart/), then [Sign users in](/build/apps/connect/user-login/) |
| A backend service or integration with no person at the keyboard | A service account and one app-owned API key (`fct_…`) under a role you pin on the app | [Backend apps and service accounts](/build/apps/connect/backend-apps/) |
| An AI agent | MCP, one endpoint per role, over an app token or an API key | [Connect agents over MCP](/build/apps/agents/mcp/) |

The three paths share one rule. **An app can never do more than both the
app and its user are allowed.** You cap the app with grants at
registration. The role the caller acts as does the rest. The model behind
that rule is [How apps work on Facet](/build/apps/how-apps-work/).

A static frontend that only needs hosting skips sign-in work entirely —
deploy it and let it sign users in like any browser app. See
[Deploy your app on Facet](/build/apps/host/deploy/).

## All pages in this section

**Connect** — registration and the sign-in paths:

- [Register an app](/build/apps/connect/register/)
- [Sign users in](/build/apps/connect/user-login/)
- [Bind tokens to your app (DPoP)](/build/apps/connect/dpop/)
- [Allowed origins and CORS](/build/apps/connect/cors/)
- [Backend apps and service accounts](/build/apps/connect/backend-apps/)
- [Show only what the user can do](/build/apps/connect/permission-manifest/)
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/)

**Read and write data** — the surfaces a signed-in app calls:

- [Use the REST API](/build/apps/data/rest-api/)
- [The TypeScript SDK](/build/apps/data/sdk/)
- [Search from an app](/build/apps/data/search/)
- [Live updates](/build/apps/data/realtime/)
- [Upload and serve files](/build/apps/data/files/)
- [Bulk import and export](/build/apps/data/bulk-import-export/)

**Host and embed**:

- [Deploy your app on Facet](/build/apps/host/deploy/)
- [Embed the assistant in your app](/build/apps/host/embed-assistant/)

**AI agents**:

- [Build apps with a coding agent](/build/apps/agents/coding-agents/)
- [Connect agents over MCP](/build/apps/agents/mcp/)
- [What agents can do](/build/apps/agents/agent-tools/)

## Related

- [How apps work on Facet](/build/apps/how-apps-work/) — the model every page
  in this group builds on.
- [Build](/build/) — one layer up: modelling domains and access rules.
- [Control what apps can reach](/admin/apps-access/app-grants/) — the
  administrator's view of the same grants.
