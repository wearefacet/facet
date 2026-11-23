# Contributing to Facet

Facet is a document store with event sourcing for mid-sized organizations. Documents live by **domain** and **doctype** in PostgreSQL; every mutation appends to an event log. This page gives a new contributor a working environment, the commands, and a map from each subsystem to its concern document.

## License and the CLA

Facet is source-available software, licensed under the Business Source License 1.1 — see [`LICENSE`](LICENSE) and [`LICENSING.md`](LICENSING.md). Every source file carries an `SPDX-License-Identifier: BUSL-1.1` header; `scripts/check-license-headers.sh` enforces it, and CI runs the same check.

Contributions are licensed to Amplitude Solutions Ltd through the Contributor License Agreement in [`CLA.md`](CLA.md). The CLA Assistant app asks you to sign on your first pull request; a pull request without a signed CLA cannot be merged.

## Development environment

| Tool                    | Notes                                                                        |
| ----------------------- | ---------------------------------------------------------------------------- |
| Crystal 1.21            | The toolchain in use. The `agent-cr` shard needs Crystal >= 1.19.            |
| PostgreSQL 14+          | One instance for the app. The `ulid()` function needs PG 14+.                |
| Redis                   | Required. The event bus, sessions, OAuth codes, and rate limits use it.      |
| Docker + Docker Compose | The spec-suite database (`compose.test.yml`), the E2E suite, and the Docker-only way to run the product (see below). |
| Node.js >= 20 + pnpm   | Frontend, CLI package, E2E runner. **pnpm only** — the lockfiles are `pnpm-lock.yaml`; npm is not supported (no `package-lock.json`). |
| Caddy                   | The dev proxy. `scripts/dev` expects it on PATH. Hosted apps need one `/etc/hosts` line (`127.0.0.1 facet.localhost app.apps.localhost`); Chromium resolves `*.localhost` by itself. |
| Lua 5.4 or 5.5 headers  | The `lua` shard links the system library (`liblua5.4-dev` on Debian/Ubuntu). |

Configuration lives in `config.dev.yml` (backend) and the root `.env` (shared addresses, notably `BACKEND_URL`). The dotenv files are git-ignored — copy `.env.example` to create one.

## Daily commands

Full dev stack — migrate + Caddy + backend + frontend, one terminal:

```sh
./scripts/dev             # start all
./scripts/dev --no-caddy  # raw two-port mode (backend :3000, frontend :5173)
```

Backend (repository root):

| Command                             | Purpose                                                              |
| ----------------------------------- | -------------------------------------------------------------------- |
| `make test`                         | Full spec suite. Starts the throwaway PostgreSQL on port 5433 first. |
| `make check`                        | Compile gate, no binary. Fastest signal on type errors.              |
| `make build` / `make build_release` | Server binary into `build/`.                                         |
| `make run`                          | Backend only.                                                        |
| `bin/ameba`                         | Crystal linter. Run before and after tests.                          |

Frontend (in `frontend/`):

| Command          | Purpose                                                                                   |
| ---------------- | ----------------------------------------------------------------------------------------- |
| `pnpm check`     | `svelte-check` — types, Svelte syntax, accessibility.                                     |
| `pnpm lint`      | Prettier + ESLint.                                                                        |
| `pnpm test`      | Vitest: the `server` project (pure logic) + the Storybook project (story play functions). |
| `pnpm storybook` | Component workbench. Stories double as component tests.                                   |

CLI package (in `packages/cli/`): `pnpm build`, `pnpm check`, `pnpm test`.

E2E gate: `e2e/run-suite.sh` — one Dockerized throwaway stack per scenario (`e2e/run-suite.sh smoke` runs one).

### Running the product in Docker (no local toolchain)

You can run a full Facet stack without installing Crystal, Node, or PostgreSQL — Docker Compose is enough:

- **Build the images**: `make docker_images` (wraps `docker build -f docker/backend.Dockerfile` + `frontend.Dockerfile`). The backend image holds a whole-program Crystal `--release` compile — budget **3–6 minutes cold** on a 4-core host; a warm rebuild (shard layers cached) stays under a minute.
- **Run the production-shaped stack with its checks**: `make docker_smoke` (`docker/smoke.sh` over `docker/compose.smoke.yml`).
- **Run the seeded e2e stack as a dev instance**: the e2e compose stack (`e2e/compose.yml`) boots PostgreSQL + Redis + backend + frontend + Caddy, and its backend entrypoint runs `db_reset seed:dev` plus the CRM, production and iam bundle imports before serving — a populated instance in one boot. `e2e/run-suite.sh smoke` uses it for a full scenario; to keep one up for exploration, start it by hand:

  ```sh
  COMPOSE_PROJECT_NAME=facet-e2e-dev docker compose -f e2e/compose.yml up --build
  ```

  The stack publishes **no ports** — its origins are TLS vhosts (`https://facet.localhost:3443`, hosted apps under `*.apps.localhost`) served by the stack's Caddy inside the compose network. Reach it from inside that network (for example `docker compose exec backend curl -k https://caddy/…`), or add a published port for the Caddy service in a local compose override file (`docker compose -f e2e/compose.yml -f my-override.yml up`). The stack's data is throwaway; its config keys are fixed dev/e2e literals.

### Seeded accounts (dev and e2e)

The dev and e2e seeds create an administrator with `admin@example.tld` / `admin` (see `src/iam/seed.cr` — throwaway data only; never a production credential). For a real first deployment, use `facet seed:admin`, which prints a generated one-time password — see [`doc/ops/first-deployment.md`](doc/ops/first-deployment.md).

## Continuous integration

GitHub Actions runs the quality gates. Two workflows live in `.github/workflows/`.

**CI** (`ci.yml`) has two tiers. The fast tier runs on every PR push (drafts included) and on every push to `master`: license headers, format check, ameba, type check, frontend lint and check, the vitest `server` project, and the CLI suite. The full tier runs when a PR is marked ready for review, and on every push to `master`: the Crystal spec suite on the `compose.test.yml` stack (same tuned throwaway PostgreSQL as local) plus a Redis service, and the vitest `storybook` project in Chromium. A new PR push cancels the run it replaces. Runs on `master` always finish.

**E2E** (`e2e.yml`) runs weekly, Sundays at 03:00 UTC, and on manual dispatch. It runs the full `e2e/run-suite.sh`.

Doc-only changes (`**/*.md`, `doc/**`) skip CI. Changes to the workflow files always trigger a run.

| Gate                      | CI job          | Local command                                               |
| ------------------------- | --------------- | ----------------------------------------------------------- |
| SPDX license headers      | `backend-fast`  | `make license_check`                                        |
| Crystal format            | `backend-fast`  | `crystal tool format --check src spec scripts`              |
| Crystal lint              | `backend-fast`  | `bin/ameba`                                                 |
| Crystal type check        | `backend-fast`  | `make check`                                                |
| Crystal spec suite        | `backend-full`  | `make test`                                                 |
| Frontend lint + check     | `frontend-fast` | `pnpm lint`, `pnpm check` (in `frontend/`)                  |
| Frontend logic tests      | `frontend-fast` | `pnpm exec vitest run --project server` (in `frontend/`)    |
| Storybook component tests | `frontend-full` | `pnpm exec vitest run --project storybook` (in `frontend/`) |
| CLI gates                 | `cli`           | `pnpm lint`, `pnpm check`, `pnpm test` (in `packages/cli/`) |
| E2E suite                 | weekly + manual | `e2e/run-suite.sh`                                          |

### Run CI locally

[`act`](https://github.com/nektos/act) runs the workflows in Docker on your machine. Use it to reproduce a failing run without pushing. Run a whole job:

```sh
act workflow_dispatch -j backend-fast     # or frontend-fast, cli, openapi-drift
act workflow_dispatch -j frontend-full
```

The repository `.actrc` maps `ubuntu-latest` to `catthehacker/ubuntu:act-latest` (pull it once: `docker pull catthehacker/ubuntu:act-latest`). One setting must live in your **user** config because a project `.actrc` may not set secrets:

```sh
printf '%s\n' '-s GITHUB_TOKEN=' >> ~/.actrc
```

That empty token forces an anonymous action clone. `act` otherwise reuses a GitHub token from the environment or the `gh` keyring; a stale or invalid one makes its go-git action fetch fail with `authentication required: Invalid username or token`, and every action clone (`actions/checkout`, `crystal-lang/install-crystal`, ...) dies. Use `act` 0.2.86 or newer — older versions carry known CVEs.

`backend-full` runs the full Crystal suite (`make test`) and needs the `compose.test.yml` stack; it is the same command the workflow runs, so prefer `make test` directly unless you need the job's exact step order.

## The main loop

Every change follows the loop in [`AGENTS.md`](AGENTS.md): design first, read the concern docs, confirm the plan, implement, run the linter, run the tests, keep the suite green. Nothing is done while a spec fails.

## Documentation map

[`doc/project-structure.md`](doc/project-structure.md) is the exhaustive index. The map below is the reading path by product area. Start at the doc in the right column, then follow its links.

### Core data platform

| Subsystem                                    | Concern doc                                                          |
| -------------------------------------------- | -------------------------------------------------------------------- |
| Documents, doctypes, field types, validation | [`doc/backend/doctype-system.md`](doc/backend/doctype-system.md)     |
| Create, copy, and named actions on documents | [`doc/backend/document.md`](doc/backend/document.md)                 |
| Mutation log, projections, triggers          | [`doc/backend/mutation.md`](doc/backend/mutation.md)                 |
| Lazy schema migration of old documents       | [`doc/backend/schema-migration.md`](doc/backend/schema-migration.md) |
| HTTP routes, list parsing                    | [`doc/backend/http-layer.md`](doc/backend/http-layer.md)             |
| Filters                                      | [`doc/backend/filter-set.md`](doc/backend/filter-set.md)             |
| Indexes on projections                       | [`doc/backend/index-management.md`](doc/backend/index-management.md) |
| Saved views (table / kanban / grid)          | [`doc/backend/collection-view.md`](doc/backend/collection-view.md)   |
| History, rollback, restore                   | [`doc/backend/audit.md`](doc/backend/audit.md)                       |
| Back-references between documents            | [`doc/backend/links.md`](doc/backend/links.md)                       |
| `display_name` and search templating         | [`doc/backend/templating.md`](doc/backend/templating.md)             |
| Money and currencies                         | [`doc/backend/util-money.md`](doc/backend/util-money.md)             |

### Identity and access

| Subsystem                                           | Concern doc                                          |
| --------------------------------------------------- | ---------------------------------------------------- |
| Accounts, credentials, MFA, sessions, JWT, API keys | [`doc/backend/iam.md`](doc/backend/iam.md)           |
| Roles, scopes, enforcement                          | [`doc/backend/rbac.md`](doc/backend/rbac.md)         |
| Account settings                                    | [`doc/backend/settings.md`](doc/backend/settings.md) |
| Secret store                                        | [`doc/backend/secrets.md`](doc/backend/secrets.md)   |
| OIDC federated login                                | [`doc/backend/oidc.md`](doc/backend/oidc.md)         |

### Automation and integration

| Subsystem                                | Concern doc                                                                                                                                                                                                    |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Event bus (Redis Streams)                | [`doc/backend/event.md`](doc/backend/event.md)                                                                                                                                                                 |
| Background jobs (PostgreSQL queue)       | [`doc/backend/jobs.md`](doc/backend/jobs.md)                                                                                                                                                                   |
| Cron                                     | [`doc/backend/cron.md`](doc/backend/cron.md)                                                                                                                                                                   |
| Domain hooks (Lua)                       | [`doc/backend/hooks.md`](doc/backend/hooks.md)                                                                                                                                                                 |
| Webhooks                                 | [`doc/backend/webhook.md`](doc/backend/webhook.md)                                                                                                                                                             |
| Notifications                            | [`doc/backend/notifications.md`](doc/backend/notifications.md)                                                                                                                                                 |
| WebSocket bridge                         | [`doc/backend/websocket.md`](doc/backend/websocket.md)                                                                                                                                                         |
| Cross-domain field replication           | [`doc/backend/replication.md`](doc/backend/replication.md)                                                                                                                                                     |
| Sidecar doctypes                         | [`doc/backend/sidecar.md`](doc/backend/sidecar.md)                                                                                                                                                             |
| Document import / export                 | [`doc/backend/import-export.md`](doc/backend/import-export.md)                                                                                                                                                 |
| Lua engine                               | [`doc/backend/lua-engine.md`](doc/backend/lua-engine.md)                                                                                                                                                       |
| Portable, draft, and dev-watched domains | [`doc/backend/portable-domains.md`](doc/backend/portable-domains.md), [`doc/backend/draft-domains.md`](doc/backend/draft-domains.md), [`doc/backend/dev-domain-watcher.md`](doc/backend/dev-domain-watcher.md) |

### App platform

| Subsystem                                                     | Concern doc                                              |
| ------------------------------------------------------------- | -------------------------------------------------------- |
| Registered apps, grants, service accounts, deployment serving | [`doc/backend/app-system.md`](doc/backend/app-system.md) |
| OAuth 2.1 authorization server                                | [`doc/backend/oauth.md`](doc/backend/oauth.md)           |
| Artifact store with signed grants                             | [`doc/backend/artifact.md`](doc/backend/artifact.md)     |
| CLI for app developers                                        | [`doc/packages/cli.md`](doc/packages/cli.md)             |

### Assistants and MCP

| Subsystem                                         | Concern doc                                                                                                                            |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Domain-builder assistant                          | [`doc/backend/assistant.md`](doc/backend/assistant.md), [`doc/backend/domain-builder-skills.md`](doc/backend/domain-builder-skills.md) |
| Workspace assistant                               | [`doc/backend/workspace-assistant.md`](doc/backend/workspace-assistant.md)                                                             |
| Conversation storage, SSE streaming, usage ledger | [`doc/backend/agent-conversations.md`](doc/backend/agent-conversations.md)                                                             |
| Shared tool catalogue                             | [`doc/backend/agent-tools.md`](doc/backend/agent-tools.md)                                                                             |
| MCP resource server                               | [`doc/backend/mcp.md`](doc/backend/mcp.md)                                                                                             |
| Chat UI                                           | [`doc/frontend/chat.md`](doc/frontend/chat.md)                                                                                         |

### Platform and operations

| Subsystem                  | Concern doc                                                    |
| -------------------------- | -------------------------------------------------------------- |
| Entrypoint and subcommands | [`doc/backend/cli.md`](doc/backend/cli.md)                     |
| YAML config                | [`doc/backend/config.md`](doc/backend/config.md)               |
| Logging                    | [`doc/backend/logging.md`](doc/backend/logging.md)             |
| Metrics                    | [`doc/backend/metrics.md`](doc/backend/metrics.md)             |
| OpenTelemetry              | [`doc/backend/telemetry.md`](doc/backend/telemetry.md)         |
| SQL migrations             | [`doc/backend/migrations.md`](doc/backend/migrations.md)       |
| Graceful shutdown          | [`doc/backend/shutdown.md`](doc/backend/shutdown.md)           |
| Test database              | [`doc/backend/test-database.md`](doc/backend/test-database.md) |
| Spec layout                | [`doc/backend/specs.md`](doc/backend/specs.md)                 |

### Frontend

Start at [`doc/frontend/workflow.md`](doc/frontend/workflow.md), then [`doc/frontend/bits-ui.md`](doc/frontend/bits-ui.md) for component rules. Feature docs: [`sidecar-panel`](doc/frontend/sidecar-panel.md), [`schematic`](doc/frontend/schematic.md), [`notifications`](doc/frontend/notifications.md), [`markdown-editor`](doc/frontend/markdown-editor.md), [`settings`](doc/frontend/settings.md), [`audit`](doc/frontend/audit.md), [`calendar`](doc/frontend/calendar.md), [`filter-bar`](doc/frontend/filter-bar.md), [`datetime-picker`](doc/frontend/datetime-picker.md), [`access-assignments`](doc/frontend/access-assignments.md), [`access-accounts`](doc/frontend/access-accounts.md), [`app-configure`](doc/frontend/app-configure.md), [`configure-editors`](doc/frontend/configure-editors.md).

### Cross-stack

| Subsystem       | Concern doc                                        |
| --------------- | -------------------------------------------------- |
| Shared fixtures | [`doc/shared/fixtures.md`](doc/shared/fixtures.md) |
| E2E harness     | [`e2e/README.md`](e2e/README.md)                   |

When you add a subsystem: write its concern doc under `doc/`, then add it to [`doc/project-structure.md`](doc/project-structure.md) and to this map.

## Author-maintained shards

One dependency lives under this project's author's account and is pinned to a commit SHA in [`shard.yml`](shard.yml); the comment above the pin holds the rationale. The `lua` dependency tracks its upstream project (`veelenga/lua.cr`), also pinned to a commit: the fixes the author once carried on a fork landed upstream, so the fork is retired.

| Shard              | Role                                       |
| ------------------ | ------------------------------------------ |
| `anykeyh/agent.cr` | The LLM agent loop behind both assistants. |

To move a pin: edit the `commit:` SHA, run `shards install` (or `shards update <name>`), then `make check` and `make test`.

## Conventions that surprise newcomers

- `account` names the identity (`account_id`). `user` stays in UX copy. See [`doc/backend/iam.md`](doc/backend/iam.md) → Terminology.
- Every timestamp column stores naive UTC.
- Configuration comes from `config.{env}.yml`, not from `ENV` (secrets excepted).
- Event delivery is at-most-once by decision. PostgreSQL holds durable state; Redis is a reaction bus.
- One concern = one doc file under `doc/`. Docs use ASD-STE100 Simplified Technical English.
- Migrations are append-only after release. Each file carries `-- UP` / `-- DOWN` sections.

The full quirk list lives in [`AGENTS.md`](AGENTS.md).
