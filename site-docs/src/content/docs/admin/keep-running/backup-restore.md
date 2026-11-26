---
title: Back up and restore
description: Back up the four things Facet keeps state in, and prove a restore works before you need it.
type: how-to
audience: [operator]
features: [PLT-03, PLT-04]
verified_at: eee55a2
sidebar:
  order: 6
---

The disk holding your PostgreSQL volume just failed, or a bad upgrade left
the data unusable. What saves you is the backup you took before — and Facet
does not take it for you. Facet ships no backup feature: no backup command,
no scheduled dumps, no point-in-time recovery. Backup and restore are the
operator's job, by design. PostgreSQL already has the tools; Facet's job is
to keep its state in places you can back up with them.

This page lists exactly what to protect, what the shipped container setup
gives you, and how to prove a restore works.

## Before you start

- [Run with containers](/admin/install/containers/) — the volumes and mounts this page protects.

## What to back up

Four things hold state. Lose any one of them and part of the installation is
gone for good.

| What | Where it lives | Why |
| --- | --- | --- |
| PostgreSQL | The `pg-data` volume (or your managed database) | The durable state: every document, every history row, every secret slot, accounts, roles, settings. Redis holds only reactions — nothing to back up. |
| Artifact storage | The `artifact-store` volume, or your S3 bucket | Uploaded files and generated bundles live outside the database, by design. |
| Config files | `config.{env}.yml`, plus any `.env` file beside it | The file is the single source of truth for runtime configuration. |
| Secrets | The secret-store master key, and the other env secrets | The database stores secrets sealed with AES-256-GCM under this key. The key lives only in your environment. |

Two of these deserve a closer look.

**The secret-store master key unlocks the backup, not just the boot.**
Password hashes, API credentials, TOTP seeds — every stored secret sits in
the PostgreSQL secret store. The `sealed` ones are encrypted with AES-256-GCM
under `secrets.master_key`. The shipped production config reads that key from
the environment: `master_key: !env FACET_SECRETS_MASTER_KEY`. Restore a
database without the key that sealed it, and every sealed slot stays
unreadable — sign-ins fail, webhooks lose their credentials. Back the key up
beside the dump, in a place with different failure modes than the database
host. The same rule covers the other env secrets the deployment needs, such
as `JWT_SIGNING_KEY`.

**Redis is a reaction bus, not a record.** Events, shard locks, and cron
leases pass through it; PostgreSQL holds the durable state. A lost Redis
dataset costs transient reactions, not data — the consumers self-heal or get
repaired. Do not spend backup effort on it; do spend it on PostgreSQL.

## What the shipped setup provides

The production compose stack defines four named volumes: `pg-data`,
`redis-data`, `caddy-data`, and `artifact-store`. Volume contents survive
container restarts, which is all a volume does — it is not a backup. The
The backend config example wires the artifact store to the `artifact-store`
volume at `/data/store`. Point `artifact.storage` at S3 if your backup
tooling already covers object storage.

PostgreSQL backup tooling works unchanged. Use `pg_dump` for logical dumps,
`pg_basebackup` or provider snapshots for physical copies, and WAL archiving
for point-in-time recovery. Facet uses standard PostgreSQL features only —
no custom storage engine sits in the way.

## Steps

### 1. Back up PostgreSQL on a schedule

```sh
docker compose -f docker/compose.prod.yml exec -T postgres \
  pg_dump -U facet -Fc facet > facet-$(date +%F).dump
```

Test the exact command against your deployment first: the service name, user,
and database name come from your compose file and environment. Store dumps
off the host — a backup on the same disk as the database survives nothing.

### 2. Back up the artifact store

For the filesystem adapter, copy or sync the store directory the way you
back up any file tree. For S3, use your bucket's replication or versioning.
Match the cadence to how often people upload.

### 3. Back up config and secrets

Keep a copy of `config.{env}.yml` and the `.env` file with the environment
secrets — `FACET_SECRETS_MASTER_KEY` above all. These change rarely; back
them up on every change, and store them where only operators can read them.

### 4. Prove the restore before you need it

A backup you have never restored is a hope, not a backup. Rehearse on a
scratch machine:

1. Start an empty PostgreSQL and an empty artifact store.
2. Restore the database dump, then restore the artifact store contents.
3. Restore the config file and the environment secrets, master key included.
4. Start the stack. The entrypoint runs `facet migrate && facet seed:core` —
   both are safe on an existing, up-to-date database.
5. Check `GET /Healthcheck` answers `200`, sign in with a real account, and
   open one document with a history entry.

Steps 1 to 5 are the whole test. Write down how long they took; that number
is your real recovery time, and it belongs in your continuity plan.

### 5. Restore for real

Run the same five steps against the production hosts. Two warnings:

- Do not run `db_reset`. It drops, recreates, and re-migrates the database —
  it destroys the data you are restoring.
- Let the boot migrations run. If the backup predates the current release,
  the entrypoint migrates the restored schema forward on boot; that is
  normal and safe.

## What Facet does not provide

Say it plainly, because an auditor will ask:

- No backup command and no scheduled backup task ship with the product.
- No point-in-time recovery is wired; if you need it, configure WAL archiving
  on PostgreSQL yourself.
- No cross-region replication ships with the stack.

The [Keep it running](/admin/keep-running/) group covers everything the product
does run for you; recovery from data loss is not on that list.

## Related

- [Health, metrics and logs](/admin/keep-running/monitoring/) — the check to run first after any restore.
- [Upgrade Facet](/admin/keep-running/upgrades/) — the snapshot-before-revert rule this page builds on.
- [Run with containers](/admin/install/containers/) — the volumes and mounts this page protects.
- [Go to production](/admin/install/production/) — the checklist that sends you here before launch.
