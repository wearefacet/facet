# E2E harness — dockerized pre-release gate

The pre-release gate proves the whole product on a real stack: browser, Caddy, backend, PostgreSQL, Redis.

Fast feedback lives elsewhere: Crystal specs (`make test`) and Storybook play functions + the Vitest `server` project under `frontend/`. This suite runs rarely, in minutes, against throwaway stacks.

**Also the quickest "real stack with data" a developer can boot.** The backend entrypoint runs `db_reset seed:dev` plus the CRM, production and iam bundle imports before serving, so one `e2e/run-suite.sh smoke` (or a manual `docker compose -f e2e/compose.yml up` — see `CONTRIBUTING.md` → Running the product in Docker) gives a populated instance: seeded admin `admin@example.tld` / `admin`, the iam fixture accounts, CRM and production doctypes and fixture documents, TLS vhosts through the stack's Caddy. Nothing is published to the host — the origins resolve inside the compose network.

## Principles

1. **One scenario file = one worker = one Docker stack = one database lifetime.** State accumulates inside the file.
2. **No reset between steps.** A failed step aborts the file; remaining steps are skipped.
3. **No retries** (`retries: 0`). No DSL — plain TypeScript with `test.step()` blocks.
4. **Arrange with the API, act through the UI.** The browser drives the surface under test.

## Run

```sh
e2e/run-suite.sh          # every scenario listed in scenarios.txt
./run-suite.sh smoke      # one scenario (stack boot included)
```

The driver loops over the scenario names in `scenarios.txt`. Per scenario it:

1. boots a fresh compose project (`facet-e2e-<scenario>`): PostgreSQL (pgvector) + Redis + backend (`db_reset seed:dev` + CRM + production + iam bundle imports, then `facet server`) + frontend (`vite preview`) + Caddy (TLS :3443),
2. waits for every service healthcheck,
3. runs the scenario's Playwright project inside the runner container (the `setup` dependency project logs in through the real UI first and saves the admin `storageState`),
4. tears the stack down (`compose down -v` — the network is left clean) and writes artifacts to `artifacts/<scenario>/`.

Run one scenario's project against an already-running stack by hand:

```sh
COMPOSE_PROJECT_NAME=facet-e2e-smoke E2E_SCENARIO=smoke \
  docker compose run --rm runner pnpm exec playwright test --project=smoke
```

The host needs `docker` + `docker compose`. Local edits to `tests/` require an image rebuild of the runner (layer-cached; `run-suite.sh` builds automatically).

### Phase timeouts

Every phase runs under a `timeout` guard. A hung build, a stack that never gets healthy, or a wedged runner ends its phase — the scenario fails, and the loop goes on. Defaults, in seconds:

| Env var | Phase | Default |
| --- | --- | --- |
| `E2E_BOOT_TIMEOUT` | stack boot (includes image builds) | 1800 |
| `E2E_BUILD_TIMEOUT` | runner image build | 900 |
| `E2E_TEST_TIMEOUT` | one scenario's Playwright run | 1200 |
| `E2E_DOWN_TIMEOUT` | stack teardown | 120 |

The first boot on a cold cache needs the biggest budget — the backend image holds a release Crystal build (reference point, not a contract: roughly 3–6 minutes for the backend image on a 4-core host, ~20 s stack boot once the images exist; keep `E2E_BOOT_TIMEOUT` at its 1800 s default unless you have measured your host). A timed-out phase reports `exceeded its <n>s budget`.

The guard runs `timeout --foreground`, so the wrapped command stays in the shell's foreground process group: the runner phase can read the terminal, and Ctrl+C stops the whole suite — the EXIT trap then tears the current stack down.

## Layout

| Path | Role |
| --- | --- |
| `scenarios.txt` | Single source of scenario project names — read by `playwright.config.ts` (project binding) and `run-suite.sh` (stack loop) |
| `tests/` | Scenario files (`*.e2e.ts`); `tests/setup/` holds the storageState setup project |
| `compose.yml` | One stack: `postgres`, `redis`, `backend`, `frontend`, `caddy`, `runner` |
| `stack/config.e2e.yml.tmpl` | The `APP_ENV=e2e` config the backend entrypoint renders (fixed key literals — see below) |
| `stack/node-runtime-shims.cjs` | Stack-scoped Node fixes (see below) |
| `docker/*.Dockerfile` | Backend (multi-stage Crystal), frontend (`vite preview`), runner (`mcr…/playwright`) images |
| `docker/backend-entrypoint.sh` | Renders `config.e2e.yml`, runs the baseline chain, execs the server |
| `stack/runner-entrypoint.sh` | Waits for Caddy's root CA, then execs Playwright/CLI |
| `artifacts/` | Traces, videos, HTML report — per scenario (git-ignored) |
| `.auth/` | storageState inside the runner (git-ignored) |

A new scenario file **must** be listed in `scenarios.txt` — the config guard fails the run when a `tests/*.e2e.ts` file matches no project. The guard is symmetric: the runner fails when a listed scenario has no file, so the manifest cannot silently skip a gap.

## Topology facts worth knowing

- **Fixed internal ports.** Nothing is published to the host. Origins are the dev vhosts (`https://facet.localhost:3443`, hosted apps under `*.apps.localhost`) resolved to the stack's Caddy through compose network aliases; browsers additionally get `--host-resolver-rules` because Chromium pins `*.localhost` to loopback, where nothing listens inside the runner.
- **SSR goes through Caddy**: the production build's `event.fetch('/Api/…')` rides Caddy to the backend. Two Node behaviors made this need explicit handling in `stack/node-runtime-shims.cjs`; the file header documents them in full:
  1. Node ≥ 23 hardens hostname verification for RFC 6761 `.localhost` names. The shim relaxes wildcard matching for exactly those names; with the current Caddyfile (exact cert for `facet.localhost`, three-label `*.apps.localhost` for apps) the stock verifier already accepts every stack origin and the shim is a pass-through. Chain-trust stays intact.
  2. `vite preview` builds SSR fetch URLs with its own plain-HTTP protocol (`PROTOCOL_HEADER`/`HOST_HEADER` are adapter-node features). SvelteKit's internal fetch then hit Caddy's TLS port with plaintext and got 400s. The shim upgrades the pinned origin's `http` fetches to `https`.
- **No secret env plumbing.** The grant secret and the secrets master key are fixed literals in `stack/config.e2e.yml.tmpl` — the stacks carry throwaway data, so (like the dev literals in `config.dev.yml`) the keys ship checked in with do-not-use-in-production comments. They differ from the dev values so an e2e key never unlocks dev data.
- **Traces, videos and the HTML report** always land in `artifacts/<scenario>/` — the suite runs rarely, so capture everything; upload from CI on failure.
- **`docker compose run` with a different `-f` set recreates the stack.** The recreation runs without the override's published port. The host loses `:3443` until the next `up`.
- **Restarting the backend container wipes the scenario.** The entrypoint runs `db_reset seed:dev` + the CRM, production and iam imports on **every** start — `docker compose restart backend` resets the database to the baseline and any mid-scenario state is gone. Rebuild the stack instead (`run-suite.sh`), or scope manual restarts to scenarios that tolerate a reset.
- **The login page hydrates slowly.** A naive Playwright submit can silently reload `/Login`. Wait for hydration before you submit.

## OIDC mock issuer recipe

An OIDC scenario needs a mock identity provider (IdP) in the stack. The backend checks the `issuer` URL when you save the provider document: it accepts an absolute `https` URL, or plain `http` on a loopback host only — `localhost`, `127.0.0.1`, `::1`, `*.localhost` (`src/util/redirect_uri.cr`; see [`doc/backend/oidc.md`](../doc/backend/oidc.md)). A `<name>.localhost` name is a loopback name (RFC 6761), so plain `http` stays on the machine.

A bare service name such as `keycloak` fails the check with 422. The refusal is deliberate: the backend fetches the IdP discovery document server-side, and plain `http` to a non-loopback host can let credentials leave the machine. Do not widen the rule. Give the mock a `<name>.localhost` name, and put a network alias on the service so the stack network resolves the name to the mock's container — the pattern Caddy uses for the dev vhosts:

```yaml
  keycloak:
    image: <mock-idp-image>
    networks:
      default:
        aliases:
          - keycloak.localhost
```

Create the provider with issuer `http://keycloak.localhost:8080`. The port is the mock's container port — nothing is published to the host.

## What to read next

- `scenarios.txt` and `tests/` — the scenario manifest and the scenario files themselves.
- [`doc/frontend/workflow.md`](../doc/frontend/workflow.md) → Testing strategy — where this package sits among the test layers.

## Smoke scenario contents

The smoke scenario (`tests/smoke.e2e.ts`) proves the login path and carries the a11y smoke gate (audit 22): an `@axe-core/playwright` scan of the signed-in dashboard that fails on `critical` violations. The documented a11y backlog lives in the frontend Storybook overrides; this gate only catches egregious regressions on a real page.

## Containment scenario contents

The containment scenario (`tests/containment.e2e.ts`) pins the five field-containment guards for a tagged-down caller: the masked GET (`RBAC::ReadEnforcer`), the masked write response (`Responders.write_document_result` → `Document::Presenter`), the redacted mutation history (`Audit::Redact`), the invisible-field write refusal (403 "Write refused: invisible field"), and the role self-escalation refusal (403 "Role authority refused this write"). It authors its own domain and doctype over the API, tags one field `confidential`, and drives every assertion as a non-admin `editor` account — the API only, no UI surface.
