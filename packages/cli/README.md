# @facetapp/cli

Command-line interface for [Facet](https://github.com/wearefacet/facet). It deploys a static build folder as a new revision of a Facet app, lists and activates revisions, and manages sign-in.

No install step is required. Run it through pnpx, pinned to the current release:

```
pnpx @facetapp/cli@0.0.3 <command>
```

Requires Node 20 or newer.

## Quick start

```
pnpx @facetapp/cli init
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

`init` asks for the app slug, the build folder, and the instance URL, then writes `facet.config.json`. Without a terminal, pass the answers as flags or pipe them on stdin (see [init](#init)). `login` opens a browser for the consent screen. `deploy` uploads the build folder as a new revision and activates it.

## Configuration — `facet.config.json`

`init` writes this file at the project root. The CLI reads it from the working directory.

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

| Field           | Required | Meaning                                                             |
| --------------- | -------- | ------------------------------------------------------------------- |
| `app`           | yes      | The app slug on the Facet instance, for example `myapp`.            |
| `outDir`        | yes      | The build folder to upload, relative to the project root.           |
| `spa`           | no       | Whether the deployment serves as a single-page app. Default `true`. |
| `targets`       | no       | Named Facet instances. Each carries one `url`.                      |
| `defaultTarget` | no       | The target used when no `--target` flag is passed.                  |

Pick a target with `--target <name>`. Without the flag the CLI uses `defaultTarget`; with neither, the command fails and lists the available targets.

## Sign-in model

`login` runs the OAuth authorization-code flow with PKCE (S256): the CLI resolves its own client registration through `GET /OAuth/client-info`, starts a one-shot loopback server, opens the browser at the consent screen, and exchanges the code at the token endpoint. The session lands in `~/.config/facet/auth.json` (mode 600; `$XDG_CONFIG_HOME` is respected), one entry per instance URL.

Access tokens are short-lived. The CLI refreshes a stored session only when it is near expiry or after a 401 — never eagerly, because the server enforces a refresh floor. Rotated refresh tokens are stored back at once.

For CI and automation, skip the browser flow and set `FACET_TOKEN` to an access token. The environment token wins over any stored session and is never refreshed — when it expires, the run fails with a re-login hint.

## Commands

### init

```
pnpx @facetapp/cli init [--yes] [--app <slug>] [--build <dir>] [--server <url>]
```

Writes `facet.config.json`. Offline safe: with no stored session for the instance, the config is written and the command stops. With a stored session, the app is read by slug; when it does not exist yet, the CLI offers to create it (needs `write` on `app.App`). A created app is a draft — activate it in the dashboard before the first deploy.

Without a terminal, pass the answers as flags, or pipe them on stdin as three lines (app slug, build folder, instance URL):

```
printf 'myapp\ndist\nhttps://facet.example.tld\n' | pnpx @facetapp/cli init
```

`--build` defaults to `dist`. When `--server` is omitted, no target is written and the app check is skipped. `--yes` makes the run non-interactive: it skips the answer prompts and creates a missing app without asking.

### login

```
pnpx @facetapp/cli login [--target <name>]
```

Runs the browser sign-in round-trip against the configured target. Without a config file the command asks for the instance URL.

### logout

```
pnpx @facetapp/cli logout [--target <name>]
```

Removes the stored session for the instance. Idempotent.

### whoami

```
pnpx @facetapp/cli whoami [--target <name>]
```

Prints the instance, the account behind the stored token, the active role, and the app's active revision.

### deploy

```
pnpx @facetapp/cli deploy [--target <name>] [--note <text>] [--no-activate]
```

Loads the config, walks `outDir` (skipping `node_modules`, `.git`, and `.DS_Store`), resolves the app slug to its id, and uploads one multipart request. The new revision is activated by default; `--no-activate` uploads it dormant. Prints the assigned revision and the app URL — its scheme and port follow the instance URL.

### releases

```
pnpx @facetapp/cli releases [--target <name>]
```

Lists the app's deployments, newest revision first. The active one carries a `*`.

### rollback

```
pnpx @facetapp/cli rollback <revision> [--target <name>]
```

Points the app's `active_deployment` at the deployment with the given revision. Unknown revision numbers fail with the list of known ones.

## Error messages

| Message                                            | Cause and next step                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `No facet.config.json in <root>`                   | No config file. Run `init` or `cd` into the project.                                             |
| `facet.config.json is not valid JSON`              | Fix the JSON syntax.                                                                             |
| `has no "app"/"outDir" value`                      | Fill the missing field in `facet.config.json`.                                                   |
| `Unknown target "x"… Available targets: …`         | `--target` or `defaultTarget` names nothing. Use a listed name.                                  |
| `No stored session for <instance>`                 | Not signed in. Run `login`.                                                                      |
| `Run "pnpx @facetapp/cli login" to sign in again.` | The session expired or was revoked, and refresh failed. Sign in again.                           |
| `No app with slug "x" on <instance>`               | The config's `app` slug matches no app on the instance. Create it or fix the slug.               |
| `init needs answers` / `init needs an app slug`    | No terminal, no flags, and no piped stdin. Pass `--app`, pipe the answers, or run in a terminal. |
| `The build folder "x" does not exist`              | `outDir` points at a missing folder. Check the config.                                           |
| `holds no files to deploy`                         | The build folder is empty. Build first.                                                          |
| `HTTP 422 from /Api/app/…/deploy: …`              | The server refused the upload — usually a draft/disabled app or a rejected file path.            |
| `Cannot reach <instance>`                          | Network failure. Check the URL and connectivity.                                                 |

## Development

**pnpm only.** This package ships a `pnpm-lock.yaml` and no `package-lock.json` — do not run `npm install` / `npm run build` here; npm cannot read the lockfile and the result is not supported. Use pnpm (`pnpm install`, then):

```
pnpm check   # type-check
pnpm test    # vitest
pnpm build   # emit dist/
pnpm start   # rebuild, then run dist/index.js — a stale dist/ cannot run
pnpm dev     # the same rebuild-then-run entry for a checkout session
```

`pnpm start` / `pnpm dev` rebuild before every run, so a checkout's
`dist/` can never go stale against `src/` (B-334). Every distribution
channel (git, Docker, npm) already rebuilds fresh; these scripts cover
the local prebuilt case.
