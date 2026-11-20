# WP 12 — Operate section (`/operate/`)

Phase 1 (whole-doc §7) · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/operate/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.8. Audience: operators (self-hoster, ops). How-to pages: WP 00 skeleton with `## Steps`.

Split into two batches.

## Batch A — deploy and configure (10 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `operate/system-requirements.md` | System requirements and topology | `audience: [operator, evaluator]`, `features: [PLT-10, PLT-16]` | `doc/ops/container-images.md`, `doc/ops/first-deployment.md` |
| `operate/containers-tls.md` | Deploying with containers (+ Caddy TLS) | `audience: [operator]`, `features: [PLT-16, APP-06]` | `doc/ops/container-images.md`, `doc/ops/first-deployment.md` |
| `operate/configuration-files.md` | Configuration files | `audience: [operator]`, `features: [PLT-01]` | `doc/backend/config.md` |
| `operate/system-settings.md` | System settings | `audience: [operator, admin]`, `features: [PLT-02, FE-14]` | `doc/backend/system-settings.md` |
| `operate/bootstrap-cli.md` | Bootstrap and CLI tasks | `audience: [operator]`, `features: [IAM-12, DOM-24]` | `doc/backend/cli.md` |
| `operate/email.md` | Email delivery | `audience: [operator]`, `features: [AUT-07]` | `doc/backend/config.md` (mail), `doc/backend/notifications.md` |
| `operate/file-storage.md` | File storage: filesystem or S3 | `audience: [operator]`, `features: [PLT-04]` | `doc/backend/artifact.md` |
| `operate/assistant-config.md` | Configuring the assistant (LLM endpoint, model, budgets) | `audience: [operator]`, `features: [AI-08, AI-07, AI-09]` | `doc/backend/assistant.md`, `doc/backend/system-settings.md` |
| `operate/migrations.md` | Database migrations | `audience: [operator]`, `features: [PLT-11]` | `doc/backend/migrations.md` — include the deployment constraints (UTC session default, append-only rule) |
| `operate/indexes.md` | Managed indexes | `audience: [operator]`, `features: [PLT-05]` | `doc/backend/index-management.md` |

## Batch B — run and maintain (7 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `operate/jobs-cron.md` | Background jobs and cron | `audience: [operator]`, `features: [AUT-04, AUT-05]` | `doc/backend/jobs.md`, `doc/backend/cron.md` |
| `operate/health-metrics-logs.md` | Health checks, metrics, tracing, logs | `audience: [operator]`, `features: [PLT-06, PLT-07, PLT-08, PLT-09, AUT-01]` | `doc/backend/metrics.md`, `doc/backend/telemetry.md`, `doc/backend/logging.md`, `doc/backend/event.md` (event_loss and max-lag gauges) |
| `operate/currencies.md` | Currencies and money | `audience: [operator, author]`, `features: [PLT-14, FE-15]` | `doc/backend/util-money.md` |
| `operate/retention-tuning.md` | Retention tuning | `audience: [operator]`, `features: [AUD-05, AUD-06, AUD-07]` | `doc/backend/audit.md`, `doc/backend/mutation.md` |
| `operate/upgrades-shutdown.md` | Upgrades and graceful shutdown | `audience: [operator]`, `features: [PLT-15, PLT-11]` | `doc/backend/shutdown.md`, `doc/backend/migrations.md` |
| `operate/backup-restore.md` | Backup and restore | `audience: [operator]`, `features: []` | **Blocked on D1** (`99-decisions.md`): whole-doc §6 item 1 — document the replica + backup + S3 approach, or name it the operator's responsibility. Do not write this page before D1 is decided. |
| `operate/localization.md` | Localization | `audience: [operator, user]`, `features: [FE-20]` | `doc/frontend/settings.md`, `doc/backend/system-settings.md` |

`operate/index.md` (from WP 01): the batch that runs last finishes the index. Note the existing `operate/production.md` (from the old `deploy/` directory) — fold its content into `containers-tls.md` and delete it, or keep it as the deployment walkthrough and cross-link; the batch A agent decides and updates `operate/index.md` accordingly.

## Writing notes

- Every config example is a valid `config.{env}.yml` fragment — complete keys, real defaults (WP 00: no elisions).
- `health-metrics-logs.md` lists the real metric names from `doc/backend/metrics.md`.
- `backup-restore.md` waits for D1. If D1 says "operator's responsibility", the page states exactly that, with the PostgreSQL tooling pointers.

## Definition of done (per batch)

- [ ] Batch pages written, front-matter per WP 00.
- [ ] Config fragments validated against `doc/backend/config.md` key names.
- [ ] `cd site-docs && npm run build` passes.
