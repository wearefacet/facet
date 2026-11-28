---
title: Operate
description: Run Facet in production — deploy with containers, configure, monitor, and upgrade.
audience: [operator]
features: []
sidebar:
  order: 0
verified_at: 008dd880
---

This section is for operators who run Facet for their organization. It
covers system requirements, container deployment, configuration, storage,
email, background jobs, health and metrics, currencies, retention,
upgrades, and localization.

## Deploy and configure

- [System requirements and topology](/operate/system-requirements/) — what a
  host needs and how the services connect.
- [Deploying with containers](/operate/containers-tls/) — the release images,
  config mounting, and the Caddy TLS edge.
- [Deploy to production](/operate/production/) — the copy-paste Docker
  Compose walkthrough.
- [Configuration files](/operate/configuration-files/) — one YAML file
  configures the backend; inject secrets with `!env`.
- [System settings](/operate/system-settings/) — change platform knobs at
  runtime, with the config file as fallback.
- [Bootstrap and CLI tasks](/operate/bootstrap-cli/) — first deployment,
  accounts, lockout recovery, and maintenance commands.
- [Email delivery](/operate/email/) — SMTP setup, the production gate, and
  runtime changes.
- [File storage: filesystem or S3](/operate/file-storage/) — the artifact
  store, its knobs, and its care tasks.
- [Configuring the assistant](/operate/assistant-config/) — connect an
  OpenAI-compatible provider and tune the turns.
- [Database migrations](/operate/migrations/) — apply and revert, and the
  UTC and append-only rules.
- [Managed indexes](/operate/indexes/) — watch index health and retry failed
  builds.

## Run and maintain

- [Background jobs and cron](/operate/jobs-cron/) — the job queue, retries
  and leases, and the eight scheduled passes.
- [Health checks, metrics, tracing, logs](/operate/health-metrics-logs/) —
  the probes, the metric catalog, OpenTelemetry, and log setup.
- [Currencies and money](/operate/currencies/) — curate the currency list
  and learn how money values are stored and filtered.
- [Retention tuning](/operate/retention-tuning/) — set the history and
  tombstone windows, in the file or at runtime.
- [Upgrades and graceful shutdown](/operate/upgrades-shutdown/) — the
  release runbook and the clean-stop sequence.
- [Localization](/operate/localization/) — instance defaults for timezone
  and language, and the per-account settings.
