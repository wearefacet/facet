---
title: Quickstart with the dev CLI
description: Install, sign in, and deploy a first build with the facet CLI in a few commands.
audience: [developer]
features: [APP-09]
sidebar:
  order: 2
verified_at: a77c6171
---

The `@facetapp/cli` command-line interface (CLI) turns a static build folder
into a deployed Facet app revision. There is no install step: run every
command through `pnpx`. The CLI needs Node 20 or newer.

> **For agents:** The whole flow is three commands: `pnpx @facetapp/cli init`, then
> `pnpx @facetapp/cli login`, then `pnpx @facetapp/cli deploy --note "first build"`.
> Config sits in `facet.config.json` (keys `app`, `outDir`); the session sits in
> `~/.config/facet/auth.json` (mode 600). For automation set `FACET_TOKEN` to an
> access token; it wins over any stored session and is never refreshed. Deploy is
> one multipart `POST /Api/app/:id/deploy`; the route answers `{id, revision, activated, files}`.

## When to use this

Use the CLI when:

- You deploy a first static build to a Facet instance.
- You push a new build from your machine or from continuous integration (CI).
- You list releases and roll a bad build back.

## Before you start

- A Facet instance you can reach over HTTPS, and an account on it.
- A role that carries `deploy` on `app.App`. The CLI signs in with your account,
  and you elect one role on the consent screen. The seeded `admin` role carries
  `deploy`; the seeded `editor` role does not.
- A static build folder. Any static site generator works.
- Node 20 or newer.

## Steps

### 1. Write the configuration

```sh
pnpx @facetapp/cli init
```

The command asks for three values: the app slug, the build folder, and the
instance URL. It writes `facet.config.json` at the project root.

With a stored session, `init` reads the app by slug. When that app does not
exist, the CLI offers to create it. Creating needs `write` on `app.App`. A
created app is a draft, so activate it in the dashboard before the first
deploy — see [Registering an app](/apps/registering-app/).

Without a stored session, `init` writes the config and stops. Run `login` next.

### 2. Sign in

```sh
pnpx @facetapp/cli login
```

The command opens a browser at the OAuth consent screen. The flow is the
authorization code flow with PKCE (Proof Key for Code Exchange). The challenge
method is S256. The CLI starts a one-shot loopback server and receives the code
there.

The CLI signs in through the seeded `facet-cli` registration. That registration
accepts loopback redirect addresses only: `http://localhost:*`,
`http://127.0.0.1:*`, and `http://[::1]:*`.

The session lands in `~/.config/facet/auth.json` with mode `600`.
`$XDG_CONFIG_HOME` moves the location. The file holds one entry per instance URL.

:::note[Token refresh]
Access tokens are short-lived. The CLI refreshes a stored session only when it
is near expiry or after a `401` answer. It never refreshes eagerly, because the
server enforces a refresh floor. Rotated refresh tokens are stored back at once.
:::

### 3. Build and deploy

Build your app with any static site generator. Then run:

```sh
pnpx @facetapp/cli deploy --note "first build"
```

The command walks the build folder. It skips `node_modules`, `.git`, and
`.DS_Store`. It uploads one multipart request and activates the new revision.
It prints the assigned revision and the app URL; the scheme and port follow the
instance URL.

Pass `--no-activate` to upload a revision that stays dormant:

```sh
pnpx @facetapp/cli deploy --no-activate
```

### 4. Check the session

```sh
pnpx @facetapp/cli whoami
```

The command prints the instance, the account behind the stored token, the
active role, and the app's active revision.

### 5. Manage releases

```sh
pnpx @facetapp/cli releases
```

The list shows the app's deployments, newest revision first. The active one
carries a `*`.

Roll a bad build back by revision:

```sh
pnpx @facetapp/cli rollback 2
```

The command points `active_deployment` at the deployment with revision `2`. An
unknown revision fails with the list of known ones.

Sign out when you finish:

```sh
pnpx @facetapp/cli logout
```

The command removes the stored session for the instance. It is idempotent.

### 6. Deploy from CI

Put an access token in the CI environment:

```sh
export FACET_TOKEN="paste-an-access-token"
pnpx @facetapp/cli deploy --note "ci build 42"
```

The environment token wins over any stored session. The CLI never refreshes it.
When it expires, the run fails with the re-login hint. Put a fresh token in the
CI secret before the next run.

## Example

This `facet.config.json` configures two targets:

```json
{
  "app": "myapp",
  "outDir": "dist",
  "spa": true,
  "targets": {
    "staging": { "url": "https://staging.facet.example.tld" },
    "prod": { "url": "https://facet.example.tld" }
  },
  "defaultTarget": "staging"
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `app` | yes | The app slug on the Facet instance, for example `myapp`. |
| `outDir` | yes | The build folder to upload, relative to the project root. |
| `spa` | no | Whether the deployment serves as a single-page app. Default `true`. |
| `targets` | no | Named Facet instances. Each carries one `url`. |
| `defaultTarget` | no | The target used when no `--target` flag is passed. |

Pick a target with `--target`:

```sh
pnpx @facetapp/cli deploy --target prod --note "release 1.0"
```

Without the flag, the CLI uses `defaultTarget`. With neither, the command fails
and lists the available targets.

## Troubleshooting

The CLI prints one message per failure:

| Message | Cause and next step |
| --- | --- |
| `No facet.config.json in <root>` | No config file. Run `init` or `cd` into the project. |
| `facet.config.json is not valid JSON` | Fix the JSON syntax. |
| `has no "app"/"outDir" value` | Fill the missing field in `facet.config.json`. |
| `Unknown target "x"… Available targets: …` | `--target` or `defaultTarget` names nothing. Use a listed name. |
| `No stored session for <instance>` | Not signed in. Run `login`. |
| `Run "pnpx @facetapp/cli login" to sign in again.` | The session expired or was revoked, and refresh failed. Sign in again. |
| `No app with slug "x" on <instance>` | The config's `app` slug matches no app on the instance. Create it or fix the slug. |
| `The build folder "x" does not exist` | `outDir` points at a missing folder. Check the config. |
| `holds no files to deploy` | The build folder is empty. Build first. |
| `HTTP 422 from /api/app/…/deploy: …` | The server refused the upload. A draft or disabled app is the usual cause; a rejected file path is the other. |
| `Cannot reach <instance>` | Network failure. Check the URL and connectivity. |

**A new app keeps answering `HTTP 422` on deploy.**

A created app is a draft until an operator activates it. Activate the app in
the dashboard, then deploy again. See
[Registering an app](/apps/registering-app/).

**A CI run fails with the re-login hint.**

`FACET_TOKEN` expired. The CLI never refreshes an environment token. Put a
fresh access token in the CI secret.

## Related

- [Deploy your frontend](/apps/hosting-deploy/) — the deploy model behind these commands.
- [Registering an app](/apps/registering-app/) — app status, draft and activate.
- [The TypeScript SDK (`@facetapp/sdk`)](/apps/typescript-sdk/) — call the API from app code.
- The CLI README on GitHub:
  [packages/cli/README.md](https://github.com/wearefacet/facet/blob/main/packages/cli/README.md).
- The backend contract on GitHub:
  [doc/packages/cli.md](https://github.com/wearefacet/facet/blob/main/doc/packages/cli.md).
