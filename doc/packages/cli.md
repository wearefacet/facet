# CLI — `@facetapp/cli`

The command-line interface for app developers: it deploys a static build folder as a new revision of a `app.App` document, lists and activates revisions, and manages sign-in against a Facet instance's OAuth authorization server. It is a standalone npm package, separate from the SvelteKit frontend and the Crystal backend.

Publishing the package to npm is a separate concern: see [`release.md`](release.md).

## Source files

All paths are relative to `packages/cli/`:

| File | Role |
| ---- | ---- |
| `src/index.ts` | Commander program: the seven commands, one error boundary per action |
| `src/commands/context.ts` | Config + target resolution into a `CommandContext`; readline prompts |
| `src/commands/init.ts` | `facet.config.json` writer; flag, piped-stdin, and interactive answers; app lookup + create offer |
| `src/commands/login.ts` | Command wrapper around the OAuth flow in `src/login.ts` |
| `src/commands/logout.ts` | Stored-session removal |
| `src/commands/whoami.ts` | Session profile + active revision readout |
| `src/commands/deploy.ts` | Build-folder walk, multipart upload, revision printout |
| `src/commands/releases.ts` | Deployment list with the active marker |
| `src/commands/rollback.ts` | `active_deployment` PATCH by revision |
| `src/api.ts` | `fetch` wrapper, error mapping, 401 refresh-and-retry, typed API surface |
| `src/auth.ts` | `~/.config/facet/auth.json` storage, `FACET_TOKEN` precedence, refresh |
| `src/config.ts` | `facet.config.json` load + validate + target resolution |
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
| Slug → app id | `GET /Api/app/App?filters[slug__eq]=…` |
| App read / create / rollback | `GET/POST /Api/app/App`, `PATCH /Api/app/App/:id` |
| Deployment list | `GET /Api/app/Deployment?filters[app_id__eq]=…&sort=-revision` |
| Deploy | `POST /Api/app/:id/deploy` (multipart; `$content` part + `files[<i>].file` parts; `activate` read from `$content`) |

The deploy route answers `{id, revision, activated, files}` — not a document envelope. Reference filters carry the qualified form (`app.App.<id>`), and `active_deployment` is set to a qualified `app.Deployment.<id>` token.

## Testing

Vitest, `pnpm test` inside `packages/cli`. The module tests (`test/*.test.ts`) cover pure logic and HTTP mocks; the command tests (`test/commands/*.test.ts`) mock the `api`/`auth`/`login` modules and assert printed output; `test/program.test.ts` wires commander actions through the real argument parsing, including the exit-code error boundary.
