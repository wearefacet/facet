---
title: Performance & sizing
description: How fast a single Facet instance is under real load, and how to size a deployment.
type: reference
audience: [operator, evaluator]
features: [AUT-04, PLT-05, PLT-13]
sidebar:
  order: 1
verified_at: 9aea50f
---

**The short answer:** one Facet instance on a modern machine handles around
**300 operations per second** under sustained mixed traffic. Most reads come
back in **20–30 ms**, writes in **5–100 ms** depending on load. In our
20-minute run with 20 clients and 4.6 million documents, **no request failed**.

Most of that time is spent in **PostgreSQL**, not in Facet. How fast your
deployment runs depends mainly on how your database is set up. See
[Where the time goes](#where-the-time-goes).

---

## Test setup

| | |
|---|---|
| Facet version | 0.2.3 (backend + frontend Docker images, default config) |
| Machine | AMD Strix-class workstation, a single box running Facet, PostgreSQL and the load generator |
| Topology | **1** Facet process, **1** PostgreSQL instance, Caddy at the edge |
| Memory limit | 10 GB for the Facet container |
| Dataset | One document type (`Invoice`, ~20 fields, 74 indexed), grown from **2.5 M to 4.7 M documents** (14 GB) during the run |
| PostgreSQL | 17 (`pgvector/pgvector:0.8.0-pg17`), same machine, local NVMe |
| PostgreSQL settings | `max_connections = 200`, `shared_buffers = 128 MB`, `work_mem = 4 MB`, `effective_cache_size = 4 GB`, `synchronous_commit = on`, `max_parallel_workers_per_gather = 2`; Facet connection pool at its default size |

This is a single machine with no replicas and no cache layer. A typical
server deployment runs PostgreSQL on its own host, so expect equal or better
numbers there. Read the [notes on servers](#running-on-a-server) below.

---

## What to expect

### Everyday use (mixed load)

20 concurrent clients for 20 minutes against 4.6 M documents. 75 % of the
traffic was reads (list, filter, sort, get by id) and 25 % was writes
(updates and creates).

| | |
|---|---:|
| Throughput | **311 ops/s** (~1.1 M ops/hour) |
| Read latency, p50 / p95 | **45 ms / 98 ms** |
| Write latency, p50 / p95 | **108 ms / 230 ms** |
| Errors | **0** in 373 884 requests |

### Reads

2.5 M documents, 8 concurrent clients. All values in ms.

| Query | p50 | p95 |
|---|---:|---:|
| Get by id | 12 | 31 |
| List (default page) | 24 | 39 |
| Count | 18 | 35 |
| Document history | 18 | 27 |
| Filter on an indexed field (equality, range, country…) | 26–29 | 42–49 |
| Full-text filter on an indexed field | 31 | 62 |
| Sort by any indexed field or by creation date | 22–23 | 36–42 |
| Page through results (first 500 rows) | 22 | 39 |
| Deep page (row ~5 000) | 102 | 144 |
| Embedded line items (100 per document) | 50 | 78 |
| **Aggregates (`sum`, …) over the whole table** | **1 037** | **2 732** |
| **Global search** | **807** | **1 555** |

Any query that uses an index is fast, and its speed barely depends on table
size. Two kinds of query stay slow on large tables:

- **Aggregates and search across millions of documents** take about 1 s.
  Narrow them with a filter, or run them in the background.
- **Very deep offset paging** (for example page 100 000) takes 2–3 s. Filter
  or sort to reach the rows you need rather than paging that far.

Filtering on a field that has no index is refused with a `422` that lists
which fields you can filter on. Facet never falls back to a slow scan without
telling you.

### Writes

| Concurrent writers | Creates/s | p50 | p95 |
|---:|---:|---:|---:|
| 1 | 250 | 4 ms | 5 ms |
| 4 | 320 | 11 ms | 23 ms |
| 8 | 350 | 22 ms | 36 ms |
| 32 | 320 | 99 ms | 139 ms |
| 128 | 285 | 428 ms | 641 ms |

Updates (`PATCH`, 8 writers) run at **350/s**, with a p50 of 20 ms and a p95
of 47 ms.

**One instance tops out at about 300–350 writes per second.** Beyond that,
extra clients don't add throughput. They make each request wait longer.

### Bulk import

| | |
|---|---:|
| One import job | ~440 rows/s (100 k rows in ~4 min) |
| 2 jobs in parallel (the default maximum) | ~720 rows/s in total |
| 1 M rows | ~23 min |
| 2 M rows | ~46 min |

Memory stays bounded. One import of 100 k rows adds about 0.6 GB, and
several large imports running together peaked at about 6 GB. When the
imports finish, memory falls back to about 1 GB. No more than 2 imports run
at the same time (the import's own cap inside `jobs.max_concurrent`), and
any further jobs wait in a queue.

### Overload

| Concurrent writers | Result |
|---:|---|
| up to 128 | all requests succeed |
| 256 | 7.5 % refused with `503` |
| 512 | 87 % refused with `503` |

When it is overloaded, Facet **refuses requests quickly and says why** with
`503 {"error":"Service unavailable","dependency":"postgresql"}`, and it keeps
serving the requests it accepts. It does not hang or time out. Clients can
retry with backoff.

---

## Where the time goes

Each limit above comes from PostgreSQL.

| Limit | What sets it | What raises it |
|---|---|---|
| **~300 writes/s** | Each write spends about **3 ms in PostgreSQL**: 1.6 ms to update the document and 1.4 ms to append it to the history. 300 writes/s × 3 ms ≈ 1 s of database time per second, so writes go through one at a time. The ceiling is how fast PostgreSQL can complete one write. | Lower commit latency: fast NVMe storage, PostgreSQL on its own host, WAL and commit settings. Adding Facet threads does nothing. |
| **~1 s aggregates and search** | PostgreSQL scanning millions of rows | More RAM for caching, `work_mem`, parallel query workers, or a narrower filter |
| **Deep paging** | PostgreSQL skipping over the earlier rows | Filter or sort instead of paging far |
| **`503` under overload** | No free database connection (`max_connections`, pool size) | More connections, or a connection pooler |

Facet itself is light: about one CPU core and 1–2 GB of memory. Bulk import
is the exception, because Facet decodes rows on its own CPU.

---

## Sizing guide

| If you need… | Deploy |
|---|---|
| Up to ~300 ops/s mixed, or ~300 writes/s (≈ 1 M writes/hour) | **1 instance** |
| More write throughput | **A faster PostgreSQL** (storage, dedicated host, commit settings). Running more Facet processes has not been benchmarked yet. |
| Fast reports over millions of rows | Filtered queries or background jobs; whole-table aggregates take ~1 s |
| Large initial data migration | Plan ~25 min per million rows |

Memory: plan **2 GB** for the Facet process in normal use, and **8 GB** if
you run large parallel imports.

## Running on a server

Put your sizing effort into **PostgreSQL**.

- **Storage latency sets the write limit.** Use local NVMe, or a managed
  database with low commit latency. Slow network-attached disks bring the
  ~300 writes/s down in proportion to how slow they are.
- **Give PostgreSQL enough RAM to keep your active data cached.** The reads
  in this test run in 20–30 ms because indexes and recent data stay in
  memory.
- **Run PostgreSQL on its own host.** In this test, PostgreSQL, Facet and the
  load generator all shared one machine.
- **Allow enough database connections** (`max_connections`). Running out of
  connections is the first limit you hit under overload.
- Facet itself needs **1–2 CPU cores and 2 GB of memory**, or 8 GB if you
  run large parallel imports.

## Getting these numbers

- Install **0.2.3 or later**. The indexes and planner statistics these
  numbers depend on are created automatically on a fresh install.
- **Run `ANALYZE projections;` after a large initial import.** PostgreSQL
  needs fresh statistics to plan queries well. Autovacuum gets there on its
  own eventually, but running `ANALYZE` yourself makes queries fast right
  away.
- If you **upgraded from an earlier version**, follow the
  [0.2.3 upgrade notes](/admin/keep-running/upgrades/) to add the new indexes
  and statistics to your existing database. Without them, filters and date
  sorts on large tables can be up to 100× slower.

## Related

- [System requirements](/admin/install/requirements/) — what a host needs to run Facet.
- [Upgrade Facet](/admin/keep-running/upgrades/) — the deployment notes each release carries, including 0.2.3.
- [Health, metrics and logs](/admin/keep-running/monitoring/) — the counters to watch under load.
- [Limits](/reference/limits/) — the exact caps and the config keys behind them.
