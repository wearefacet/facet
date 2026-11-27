# CLI — `@facetapp/cli`

The command-line interface for app developers: it deploys a static build folder as a new revision of a `app.App` document, lists and activates revisions, and manages sign-in against a Facet instance's OAuth authorization server. It is a standalone npm package, separate from the SvelteKit frontend and the Crystal backend.

Publishing the package to npm is a separate concern: see [`release.md`](release.md).

## Source files

All paths are relative to `packages/cli/`:

| File | Role |
| ---- | ---- |
| `src/index.ts` | Commander program: the ten commands, one error boundary per action |
| `src/commands/context.ts` | Config + target resolution into a `CommandContext`; readline prompts |
| `src/commands/init.ts` | `facet.config.json` writer; flag, piped-stdin, and interactive answers; app lookup + create offer |
| `src/commands/setup-dev.ts` | `setup-dev`: scaffold the GHCR dev stack, start it, seed the dev admin, fetch an API key |
| `src/commands/connect.ts` | `connect`: sign in, then optionally issue and store a project API key (pinned to the active role, or `--role`) |
| `src/commands/apikey.ts` | `apikey`: print the stored project API key for shell substitution |
| `src/commands/host.ts` | `host`: print the resolved target's instance URL for shell substitution |
| `src/commands/login.ts` | Command wrapper around the OAuth flow in `src/login.ts` |
| `src/commands/logout.ts` | Stored-session removal |
| `src/commands/whoami.ts` | Session profile + active revision readout |
| `src/commands/deploy.ts` | Build-folder walk, multipart upload, revision printout |
| `src/commands/releases.ts` | Deployment list with the active marker |
| `src/commands/rollback.ts` | `active_deployment` PATCH by revision |
| `src/api.ts` | `fetch` wrapper, error mapping, 401 refresh-and-retry, typed API surface |
| `src/auth.ts` | `~/.config/facet/auth.json` storage, `FACET_TOKEN` precedence, refresh |
| `src/keyfile.ts` | `.facet.local.json` storage — per-folder user API keys, mode 600 |
| `src/config.ts` | `facet.config.json` load + validate + target resolution |
| `src/devcompose.ts` | Pure builders for the `setup-dev` stack files (compose, `.env`, `config.dev.yml`, Caddyfile, facet config, gitignore) |
| `src/deploy.ts` | Build-folder walk + multipart body builder |
| `src/login.ts` | PKCE flow: client-info, loopback callback server, token exchange |

User-facing documentation lives in [`packages/cli/README.md`](../../packages/cli/README.md) — it ships in the npm tarball. This doc covers the module layout and the contracts behind it.

## Layering

```
commands ──> api.ts ──> auth.ts      (token resolution + refresh)
    │            │
    │            └──> fetch (one request; 401 → refresh → retry once)
    ├──> deploy.ts (walk + multipart)
    └──> login.ts  (OAuth + PKCE + loopback server)
```

- `config.ts` and `deploy.ts` are pure logic with no network access; they carry the strictest tests.
- `auth.ts` owns the session file. Every command resolves its bearer token through `currentToken`: `FACET_TOKEN` first, then the stored session, refreshed only near expiry (the server enforces a refresh floor — eager refresh is a `slow_down` rejection).
- `api.ts` wraps one `fetch` per request, maps error bodies into `ApiError` (`error` name + joined `details[].message`), and retries once through `refreshSession` on a 401. A 401 after a failed refresh raises `AuthError` with the re-login hint.
- `login.ts` resolves the CLI's own registration through `GET /OAuth/client-info?slug=facet-cli` (public route on the backend), then runs authorization code + PKCE S256 against a one-shot loopback server on an ephemeral `127.0.0.1` port. Sessions are keyed by instance URL.

## Dev environment (`setup-dev`)

`setup-dev` takes an empty folder to a running dev instance without a repository clone. It writes the image-only stack in dev mode, starts it, seeds the known dev admin, and fetches the user's API key. The Facet environment is the target — no app deploy is set up, so the generated `facet.config.json` carries `targets` only.

The generated files:

| File | Content |
| ---- | ------- |
| `compose.yml` | GHCR images, `APP_ENV=dev`, `FACET_CONFIG_FILE=/app/config.dev.yml`, the dev config mounted |
| `config.dev.yml` | Only the loader-required sections plus dev values: `mail.adapter: dev`, `iam.secure_cookies: false`, `event.url` at the `redis` service, artifact store at `/data/store` |
| `.env` | Generated `POSTGRES_PASSWORD` and `JWT_SIGNING_KEY` (P-256 PEM), mode 600 |
| `Caddyfile.prod` | The edge config |
| `facet.config.json` | `targets: { dev: { url } }`, `defaultTarget: dev` |
| `.gitignore` | `.env`, `.facet.local.json`, `domains/`, build and OS ignores |
| `domains/` | The watch folder (opt-in, default on) |

The backend must boot as `APP_ENV=dev` because `facet seed:dev` refuses production (`src/iam/seed.cr`), and the known credential needs the dev seed. The mounted `config.dev.yml` sidesteps the shipped production example the entrypoint would otherwise render (`FACET_CONFIG_FILE` wins in `Config.resolve_config_path`). The template is self-contained (not a copy of the repo `config.dev.yml`), so it does not drift with the backend config schema; only the loader-required keys are emitted.

Steps: pre-flight `docker compose version`, prompt hostname/port/watch folder (skipped with `--yes`), write the files, `git init` when the folder is not already in a repo, `docker compose up -d --wait`, `docker compose run --rm backend db_reset --yes seed:dev`, then the `connect` flow. `--no-start` writes only; `--no-key` skips the key; `--force` overwrites an existing stack.

## Connect and API keys

`connect` runs the same OAuth flow as `login`, then offers to issue a **user-owned API key**. The key is created through `POST /Api/iam/keys` with `{name, role}` — the key is pinned to the signed-in account and that role, exactly like the self-service key route documented for operators. `--role` names the role (a bare name is qualified to `iam.Roles.<name>`); without it the role is the caller's `active_role` read from `GET /Api/iam/me`. No app-owned key is involved: the seeded `facet-cli` app is a public client and `App::ApiKeys.issue` refuses it (`422 App is not a backend app`), so `connect` never asks an app to mint a key for itself.

The instance refuses the key with `422` when the role is not assigned to the account or its `connectivity` excludes the `api` channel. The command prints the server's message and exits failing; no key is stored.

Stored keys live in `.facet.local.json` at the project root, next to `facet.config.json` — **per folder, not global**, so several Facet setups can sit side by side. The file is gitignored and written mode 600. Shape:

```json
{ "apiKeys": { "https://facet.example.tld": { "key": "fct_…", "id": "…", "display_prefix": "fct_…", "role": "iam.Roles.editor" } } }
```

`apikey` prints the raw token for the resolved target on stdout and nothing else, so a shell can inline it: `curl -H "Authorization: Bearer $(facet-cli apikey)" …`. It fails (stderr, non-zero exit) when no key is stored or the stored key's `expires_at` has passed.

`host` prints the resolved target's instance URL the same way — no trailing slash — so a request URL stays in one piece: `curl "$(facet-cli host)/Api/core/Domain/equipment" …`. It reads `facet.config.json` only and never contacts the instance; an unknown target raises `ConfigError`.

## Non-interactive init

`facet init` resolves its three answers in this order:

1. Flags: `--app <slug>`, `--build <dir>`, `--server <url>`. Any answer flag makes the run flag-driven: `--build` defaults to `dist`, and an omitted `--server` writes no target and skips the app check.
2. Piped stdin, when stdin is not a terminal and no answer flag is set: three lines, app slug, build folder, instance URL.
3. Interactive prompts, when stdin is a terminal.

`--yes` makes the run non-interactive: it skips the answer prompts and the "create app?" confirmation, and creates a missing app at once. Without `--yes`, a non-interactive run reports the missing app and leaves it uncreated. With no flags and no stdin answers the command throws `ConfigError`.

## Backend contract

| Call | Backend surface |
| ---- | ---- |
| Client registration lookup | `GET /OAuth/client-info?slug=…` (`OAuth::ClientInfo`, public route) |
| Token exchange + refresh | `POST /OAuth/token` (`grant_type: authorization_code` / `refresh_token`) |
| Session validation | `GET /Api/iam/me` |
| API key issue | `POST /Api/iam/keys` (`{name, role}`; raw token returned once) |
| Slug → app id | `GET /Api/app/App?filters[slug__eq]=…` |
| App read / create / rollback | `GET/POST /Api/app/App`, `PATCH /Api/app/App/:id` |
| Deployment list | `GET /Api/app/Deployment?filters[app_id__eq]=…&sort=-revision` |
| Deploy | `POST /Api/app/:id/deploy` (multipart; `$content` part + `files[<i>].file` parts; `activate` read from `$content`) |

The deploy route answers `{id, revision, activated, files}` — not a document envelope. Reference filters carry the qualified form (`app.App.<id>`), and `active_deployment` is set to a qualified `app.Deployment.<id>` token.

## Testing

Vitest, `pnpm test` inside `packages/cli`. The module tests (`test/*.test.ts`) cover pure logic and HTTP mocks; the command tests (`test/commands/*.test.ts`) mock the `api`/`auth`/`login` modules and assert printed output; `test/program.test.ts` wires commander actions through the real argument parsing, including the exit-code error boundary. `test/keyfile.test.ts` covers the `.facet.local.json` store (round-trip, mode 600, per-instance keys, malformed input).
