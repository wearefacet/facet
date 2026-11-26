---
type: explanation
title: How apps work on Facet
description: See how a Facet app registers, signs in, and calls the API under a grant ceiling.
audience: [developer]
features: [APP-01, RBC-08]
sidebar:
  order: 1
verified_at: a77c6171
---

An app on Facet is a registration: a document of doctype `app.App`. Your
code runs outside Facet and calls Facet over HTTP. Facet never runs app
code and never gives an app a database connection — Facet is both the
identity source and the data source. The registration document carries the
policy that bounds every call the app makes.

> **For agents:** Register the app with `POST /Api/app/App` (session cookie
> plus `X-Requested-With: XMLHttpRequest`); the create hook writes the
> read-only `client_id`. A browser app signs in with `GET /OAuth/authorize`,
> then `POST /OAuth/token` with PKCE, and calls `GET /Api/{domain}/{doctype}`
> with `Authorization: Bearer` or `DPoP <access_token>`. A backend app calls
> with `Authorization: Bearer fct_…` from `POST /Api/app/:id/api-key`. Every
> request resolves grant ∩ role from the live app document, so a grant edit
> applies on the next request.

## When to use this

Reach for this page when:

- You build a frontend or an integration on Facet.
- You must explain why an app call was allowed or refused.
- You plan a registration and must choose a client type.

## Before you start

- Read [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) for the grant
  model.
- Registering and editing apps needs `update` rights on `app.App`. The
  seeded `admin` and `editor` roles hold them.

## Explanation

### The registration document

The app document holds the fields that decide identity and reach:

| Field | Purpose |
| --- | --- |
| `slug` | Unique, URL-safe name. Immutable after create. |
| `client_type` | `public` or `confidential`. Default `public`. |
| `redirect_uris` | Addresses the sign-in flow may return to. |
| `allowed_origins` | Browser origins Facet mirrors for Cross-Origin Resource Sharing (CORS). |
| `status` | `draft`, `active`, or `disabled`. Default `draft`. |
| `grants` | The ceiling on what the app may attempt. |

`client_id` is a generated id. The create hook writes it, and no caller can
change it. Backend fields such as `service_role_id` belong to confidential apps —
see [Backend apps](/build/apps/connect/backend-apps/). [Registering an
app](/build/apps/connect/register/) walks through every field.

### The app runs outside Facet

The app never runs inside the Facet process and never touches the database.
Every read and write rides the REST API. Because grants live in document
content, each grant change is event-sourced, audited, and RBAC-checked like
any other document write.

### Two client types

A `public` app is browser-only. Proof Key for Code Exchange (PKCE) protects
the code exchange. Demonstrating Proof of Possession (DPoP) binds the token
to a key. The consent screen is always shown, and no secret exists.

A `confidential` app signs in through the same consent screen and adds a
backend. The backend authenticates as the app with an app-owned API key
through a service account.

### The grant is a ceiling

Each grant names one concrete doctype path, for example `crm.Contact`.
Wildcard targets are refused at write time with `422 wildcard_target`. The
actions are `read`, `write`, `delete`, or a named action of the doctype.
`write` expands to `create` plus `update` at resolution. A `required: true`
action must also sit on the role, or the role is unusable for the app.

### Two bounds apply together

The grant is the ceiling. The role decides what exists to grant. Facet keeps
only the actions the role also gives. The role comes from one of two places:

- **Browser flow** — the signing account elects one role on the consent
  screen. The screen shows on every sign-in.
- **Backend flow** — the service role pinned on the app document.

Row scopes on the role survive unchanged. A grant never widens a row filter.

### Re-resolved on every request

The token never carries the grant. Facet reloads the live app document,
resolves grant ∩ role, and builds the request context from it. A grant edit
applies on the next request, so no token needs re-issuing.

<!-- d2
direction: down
request: "Request arrives with a token" {class: external}
verify: "AuthHandler verifies the token"
reload: "Reload the live app document"
resolve: "Resolve grant ∩ role"
enforce: "Enforce the grant pre-check, then the role"
run: "Run the operation"
attribute: "Attribute the mutation to the app" {class: store}

request -> verify
verify -> reload
reload -> resolve
resolve -> enforce
enforce -> run
run -> attribute
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9470d917-light.svg" alt="Request arrives with a token" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9470d917-dark.svg" alt="Request arrives with a token" loading="lazy" />
</div>

### Tokens and keys

An app token carries `typ: "app"` and rides the OAuth sign-in flow. An
app-owned key starts with `fct_` and rides the API-key channel. Both
channels end in the same bounds: grant ∩ role, re-resolved per request.

### The dashboard launcher

`GET /Api/iam/apps` lists the active apps a member can open. Each card
carries a `usable` flag: the member's role covers every required grant
action, or the card renders muted. `no_launcher: true` removes a headless
registration from the list.

### An app cannot widen itself

An app-scoped caller holds `update` on `app.App`, so the standard model
alone would let it widen its own ceiling. The update hook refuses any patch
that carries `grants` or `service_role_id` from an app-scoped caller. An
operator session keeps full edit rights.

### Attribution

Every app-scoped mutation records the app id in `mutations.app`. The audit
list filters with `app__eq`. Login events carry app attribution: consent
grants, token refreshes, and refusals at the grant pre-check. See [Auditing
activity](/admin/history/audit/).

## Troubleshooting

**A call answers `403` for a doctype the app used to reach.**

The grant was narrowed or removed. The next request already runs under the
tighter bound.

**The app cannot read labels or definitions.**

An app token cannot read `core.DocType` unless a grant names it. Grant
`read` on `core.DocType`, or hardcode the values in the app.

**The app is missing from the dashboard launcher.**

`no_launcher: true` hides it, or `status` is `draft` or `disabled`.

**A PATCH that sets `grants` fails from the app's own credentials.**

The update hook refuses self-widening. Edit the app from an operator
session.

## Related

- [Registering an app](/build/apps/connect/register/) — create the registration.
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the browser sign-in.
- [Service accounts for backend apps](/build/apps/connect/backend-apps/) —
  the key channel.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the concept
  behind the two bounds.
- [Controlling app reach (grants)](/admin/apps-access/app-grants/) — the admin view.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
