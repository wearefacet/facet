---
title: Deploy your frontend
description: Deploy a static build, list releases, roll back, and set a custom domain.
audience: [developer]
features: [APP-06, APP-09]
sidebar:
  order: 8
verified_at: a77c6171
---

Facet serves your static build at the app's own host. The build is data, not
config: an `app.App` document carries `host` and `active_deployment`. A deploy
goes live with no restart and no config change. An app without a `host` value
is never dispatched.

> **For agents:** Deploy with `pnpx @facetapp/cli deploy --note "build"`, or POST multipart to
> `/Api/app/<app id>/deploy`: one `$content` JSON part
> (`{"spa": true, "activate": true, "note": "build", "files": [{"path": "index.html"}]}`) plus one
> `files[<i>].file` part per file. Auth: `Authorization: Bearer <token>`; the caller needs
> `deploy` on `app.App` in grant ∩ role. List:
> `GET /Api/app/Deployment?filters[app_id__eq]=app.App.<id>&sort=-revision`. Roll back: `PATCH /Api/app/App/<id>` with `{"active_deployment": "app.Deployment.<id>"}`.

## When to use this

Use this page when:

- You put a new build live on the app's host.
- You list releases and roll a bad revision back.
- You serve the app at a custom domain.

## Before you start

- An app document with status `active`. A draft or disabled app refuses deploys.
- The `deploy` action on `app.App`. The seeded `admin` role carries it; the
  seeded `editor` role does not. Over the API, grant and role must both carry it.
- For a custom domain: control of the Domain Name System (DNS) records.

## The model

Each deploy creates one `app.Deployment` document. The route computes the
`revision`: the app's highest revision plus one. The activate step sets
`active_deployment` on the app; the dispatcher serves that deployment's files.

The `spa` flag defaults to `true`. A page load that matches no file falls back
to `index.html`. An asset miss answers `404`.

## Steps

### 1. Deploy with the CLI

```sh
pnpx @facetapp/cli deploy --note "fix login bug"
```

The command walks the build folder, uploads one multipart request, and
activates the new revision; it prints the assigned revision and the app URL.

One request is one atomic deploy: the create and the activate run in one
transaction.

### 2. Or call the deploy route directly

For continuous integration (CI) that cannot run the CLI, call
`POST /Api/app/:id/deploy` yourself. The `:id` is the qualified app id,
`app.App.<id>`, as the app list returns. The body is multipart form data:

| Part | Content |
| --- | --- |
| `$content` | The deployment JSON: `spa`, `activate`, `note`, and `files` with one `{path}` entry per file. The JSON carries no `file` values; the server injects the artifact ids. |
| `files[0].file`, `files[1].file`, and so on | One part per file, in the same order as the `files` entries. |

The route validates every `path` against a safe-path rule: no leading `/`, no
`..`, no empty segment, valid UTF-8, and at most 1024 characters. A failed file
rolls the whole deploy back.

The route answers `{id, revision, activated, files}` — not a document envelope;
`files` counts the accepted files.

The caller needs `deploy` on `app.App` in grant ∩ role. An OAuth app token or
an app-owned API key works with a plain `Authorization: Bearer` header; an
operator session instead needs the `X-Requested-With` header for the
cross-site request forgery (CSRF) check. [Example](#example) shows the
complete call.

### 3. List releases

With the CLI:

```sh
pnpx @facetapp/cli releases
```

The list is newest revision first. The active release carries a `*`.

Over the API:

```http
GET https://facet.example.tld/Api/app/Deployment?filters[app_id__eq]=app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND&sort=-revision
```

The filter value carries the qualified form, `app.App.<id>`: reference fields
store qualified tokens.

### 4. Roll back

Rolling back points `active_deployment` at an older deployment. With the CLI:

```sh
pnpx @facetapp/cli rollback 2
```

An unknown revision fails with the list of known ones.

The API form is a plain document update; the reference value is a qualified
token, `app.Deployment.<id>`:

```sh
curl -X PATCH "https://facet.example.tld/Api/app/App/app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"active_deployment": "app.Deployment.01JF3V8QZK4M6TB2X9CWD5PNHR"}'
```

## Custom domains

Set `host` on the app document. The value is a bare lowercase hostname: no
scheme, no port, no path, no wildcard characters, and at most 253 characters.
The value is unique across apps, and Facet refuses a host that Facet itself
answers at. Point the DNS records for that hostname at Facet.

The server issues Transport Layer Security (TLS) certificates on demand.
Before it issues, the edge server calls the ask endpoint,
`GET /Edge/HostAsk?domain=<name>`. An unapproved name fails the TLS handshake
and never produces an HTTP request. A local name gets a certificate from the
internal certificate authority; a public name gets one through ACME
(Automatic Certificate Management Environment).

A new or moved host applies on the next request: the host cache invalidates
on every `app.App` mutation and rebuilds from the database. No restart is
needed.

One app carries one `host` value. The dispatcher matches the request hostname
exactly, never as a suffix.

## Serving behaviour

| Response | Cache header | Effect |
| --- | --- | --- |
| App shell: `index.html` and every navigation fallback | `public, no-cache` | The browser revalidates before reuse. A deploy is visible on the next navigation. |
| Every other asset | `public, max-age=300` | The browser reuses the asset for five minutes. |

Every response carries `X-Content-Type-Options: nosniff`. The content type is
decided at upload: file-name extension first, magic bytes as fallback.

A published build is public by design: anyone who can resolve the host gets
the bytes. Treat the build as readable source. The shipped HTML, JavaScript,
and CSS can hint at the backend schema, never at data. The API stays behind
role-based access control (RBAC).

Facet and app cookies never mix. Facet's session cookies are host-only, and
the reserved-host guard keeps an app off Facet's own origin.

The serving layer never adds a login wall. Host a private app behind your own
network gate: a virtual private network (VPN) or a proxy that checks access.

## Example

This call deploys a build from CI. The `files` parts follow the order of the
`files` entries in `$content`; the part filenames carry the build-relative
paths:

```sh
curl -X POST "https://facet.example.tld/Api/app/app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND/deploy" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F '$content={"spa": true, "activate": true, "note": "ci build 42", "files": [{"path": "index.html"}, {"path": "assets/app.js"}]};type=application/json' \
  -F "files[0].file=@dist/index.html;filename=index.html" \
  -F "files[1].file=@dist/assets/app.js;filename=assets/app.js"
```

## Troubleshooting

**The app host answers a bare `404`.**

The dispatcher matched no app. The `host` value must equal the request
hostname exactly; an app without a `host` value is never dispatched.

**Deploy answers `422`.**

The app is a draft or disabled, or its registration is marked `no_asset` — a
headless registration is not a deploy target. A `path` that breaks the
safe-path rule gives the same answer. Activate the app or fix the paths, then
deploy again.

**The TLS handshake fails on the custom domain.**

The ask endpoint approves only hosts that Facet knows. Check that `host` is
set on the app document and names the requested hostname exactly.

**An asset answers `404` after a deploy.**

The path is not in the deployment's file map. The `spa` fallback covers page
loads only. Check that the file exists in the uploaded build folder.

**Deploy answers `403`.**

The caller's grant and role miss `deploy` on `app.App`. The seeded `editor`
role does not carry the action. Use a credential whose role carries it.

**Deploy answers `401` with an app-owned key.**

The key's own app is a draft or disabled. App-owned keys answer the uniform
`401` in that case. Activate that app or use another credential.

## Related

- [Quickstart with the dev CLI](/apps/quickstart-dev-cli/) — the commands behind this page.
- [Registering an app](/apps/registering-app/) — app status and the dashboard.
- [CORS and allowed origins](/apps/cors-origins/) — how the API accepts browser calls from the app host.
- [Apps, grants and roles](/concepts/apps-grants-roles/) — the grant ∩ role model behind the deploy gate.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
