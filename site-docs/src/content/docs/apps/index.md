---
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
> at `/apps/<page>.md` (byte-for-byte, front-matter kept). Minimal build
> sequence: register an app (`POST /Api/app/App`) → sign in (`/OAuth/authorize`
> → `/OAuth/token`, or an app-owned `fct_` key) → call `/Api/<domain>/<Doctype>`
> with `Authorization`. Start at [How apps work](/apps/how-apps-work/).

## Platform

- [How apps work on Facet](/apps/how-apps-work/)
- [Quickstart with the dev CLI](/apps/quickstart-dev-cli/)
- [Registering an app (public vs confidential, headless)](/apps/registering-app/)
- [User login: OAuth 2.1 + PKCE](/apps/oauth-login/)
- [DPoP token binding](/apps/dpop/)
- [CORS and allowed origins](/apps/cors-origins/)
- [Service accounts for backend apps](/apps/service-accounts/)
- [Hosting your frontend: deploy, releases, rollback, custom domains](/apps/hosting-deploy/)
- [The TypeScript SDK (`@facetapp/sdk`)](/apps/typescript-sdk/)

## API and agents

- [Working with the REST API (CRUD, filters, aggregates, ETags)](/apps/rest-api/)
- [Search](/apps/search/)
- [Realtime with WebSockets](/apps/websockets/)
- [Uploading and serving files](/apps/files/)
- [Bulk import/export via API](/apps/bulk-import-export/)
- [Gate your UI with the manifest](/apps/permission-manifest/)
- [Embedding the assistant (`@facetapp/chat`)](/apps/chat-embed/)
- [MCP: connecting agents](/apps/mcp-agents/)
- [Agent tools](/apps/agent-tools/)
- [Building apps with AI coding agents](/apps/ai-coding-agents/)

## Related

- [Apps, grants and roles](/concepts/apps-grants-roles/) — the concept behind
  the grant ceiling.
- [Reference](/reference/) — the machine-readable details, including the REST
  API reference.
