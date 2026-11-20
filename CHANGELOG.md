# Changelog

Notable changes to Facet. The project is pre-1.0: a release can contain breaking changes.

## 0.2.0 — V1 beta (2026-11-20)

First public beta: a document store with event sourcing for mid-sized organizations.

### Stable in this beta

- Document store — domains, doctypes with typed fields, JSONB projections
- Event sourcing — append-only mutation log, history view, rollback and restore
- RBAC — roles, named scopes, context sets, enforcement on every surface; an `anonymous` role served to credential-less API requests (read-only by default, seeded with `core.Currency`); process-local role content cache with event-bus invalidation
- IAM — accounts, passwords, TOTP MFA, sessions, JWT, static API keys, OIDC federated login
- Integrations — Redis event bus, webhooks with signed delivery and a reconcile backstop, background jobs, cron, domain hooks, WebSocket live bridge, cross-domain replication, sidecar doctypes, document import and export, transactional email
- Storage — artifact store with signed grants, operator download path and audited force delete (`iam.ArtifactEvent`), secret store
- Web application — table, kanban, grid, calendar, markdown, form, show, and relations surfaces; saved views; filter bar; notification centre; audit log UI
- OAuth 2.1 authorization server — PKCE authorization code flow for external apps; the `facet` CLI signs in through it
- App hosting — build upload through `facet deploy`, deployment serving, and host dispatch
- Domain-builder assistant — LLM-guided authoring of doctype definitions, views, and fixtures
- Workspace assistant — in-application chat with tool access to the workspace
- MCP resource server — tool access for external agents under one pinned role, with RFC 7591 dynamic client registration for MCP clients
