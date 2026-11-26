---
type: overview
title: Build apps
description: Build frontends and integrations on Facet with the SDK, the REST API, and MCP.
audience: [developer]
features: []
sidebar:
  order: 0
verified_at: a77c6171
---

You can build an app on Facet — by hand or with an AI coding agent. Register
the app, sign users in, then call Facet over the REST API or the TypeScript
SDK. The pages here cover each step, and every one carries code you can copy
and run.

> **For agents:** read `/llms.txt` first, then fetch any page as raw markdown
> at `/build/apps/<page>.md` (byte-for-byte, front-matter kept). Minimal build
> sequence: register an app (`POST /Api/app/App`) → sign in (`/OAuth/authorize`
> → `/OAuth/token`, or an app-owned `fct_` key) → call `/Api/<domain>/<Doctype>`
> with `Authorization`. Start at [How apps work](/build/apps/how-apps-work/).

## Platform

- [How apps work on Facet](/build/apps/how-apps-work/)
- [Quickstart with the dev CLI](/build/apps/quickstart/)
- [Registering an app (public vs confidential, headless)](/build/apps/connect/register/)
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/)
- [DPoP token binding](/build/apps/connect/dpop/)
- [CORS and allowed origins](/build/apps/connect/cors/)
- [Service accounts for backend apps](/build/apps/connect/backend-apps/)
- [Hosting your frontend: deploy, releases, rollback, custom domains](/build/apps/host/deploy/)
- [The TypeScript SDK (`@facetapp/sdk`)](/build/apps/data/sdk/)

## API and agents

- [Working with the REST API (CRUD, filters, aggregates, ETags)](/build/apps/data/rest-api/)
- [Search](/build/apps/data/search/)
- [Realtime with WebSockets](/build/apps/data/realtime/)
- [Uploading and serving files](/build/apps/data/files/)
- [Bulk import/export via API](/build/apps/data/bulk-import-export/)
- [Gate your UI with the manifest](/build/apps/connect/permission-manifest/)
- [Embedding the assistant (`@facetapp/chat`)](/build/apps/host/embed-assistant/)
- [MCP: connecting agents](/build/apps/agents/mcp/)
- [Agent tools](/build/apps/agents/agent-tools/)
- [Building apps with AI coding agents](/build/apps/agents/coding-agents/)

## Related

- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the concept behind
  the grant ceiling.
- [Reference](/reference/) — the machine-readable details, including the REST
  API reference.
