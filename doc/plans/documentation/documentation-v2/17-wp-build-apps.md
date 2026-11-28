# WP 17 — Build: apps

**Goal:** a developer (or their coding agent) can build an app on Facet —
a browser app, a backend service, or an AI agent — pick the right way to
connect, and never be surprised by a permission error.

**Depends on:** WP 11, WP 12, WP 14 tutorial 3 (do not repeat it; link it).
**Audience:** Sam, and coding agents reading `.md` twins. Exact commands,
payloads and errors matter more here than anywhere else.

**Write scope:** `site-docs/src/content/docs/build/apps/**`.

**Batches:** A = index, how-apps-work, quickstart, `connect/*`; B = `data/*`,
`host/*`, `agents/*`. Paths and titles: `03-page-map.md` §3, §6.

---

## Shape of the group

The group index (`build/apps/index.md`) is a decision page, like "Choose how
you build". Three cards by app kind, each naming its sign-in path:

| You are building… | It signs in with | Start with |
|---|---|---|
| A browser app for people (hosted on Facet or elsewhere) | OAuth 2.1 + PKCE as the user, tokens bound with DPoP; the user picks a role on the consent screen | Quickstart → Sign users in |
| A backend service or integration | A service account and an app API key | Backend apps and service accounts |
| An AI agent | MCP, one role per endpoint | Connect agents over MCP |

Verify every cell against the code (`doc/backend/oauth.md`,
`doc/backend/app-system.md`, `doc/backend/mcp.md`, `src/oauth/`, `src/app/`,
`src/mcp/`).

## Page rules

- **`how-apps-work.md` is the mental model for developers** (explanation):
  the app outside the data, the request path, what an app can reach (the
  user's role ∩ the app's grant — the symbol may appear here, after the plain
  sentence), hosting, the permission manifest. One diagram.
- **`connect/what-an-app-can-do.md`** (from `concepts/apps-grants-roles.md`):
  the intersection in full, with the Brightwater check-out app as the worked
  example (`warehouse` role ∩ the app's grant → what Lucía can do through the
  app). Show the actual error an app gets when it reaches beyond its grant.
- **Every endpoint example** is a complete `curl` (or SDK call) with a real
  response from the running instance. Show error responses too, with their
  exact codes (link `reference/error-responses.md`).
- **SDK pages** use TypeScript examples that compile against the current
  `@facetapp/sdk` (`packages/sdk/`). Type-check them: put each example in a
  scratch project and run `tsc`; record it in the ledger.
- **DPoP, PKCE and CORS** get one plain sentence of purpose before the
  mechanics ("DPoP proves the token is being used by the app it was issued
  to, so a stolen token is useless on its own").
- **Agents pages:** `coding-agents.md` is about building *apps* with an
  agent (the domain part is in WP 16's `with-a-coding-agent.md`; link it).
  `mcp.md` shows a real client configuration (verify the endpoint shape
  `/api/_mcp/:role_slug` and discovery). `agent-tools.md` explains the tool
  families and the rights model; the full generated list stays in
  `reference/agent-tools.md`.
- **Troubleshooting** on every page: the error the developer sees, in its
  exact text, as the heading.

## Features

At least: APP-01 to APP-11, AI-03, AI-04, AI-05, AI-06 (app side), DOC-01 to
DOC-04, DOC-06, DOC-11, DOC-12, PLT-04 (app side), PLT-13, RBC-08 (developer
side), RBC-11, IAM-14, FE-12 (developer side), FE-21. Fill the page column of
`surfaces.md` for HTTP route groups, `@facetapp/cli` commands and agent tools.

## Done when

- [ ] Every example ran against the running instance (or type-checked, for
      SDK code); outputs pasted from real runs.
- [ ] Each of the three app kinds has a path from the index to a working
      result.
- [ ] Every feature above covered by a how-to or explanation page (R2).
- [ ] Preservation checklists closed for all old `apps/*` pages and
      `concepts/apps-grants-roles.md`.
- [ ] Gates pass; report per `00-contract.md` §10.
