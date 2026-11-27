# @facetapp/cli

Command-line interface for [Facet](https://github.com/wearefacet/facet). It deploys a static build folder as a new revision of a Facet app, lists and activates revisions, and manages sign-in.

No install step is required. Run it through pnpx, pinned to the current release:

```
pnpx @facetapp/cli@0.1.0 <command>
```

Requires Node 20 or newer.

## Quick start

```
npm install -g @facetapp/cli
facet-cli setup-dev
```

`setup-dev` scaffolds a complete dev instance in the current folder — the GHCR stack in dev mode, a generated `.env`, `config.dev.yml`, `facet.config.json`, and a git repo — then starts it, seeds the known dev admin, and fetches your API key. No repository clone and no local toolchain: Docker with Compose is the only prerequisite.

For an app deploy project instead, the manual path is:

```
pnpx @facetapp/cli init
pnpx @facetapp/cli connect
pnpx @facetapp/cli deploy --note "first build"
```

`init` asks for the app slug, the build folder, and the instance URL, then writes `facet.config.json`. Without a terminal, pass the answers as flags or pipe them on stdin (see [init](#init)). `connect` signs in and, on request, stores a project API key. `deploy` uploads the build folder as a new revision and activates it.

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

### setup-dev

```
pnpx @facetapp/cli setup-dev [--dir <path>] [--hostname <name>] [--port <n>]
                             [--watch <dir>|--no-watch] [--no-start] [--no-key]
                             [--force] [--yes]
```

Takes an empty folder to a running dev instance:

1. Checks Docker with Compose.
2. Asks the hostname (default `facet.localhost`), the HTTPS port (default `3443`), and whether to watch a folder for domain bundles (default yes, folder `domains`). `--yes` takes every default without prompting.
3. Writes `compose.yml`, `config.dev.yml`, `.env` (generated secrets, mode 600), `Caddyfile.prod`, `facet.config.json`, `.gitignore`, and the `domains/` folder when watching. Runs `git init` when the folder is not already in a repository.
4. Starts the stack (`docker compose up -d --wait`) and seeds the known dev admin (`db_reset --yes seed:dev`).
5. Prints the URL and the credential `admin@example.tld` / `admin`, then fetches an API key through the `connect` flow.

The generated `facet.config.json` targets the fresh instance (`defaultTarget: dev`), so `connect`, `apikey`, and `whoami` work at once. It carries no `app` — this sets up the Facet environment, not an app deploy; add an app slug with `init` or by hand when you deploy a build.

`--no-start` writes the files only. `--no-key` skips the API key. `--force` overwrites an existing stack in the folder. `--dir` picks the folder (default: current directory).

The dev credential is for throwaway local data only — the platform refuses `seed:dev` in production.

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

### connect

```
pnpx @facetapp/cli connect [--target <name>]
```

Signs in through the browser (the same OAuth flow as `login`), then asks `Store an API key for this project?`. Answer `y` and the CLI issues a **user-owned API key** pinned to your account and your active role, and writes it to `.facet.local.json` in the project folder (mode 600, gitignored). Answer anything else and no key is stored.

A key is refused when the role is not assigned to you or its `connectivity` excludes the `api` channel; the command prints the server's message and exits failing. Each project keeps its own key, so several Facet setups can live side by side.

### apikey

```
pnpx @facetapp/cli apikey [--target <name>]
```

Prints the stored API key for the resolved target on stdout — nothing else — so a shell can inline it:

```sh
curl -H "Authorization: Bearer $(pnpx @facetapp/cli apikey)" https://facet.example.tld/Api/hr/Employee
```

Fails (non-zero exit) when no key is stored or the stored key has expired. Run `connect` again to issue a fresh one.

### login

```
pnpx @facetapp/cli login [--target <name>]
```

Runs the browser sign-in round-trip against the configured target, without offering an API key. Without a config file the command asks for the instance URL.

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
| `Docker with Compose is required`                  | `setup-dev` needs Docker. Install it and retry.                                                  |
| `already holds a dev stack`                        | `setup-dev` found stack files in the folder. Re-run with `--force` or pick another `--dir`.      |
| `No API key stored for <instance>`                 | `apikey` found no key in `.facet.local.json`. Run `connect` and choose to store one.             |
| `The stored API key … expired`                     | The key's `expires_at` passed. Run `connect` again to issue a fresh one.                         |
| `The build folder "x" does not exist`              | `outDir` points at a missing folder. Check the config.                                           |
| `holds no files to deploy`                         | The build folder is empty. Build first.                                                          |
| `HTTP 422 from /Api/app/…/deploy: …`               | The server refused the upload — usually a draft/disabled app or a rejected file path.            |
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
