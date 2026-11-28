---
title: Keep it running
description: Check health, run the background jobs, upgrade, and back up — the operator half of running Facet.
type: overview
audience: [admin, operator]
features: []
verified_at: eee55a2
sidebar:
  order: 0
---

Facet is running and the first users are on it. Your job now is to keep it
that way. Hear about problems before users do. Understand the work the
server does on its own. Move to a new release without fear. And know that
you could recover from a bad day.

Each page in this group answers one of those jobs. Read them in the order of
a normal week: check health first, learn what runs at night second, and keep
the rest as reference.

## What do you want to do?

| Job | Start here |
| --- | --- |
| Wire monitoring, so you hear about problems first | [Health, metrics and logs](/admin/keep-running/monitoring/) |
| Understand the background work and the nightly schedule | [Background jobs and cron](/admin/keep-running/jobs-cron/) |
| Upgrade to a new release, or restart cleanly | [Upgrade Facet](/admin/keep-running/upgrades/) |
| Change the database schema by hand, or undo one | [Database migrations](/admin/keep-running/migrations/) |
| Check the indexes that serve lists and search | [Indexes](/admin/keep-running/indexes/) |
| Protect the installation against data loss | [Back up and restore](/admin/keep-running/backup-restore/) |

## All pages in this section

1. [Health, metrics and logs](/admin/keep-running/monitoring/) — the probes, the metrics, traces and logs.
2. [Background jobs and cron](/admin/keep-running/jobs-cron/) — the job queue and the nine scheduled tasks.
3. [Database migrations](/admin/keep-running/migrations/) — apply and revert schema changes.
4. [Upgrade Facet](/admin/keep-running/upgrades/) — the release runbook and the graceful stop.
5. [Indexes](/admin/keep-running/indexes/) — the managed PostgreSQL indexes.
6. [Back up and restore](/admin/keep-running/backup-restore/) — what to protect, and how to prove a restore.

## Related

- [Administer](/admin/) — the full admin section, one layer up.
- [Go to production](/admin/install/production/) — the checklist that sends you here before launch.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — why the health counters matter.
