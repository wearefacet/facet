---
title: Architecture at a glance
description: Follow a request through Facet, from the caller to the event bus, in one diagram.
audience: [evaluator, developer, operator]
features: [RBC-10, AUD-01, AUT-01]
sidebar:
  order: 3
verified_at: 7a6cb462
---

One diagram covers the whole request path. Each hop below it explains one box
in the diagram.

## The diagram

<!-- d2
direction: down
spa: "Browser SPA" {class: external}
apps: "Apps: OAuth" {class: external}
agents: "Agents: MCP" {class: external}
api: "HTTP API and MCP"
ctx: "Auth context: identity and one elected role"
enforcers: "Enforcers: role, row and field checks"
mutations: "Mutation log: append-only" {class: store}
projections: "Projections: current state" {class: store}
bus: "Event bus: Redis Streams"
consumers: "Hooks, webhooks, replication, live updates"

spa -> api
apps -> api
agents -> api
api -> ctx
ctx -> enforcers
enforcers -> mutations: write
enforcers -> projections: read
mutations -> projections
projections -> bus
bus -> consumers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/871f5719-light.svg" alt="Browser SPA" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/871f5719-dark.svg" alt="Browser SPA" loading="lazy" />
</div>

## The hops

### 1. Callers

Three kinds of caller share one API:

| Caller                                        | How it signs in                                                                | What it gets                                              |
| --------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------- |
| The browser SPA (single-page application)      | A session cookie, after a password, MFA, or SSO login                           | The full workspace UI                                      |
| An app                                        | OAuth 2.1 with PKCE. The user consents and elects one role                      | The rights of that role, cut down by the app's grant       |
| An agent                                      | MCP (Model Context Protocol) under one pinned role                              | The tools that role may see                                |

Static API keys and backend service accounts also enter here. A request with
no credential runs under the seeded `anonymous` role — its read grants are
the whole public API surface. A presented but invalid credential always
answers `401`; it never downgrades to anonymous.

### 2. Entry — HTTP and MCP

The Crystal backend serves the routes. Document routes look like
`/Api/{domain}/{doctype}`; platform routes start with an uppercase segment
(`/Api`, `/OAuth`, `/Ws`, `/Healthcheck`). The auth chain rejects an invalid
credential before any handler runs.

### 3. Auth context

Facet bundles the caller into an auth context: the principal, the one role it
acts under, and — for apps — the grant. Roles never merge. Humans, apps, and
agents all act under this one model, so enforcement behaves the same on every
channel.

### 4. Enforcers

The read and write enforcers turn role permissions into database checks:

- A permission names an action, a doctype path, and an optional row scope.
- Row scopes compile to SQL predicates. A list returns only the rows the role
  can see.
- Field tags mask invisible fields on reads and refuse writes into them.
- A denied single read answers the same `404` as a missing document.

### 5. Mutation log

An accepted write appends one row to the `mutations` table: who acted, through
which channel, on which document, with what change, and what caused it — a
request, an action, a hook, a rollback. The table is append-only. A retention
job replaces history older than the retention window with one snapshot row.

### 6. Projections

A PostgreSQL trigger applies each mutation to the `projections` table, which
holds the current state: the content, the display name, the search text, and
the backlinks. Reads never parse the log. They read projections, with the
role's scope predicates applied. Each row stores the id of its last mutation;
that value is the ETag (concurrency token) for optimistic writes.

### 7. Event bus

After the database commit, the write path publishes events to Redis Streams.
Consumers react: domain hooks run Lua, webhooks deliver signed envelopes,
replication copies fields across domains, and the WebSocket bridge pushes live
updates to browsers. Delivery is at-most-once by decision. The data of record
stays in PostgreSQL.

Reactions that write documents re-enter at hop 2, under the identity the
reaction runs as, and leave their own audit rows.

## See it yourself

The served OpenAPI document describes the v1 API surface. It needs a signed-in
caller, like every control-plane read:

```sh
curl -sS -H "Authorization: Bearer $FACET_TOKEN" \
  https://your-facet-host/Api/openapi.json
```

:::tip
Point an agent at this page plus the OpenAPI document. The diagram names the
hops; the auth context and the mutation log explain why an agent cannot bypass
rights or lose its audit trail.
:::

## Related

- [Security & governance overview](/start/security-governance/) — the enforcement rules in detail.
- [What is Facet](/start/what-is-facet/) — the product story behind this diagram.
- [Glossary](/start/glossary/) — the terms used above.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
