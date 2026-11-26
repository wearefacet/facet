---
title: Deploy your app on Facet
description: Upload a static build with the CLI, list releases, roll back, and serve at a custom host.
type: how-to
audience: [developer]
features: [APP-06, APP-09]
verified_at: eee55a2
sidebar:
  order: 0
---

Facet serves your static build at the app's own host. The build is data, not
config: an `app.App` document carries `host` and `active_deployment`. A
deploy goes live with no restart and no config change. An app without a
`host` value is never dispatched.

> **For agents:** Deploy with `pnpx @facetapp/cli deploy --note "build"`, or POST multipart to
> `/Api/app/<app id>/deploy`: one `$content` JSON part
> (`{"spa": true, "activate": true, "note": "build", "files": [{"path": "index.html"}]}`) plus one
> `files[<i>].file` part per file. Auth: `Authorization: Bearer <token>`; the caller needs
> `deploy` on `app.App` in grant ∩ role. List:
> `GET /Api/app/Deployment?filters[app_id__eq]=app.App.<id>&sort=-revision`. Roll back:
> `PATCH /Api/app/App/<id>` with `{"active_deployment": "app.Deployment.<id>"}`.

## When to use this

Use this page when:

- You put a new build live on the app's host.
- You list releases and roll a bad revision back.
- You serve the app at a custom host.

## Before you start

- An app document with status `active`. A draft or disabled app refuses
  deploys.
- The `deploy` action on `app.App`. The seeded `admin` role carries it; the
  seeded `editor` role does not. Over the API, grant and role must both
  carry it.
- For a custom host: control of the Domain Name System (DNS) records.

Brightwater's check-out board runs as a Facet-hosted app: the
`bfr-checkout` app record signs its browser calls in with OAuth and serves
its build from Facet hosting.

## The model

Each deploy creates one `app.Deployment` document. The route computes the
`revision`: the app's highest revision plus one. The activate step sets
`active_deployment` on the app; the dispatcher serves that deployment's
files.

The `spa` flag defaults to `true`. A page load that matches no file falls
back to `index.html`. An asset miss answers `404`.

## Steps

### 1. Deploy with the CLI

The CLI has no install step — run it through `pnpx` (Node 20 or newer).
First write the project config:

```sh
pnpx @facetapp/cli init
```

The command asks for three values — the app slug, the build folder, and the
instance URL — and writes `facet.config.json` at the project root:

```json
{
  "app": "bfr-checkout",
  "outDir": "dist",
  "spa": true,
  "targets": { "default": { "url": "https://facet.localhost:3443" } },
  "defaultTarget": "default"
}
```

Then sign in once. The command resolves the `facet-cli` app registration on
the instance, opens the consent screen in a browser, and stores the session
at `~/.config/facet/auth.json`:

```sh
pnpx @facetapp/cli login
```

Now deploy:

```sh
pnpx @facetapp/cli deploy --note "fix login bug"
```

The command walks the build folder, uploads one multipart request, and
activates the new revision:

```text
Deploying "dist" to https://facet.localhost:3443 (target of app "bfr-checkout")…
Packed 4 files.
Deployed revision 3 (4 files stored).
Active at checkout.brightwater.example
```

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

The route validates every `path` against a safe-path rule: no leading `/`,
no `..`, no empty segment, valid UTF-8, and at most 1024 characters. A
failed file rolls the whole deploy back.

The route answers `{id, revision, activated, files}` — not a document
envelope; `files` counts the accepted files.

The caller needs `deploy` on `app.App` in grant ∩ role. An OAuth app token
or an app-owned API key works with a plain `Authorization: Bearer` header;
an operator session instead needs the `X-Requested-With` header for the
cross-site request forgery (CSRF) check. [Example](#example) shows the
complete call.

### 3. List releases

With the CLI:

```sh
pnpx @facetapp/cli releases
```

The list is newest revision first. The active release carries a `*`:

```text
* 3  fix login bug        2026-11-26T13:02:44Z
  2  add depot filter     2026-11-25T09:14:02Z
  1  first build          2026-11-24T16:40:51Z

(* marks the active deployment)
```

Over the API:

```sh
curl -skg -b facet-cookies.txt \
  'https://facet.localhost:3443/Api/app/Deployment?filters[app_id__eq]=app.App.<id>&sort=-revision'
```

The filter value carries the qualified form, `app.App.<id>`: reference
fields store qualified tokens.

### 4. Roll back

Rolling back points `active_deployment` at an older deployment. With the
CLI:

```sh
pnpx @facetapp/cli rollback 2
```

The command prints `Revision 2 (<deployment id>) is now the active deployment.`
An unknown revision fails with the known ones:
`No deployment with revision 9. Known revisions: 3, 2, 1.`

The API form is a plain document update; the reference value is a qualified
token, `app.Deployment.<id>`:

```sh
curl -sk -b facet-cookies.txt -X PATCH \
  'https://facet.localhost:3443/Api/app/App/<app id>' \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"active_deployment": "app.Deployment.<deployment id>"}'
```

## Custom hosts

Set `host` on the app document. The value is a bare lowercase hostname: no
scheme, no port, no path, no wildcard characters, and at most 253
characters. The value is unique across apps, and Facet refuses a host that
Facet itself answers at. Point the DNS records for that hostname at Facet.

The server issues Transport Layer Security (TLS) certificates on demand.
Before it issues, the edge server calls the ask endpoint,
`GET /Edge/HostAsk?domain=<name>`. An unapproved name fails the TLS
handshake and never produces an HTTP request. A local name gets a
certificate from the internal certificate authority; a public name gets one
through ACME (Automatic Certificate Management Environment).

A new or moved host applies on the next request: the host cache invalidates
on every `app.App` mutation and rebuilds from the database. No restart is
needed.

One app carries one `host` value. The dispatcher matches the request
hostname exactly, never as a suffix.

## Serving behaviour

| Response | Cache header | Effect |
| --- | --- | --- |
| App shell: `index.html` and every navigation fallback | `public, no-cache` | The browser revalidates before reuse. A deploy is visible on the next navigation. |
| Every other asset | `public, max-age=300` | The browser reuses the asset for five minutes. |

Every response carries `X-Content-Type-Options: nosniff`. The content type
is decided at upload: file-name extension first, magic bytes as fallback.

A published build is public by design: anyone who can resolve the host gets
the bytes. Treat the build as readable source. The shipped HTML, JavaScript,
and CSS can hint at the backend schema, never at data. The API stays behind
role-based access control (RBAC).

Facet and app cookies never mix. Facet's session cookies are host-only, and
the reserved-host guard keeps an app off Facet's own origin.

The serving layer never adds a login wall. Host a private app behind your
own network gate: a virtual private network (VPN) or a proxy that checks
access.

## Example

This call deploys a build from CI. The `files` parts follow the order of the
`files` entries in `$content`; the part filenames carry the build-relative
paths:

```sh
curl -sk -X POST 'https://facet.localhost:3443/Api/app/app.App.<app id>/deploy' \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F '$content={"spa": true, "activate": true, "note": "ci build 42", "files": [{"path": "index.html"}, {"path": "assets/app.js"}]};type=application/json' \
  -F "files[0].file=@dist/index.html;filename=index.html" \
  -F "files[1].file=@dist/assets/app.js;filename=assets/app.js"
```

The answer names the revision and the activation:

```json
{ "id": "01JF3V8QZK4M6TB2X9CWD5PNHR", "revision": 3, "activated": true, "files": 2 }
```

## Troubleshooting

**The app host answers a bare `404`.**

The dispatcher matched no app. The `host` value must equal the request
hostname exactly; an app without a `host` value is never dispatched.

**Deploy answers `422`.**

The app is a draft or disabled, or its registration is marked `no_asset` —
a headless registration is not a deploy target. A `path` that breaks the
safe-path rule gives the same answer. Activate the app or fix the paths,
then deploy again.

**`pnpx @facetapp/cli init` refuses: `facet.config.json already exists in <root>. Edit it by hand.`**

One config lives per project. Edit the existing file, or delete it and run
`init` again.

**`pnpx @facetapp/cli login` prints `No active "facet-cli" app registration found on <instance>.`**

The instance carries no active `facet-cli` app document. An operator creates
or activates it — see [Registering an app](/build/apps/connect/register/).

**`pnpx @facetapp/cli login` prints `Timed out waiting for the browser sign-in.`**

The CLI waited five minutes for the consent round-trip. Open the printed
authorize URL in a browser that can reach the instance, then start again.

**Deploy answers `404` with `No app with slug "<slug>" on <instance>.`**

No app document carries that slug. Create the app first — write on
`app.App` — or fix the `app` value in `facet.config.json`. Copy the
`client_id` from the app's Credentials screen, never the document id, when
you configure OAuth.

**The TLS handshake fails on the custom host.**

The ask endpoint approves only hosts that Facet knows. Check that `host` is
set on the app document and names the requested hostname exactly.

**An asset answers `404` after a deploy.**

The path is not in the deployment's file map. The `spa` fallback covers
page loads only. Check that the file exists in the uploaded build folder.

**Deploy answers `403`.**

The caller's grant and role miss `deploy` on `app.App`. The seeded `editor`
role does not carry the action. Use a credential whose role carries it.

**Deploy answers `401` with an app-owned key.**

The key's own app is a draft or disabled. App-owned keys answer the uniform
`401` in that case. Activate that app or use another credential.

## Related

- [Quickstart with the dev CLI](/build/apps/quickstart/) — the commands behind this page.
- [Registering an app](/build/apps/connect/register/) — app status and the dashboard.
- [CORS and allowed origins](/build/apps/connect/cors/) — how the API accepts browser calls from the app host.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the grant ∩ role model behind the deploy gate.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
