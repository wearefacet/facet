# WP 11 — Build apps section (`/apps/`)

Phase 1 (whole-doc §7) · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/apps/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.7. Audience: app developers, human **and** agent. Whole-doc rule: "every page has a copy-paste code block and a 'for agents' summary box."

## Format addendum for this section

After the lead paragraph, every `/apps/` page has:

```markdown
> **For agents:** one short paragraph — endpoints, keys, and the minimal
> call sequence, in plain text a coding agent can act on.
```

Code blocks are complete and runnable (WP 00). TypeScript examples target `@facetapp/sdk`.

## Batch A — platform (9 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `apps/how-apps-work.md` | How apps work on Facet | `audience: [developer]`, `features: [APP-01, RBC-08]` | `doc/backend/app-system.md` |
| `apps/quickstart-dev-cli.md` | Quickstart with the dev CLI | `audience: [developer]`, `features: [APP-09]` | `doc/packages/cli.md` |
| `apps/registering-app.md` | Registering an app (public vs confidential, headless) | `audience: [developer]`, `features: [APP-01, FE-12]` | `doc/backend/app-system.md` |
| `apps/oauth-login.md` | User login: OAuth 2.1 + PKCE | `audience: [developer]`, `features: [APP-02, APP-05, FE-21]` | `doc/backend/oauth.md` |
| `apps/dpop.md` | DPoP token binding | `audience: [developer]`, `features: [APP-03]` | `doc/backend/oauth.md` |
| `apps/cors-origins.md` | CORS and allowed origins | `audience: [developer]`, `features: [APP-08]` | `doc/backend/app-system.md`, `doc/backend/http-layer.md` |
| `apps/service-accounts.md` | Backend apps: service accounts and API keys | `audience: [developer, admin]`, `features: [APP-07]` | `doc/backend/iam.md`, `doc/backend/app-system.md` |
| `apps/hosting-deploy.md` | Hosting your frontend: deploy, releases, rollback, custom domains | `audience: [developer]`, `features: [APP-06, APP-09]` | `doc/backend/app-system.md`, `doc/packages/cli.md` |
| `apps/typescript-sdk.md` | The TypeScript SDK (`@facetapp/sdk`) | `audience: [developer]`, `features: [APP-10]` | `doc/packages/sdk.md` |

## Batch B — API and agents (11 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `apps/rest-api.md` | Working with the REST API (CRUD, filters, aggregates, ETags) | `audience: [developer]`, `features: [DOC-01, DOC-02, DOC-03, DOC-04, PLT-13]` | `doc/api/openapi.json`, `doc/backend/http-layer.md`, `doc/backend/document.md` |
| `apps/search.md` | Search | `audience: [developer]`, `features: [DOC-06]` | `doc/backend/search.md` |
| `apps/websockets.md` | Realtime with WebSockets | `audience: [developer]`, `features: [DOC-12]` | `doc/backend/websocket.md` |
| `apps/files.md` | Uploading and serving files | `audience: [developer]`, `features: [PLT-04]` | `doc/backend/artifact.md` |
| `apps/bulk-import-export.md` | Bulk import/export via API | `audience: [developer]`, `features: [DOC-11]` | `doc/backend/import-export.md` |
| `apps/permission-manifest.md` | Gating your UI with the permission manifest | `audience: [developer]`, `features: [RBC-11, IAM-14]` | `doc/backend/rbac.md`, `doc/backend/oauth.md` |
| `apps/chat-embed.md` | Embedding the assistant (`@facetapp/chat`) | `audience: [developer]`, `features: [APP-11, AI-03]` | `doc/packages/chat.md` |
| `apps/mcp-agents.md` | MCP: connecting agents | `audience: [developer]`, `features: [AI-05, APP-04]` | `doc/backend/mcp.md` |
| `apps/agent-tools.md` | Agent tools | `audience: [developer]`, `features: [AI-04, AI-06]` | `doc/backend/agent-tools.md` |
| `apps/ai-coding-agents.md` | Building apps with AI coding agents | `audience: [developer]`, `features: [AI-06]` | `doc/backend/agent-tools.md`, this site's own agent output (`/llms.txt`, raw `.md` pages — WP 03) |
| `apps/index.md` | (section overview) | — | finish last |

## Writing notes

- `oauth-login.md`: a complete runnable PKCE flow (code + redirect), plus a table of errors.
- `rest-api.md`: link to `/reference/rest-api/` for the machine-readable reference; this page teaches the shapes (filters, ETags, 422 error body, non-disclosing 404).
- `ai-coding-agents.md` explains how agents consume Facet docs: `llms.txt`, `/<path>.md`, complete code blocks — and links the skills/system-prompt material in `doc/backend/domain-builder-skills.md`.

`apps/index.md` (from WP 01): the batch that runs last finishes the index.

## Definition of done (per batch)

- [ ] Batch pages written, front-matter per WP 00, "For agents" box on every page.
- [ ] Every code block compiles or runs (SDK examples against a dev instance).
- [ ] `cd site-docs && npm run build` passes.
