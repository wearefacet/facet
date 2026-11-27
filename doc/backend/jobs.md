# Background Jobs

The background-jobs concern is a PostgreSQL-only job queue. Callers enqueue
rows in the `background_jobs` table, and one poll-loop worker claims due rows
and runs the matching handler. The queue is a plain operational table — no
triggers, no RBAC, no event sourcing.

**Source files:** `src/jobs.cr`, `src/jobs/job.cr`, `src/jobs/handler.cr`,
`src/jobs/liveness.cr`, `src/jobs/queries.cr`, `src/jobs/worker.cr`,
`src/jobs/manager.cr`,
`src/config.cr` (`JobsConfig`, `load_jobs`),
`db/migrations/0008_jobs.sql` (also holds the `webhook_calls` log table,
the `lease_ttl_s` column, and the `result` outcome payload column)

---

## Job model

One row is one unit of work. The row carries the work (`kind`, `payload`),
the retry policy (`max_attempts`, `backoff_seconds`), the lease state
(`locked_by`, `locked_until`), the last-attempt debug capture (`last_error`,
`last_http_status`), and the terminal outcome payload (`result`). A row is
not a domain document and not event-sourced.

### Per-row lease override

A row may carry its own `lease_ttl_s`, set at enqueue time. `claim`
computes `locked_until` from the row's own value when set, else from the
worker's `lease_ttl_s`. The default (nil) keeps the worker TTL, so existing
callers are unaffected. Long job kinds (a document or domain import/export
always outlives the 60 s default) enqueue with a generous horizon from
`jobs.long_lease_ttl_s` — far above any real runtime, short enough that a
dead worker's row recovers within the window. There is no "no TTL" option:
the lease sweep and the instance liveness check are the crash detectors,
and a finite horizon is what turns a crashed job into a clean
re-execution when the worker still ticks but the handler hangs.

`attempts` counts claims, not outcomes. `claim` increments it, so a first
execution runs with `attempts = 1`. `run_after` gates due-ness; it is NULL
only on terminal rows.

### Status state machine

| From        | To           | Cause                                        |
| ----------- | ------------ | -------------------------------------------- |
| `pending`   | `running`    | claim (`Queries.claim`)                      |
| `running`   | `pending`    | failure with attempts left (`write_failed`)  |
| `running`   | `pending`    | lease sweep requeues a stranded row (expired lease, or owner instance dead) |
| `running`   | `succeeded`  | outcome write (`write_succeeded`)            |
| `running`   | `failed`     | outcome write when `attempts >= max_attempts`|
| `running`   | `failed`     | lease sweep caps a stranded row whose `attempts >= max_attempts` (worker lost) |

There is no `dead` state. A row with no registered handler goes terminal
`failed` with `last_error = "no handler for kind ..."`. Two partial indexes
serve the hot paths: `idx_background_jobs_claim` (due pending rows, ordered
by `run_after`) and `idx_background_jobs_prune` (terminal rows past
retention).

### Retry policy

Retry-vs-terminal is decided in one atomic `UPDATE` inside `write_failed`,
not in Crystal. A lease expiry can never interleave between the decision
and the write. The delay is `backoff_seconds[attempts]` (1-based PG array;
the stored `attempts` is the failed-attempt count after `claim` incremented
it). A NULL or empty list retries immediately. The lease sweep applies the
same cap: a stranded row (expired lease, or owner instance dead) past its
`max_attempts` goes terminal `failed` with
`last_error = "job abandoned — worker lost"` — a crash-looping job cannot
requeue forever.

---

## `Jobs::Handler`

`Facet::Jobs::Handler` (`src/jobs/handler.cr`) is the abstract class for one
job kind. `execute` does the work; the attempt hooks observe the worker
lifecycle points. Every hook has a no-op default, so a subclass overrides
only the ones it needs.

The handler never touches the `background_jobs` row — the worker writes the
outcome from the returned `Result`. The worker reads the row's
`max_attempts` to decide retry-vs-terminal; the handler does not classify
its own retryability. Subclasses are stateless and take no constructor
arguments: the worker instantiates one per claimed row through the dispatch
table.

| Member                     | Role                                                                     |
| -------------------------- | ------------------------------------------------------------------------ |
| `Result` record            | Outcome of one execution: `status`, `error`, `http_status`, `response_body`, `duration_ms`, `result` |
| `Kind` enum                | `Succeeded` / `Failed`                                                    |
| `.execute(job : Job)`      | Abstract. Runs the work for one claimed row. An uncaught exception becomes a `Failed` result — handlers do not catch their own exceptions for retry purposes. |
| `.default_max_attempts`    | `5`. A job row may override at enqueue time.                              |
| `.default_backoff`         | `[10, 60, 300, 1800, 7200]`. A job row may override at enqueue time.      |

### Attempt lifecycle hooks

| Hook                                                       | Fired                                             |
| ---------------------------------------------------------- | ------------------------------------------------- |
| `attempt_started(db, job, attempt)`                        | Right after the worker claims the row.            |
| `attempt_finished(db, job_id, attempt, result)`            | Right after the outcome write.                    |
| `attempt_abandoned(db, job_id)`                            | When the lease sweep recovers a `running` row: expired lease, dead owner instance, or the retry cap. |
| `prune_expired(db, retention_days) : Int32`                | On the worker's prune pass. Deletes the handler's own attempt-log rows older than `retention_days` and returns the count. |

The worker wraps every hook call: a raising hook is logged and skipped, and
the job outcome path is untouched. A kind with no registered handler has no
hooks.

---

## `Jobs::Job`

`Facet::Jobs::Job` (`src/jobs/job.cr`) is the record returned by
`Queries.claim` and `Queries.find`: `id`, `kind`, `payload`, `attempts`,
`max_attempts`, `backoff`.

---

## `Jobs::Queries`

`Facet::Jobs::Queries` (`src/jobs/queries.cr`) holds every SQL statement on
`background_jobs`. All methods take an explicit `db : DB::Connection` (use
`Database.with_db(:read_write)` — the worker's claim (`FOR UPDATE SKIP
LOCKED`), sweep, prune, and result writes are write-shaped) and bind
timestamps as UTC RFC-3339 strings — the columns are `TIMESTAMPTZ`.

| Method                        | Returns      | Notes                                                                 |
| ----------------------------- | ------------ | --------------------------------------------------------------------- |
| `insert(db, id, kind, payload, max_attempts: nil, backoff: nil, run_after: nil, lease_ttl_s: nil)` | — | Inserts one `pending` row. NIL policy fields fall back to the column defaults. |
| `claim(db, locked_by, lease_ttl_s, batch)` | `Array(Job)` | Claims up to `batch` due rows with `FOR UPDATE SKIP LOCKED`, so two workers get disjoint row sets. Sets `running`, increments `attempts`, starts a lease. The lease length is the row's own `lease_ttl_s` when set, else the worker TTL. `locked_by` carries the owner tag `{instance_id}:{worker_id}` — the boot's `Facet::Service` instance id, then the worker's own ULID. Rows come back ordered by due-ness. |
| `running_owner_instances(db)` | `Array(String)` | The distinct owner instance ids of the `running` rows — the part of `locked_by` before the first colon. The worker checks each id against the owner's liveness key. |
| `write_succeeded(db, id, http_status: nil, result: nil)` | — | Terminal `succeeded` outcome. Clears the lease and `last_error`. `result` stores the handler's terminal payload. |
| `write_failed(db, id, error: nil, http_status: nil, backoff_seconds: nil, result: nil)` | — | One atomic `UPDATE`: retry (`pending` + pushed `run_after`) or terminal `failed`, from the row's own `attempts` / `max_attempts`. `result` stores the handler's terminal payload on a terminal row (e.g. the failing row's coordinates on an import). |
| `sweep_expired_leases(db, dead_instances)`    | `Array({id, kind})` | Recovers stranded `running` rows: requeues a row whose lease expired or whose owner instance is in `dead_instances` (the owner's liveness key is gone); a touched row past its retry cap (`attempts >= max_attempts`) goes terminal `failed` with `last_error = "job abandoned — worker lost"` instead. Does not touch `attempts`. Returns the touched rows' `id` and `kind` for the `attempt_abandoned` hook. |
| `prune_terminal(db, retention_days)` | `Int32` | Deletes terminal rows older than `retention_days`. Non-terminal rows survive whatever their age. |
| `find(db, id)`                | `Job?`       | Single-row lookup; `nil` when absent. |
| `find_outcome(db, id)` | `Outcome?` | The caller-facing outcome: `status`, `error`, `result` (the handler's payload — NULL while the row is pending/running); `nil` when absent. |

---

## `Jobs::Worker`

`Facet::Jobs::Worker` (`src/jobs/worker.cr`) is the poll loop over
`background_jobs`. One loop fiber — supervised by `Util::FiberSupervisor`, so a
raise that escapes the loop body restarts it after a backoff — claims due rows,
runs each claimed job in its own fiber, and writes the outcome. A job fiber
never crashes the loop: an uncaught handler exception becomes a `Failed`
result, and a failed outcome write is logged — the lease sweep recovers the
row later. Job due-ness is decided by PostgreSQL's `now()`, not by the
injected `@clock` (the clock exists so tests drive sweeps and prunes
deterministically).

Each tick runs in this order:

1. **Maintenance** — the instance liveness refresh, the lease sweep, and
   the terminal prune, each on its own cadence (see below). The first
   tick always runs one sweep and one prune; sentinel past instants
   guarantee that.
2. **Claim** — one `Queries.claim` batch. One handler instance per claimed
   row; the hooks and `execute` run on the same object, so a handler may
   keep per-attempt state. The pass first holds while `max_concurrent`
   job fibers already run, so a heavy kind (an import decodes a whole
   file and buffers one event per row) cannot run more copies at once
   than the cap allows. A pass that claims nothing returns its slot.
3. **Dispatch** — one fiber per claimed job. The worker writes the outcome
   from the returned `Result` and fires `attempt_finished`. A `Failed`
   result logs one warn line (`job id`, `kind`, `error`) per failed attempt
   — the row and the caller's notification carry the detail, and the log
   line keeps a terminal failure visible in the process output.

When no row was claimed, the loop sleeps `poll_interval_s`; otherwise it
re-polls immediately (more rows may be due).

| Member                       | Role                                                                 |
| ---------------------------- | -------------------------------------------------------------------- |
| `#start`                     | Spawns the loop fiber. Idempotent.                                   |
| `#stop`                      | Closes the wake channel; the loop exits on its next `select` turn. Idempotent. In-flight job fibers run to completion. |
| `#wake`                      | Sends to the wake channel; breaks the sleep. Tests call it after enqueue. |
| `#enqueue(db, kind, payload, ...)` | Inserts one `pending` row; returns the row id. Accepts `lease_ttl_s` for the per-row lease override. |
| `#running?`                  | `true` while the loop fiber runs.                                    |
| `#handlers`                  | The `kind` → `Handler` dispatch table (snapshot taken at construction). |

### Lease sweep

Every `sweep_interval_s`, the worker refreshes its instance's liveness
key, resolves the dead owner instances (`Queries.running_owner_instances`
+ `Liveness#alive?`), and requeues `running` rows whose lease expired or
whose owner instance is dead. A touched row past its retry cap
(`attempts >= max_attempts`) goes terminal `failed` with
`last_error = "job abandoned — worker lost"` instead of requeuing — a
crash-looping job cannot requeue forever. The requeued (or failed) rows
and the `attempt_abandoned` hook calls share one transaction, so a crash
between the requeue and the hook leaves no half-marked state. Requeued
rows are due immediately, and the claim of the same tick runs after the
sweep — no forced wake is needed.

### Instance liveness

On every sweep tick the worker marks its own instance alive: one Redis
key per instance, `FACET:JOBS:SERVICE_LIVENESS:{instance_id}`
(`Liveness.key`). The instance id is the boot's `Facet::Service` ULID —
the instance-identity rule (`doc/backend/event.md` → Shard locking).

The key's TTL is 120 s (`Liveness::Redis::TTL_S`) — four sweep ticks. It
survives three missed ticks, one more than the two required, so a brief
stall (a slow tick, a short GC pause) never declares a live instance
dead. A dead instance is still detected within one tick past the TTL —
far below any lease horizon.

The check is injectable: the worker takes a `Liveness` object, and
`Liveness::Redis` is the default. A Redis failure fails open — the
instance answers alive, and the lease sweep stays the only recovery path
until Redis returns.

### Prune ticks

Every hour, the worker deletes terminal rows older than `retention_days`
and calls each registered handler's `prune_expired`, so attempt-log tables
share the queue's retention horizon. A failing prune is logged and skipped.

---

## `Jobs::Manager`

`Facet::Jobs::Manager` (`src/jobs/manager.cr`) is the coordinator and the
process-wide singleton. `main.cr` constructs it, installs it with
`instance=`, and calls `start` after the HTTP server boots; `stop` runs in
`at_exit`. The accessors (`self.instance`, `self.instance=`,
`self.reset!`) mirror `Hooks::Manager`; `instance` returns `nil` when no
manager is installed, and callers use `try` to skip safely.

| Member                                  | Role                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------- |
| `#register_handler(kind, handler)`      | Fills the dispatch table one entry at a time. Must run **before** `start` — the worker snapshots the map at start, so a later entry would never dispatch. Registration after start raises. |
| `#handler_for(kind)`                    | The registered handler class for `kind`, or `nil`. Read-only view.        |
| `#start`                                | Starts the worker when `jobs.enabled` is true. Idempotent; a no-op when disabled. |
| `#stop`                                 | Stops the worker. Idempotent; safe when disabled.                          |
| `#enqueue(kind, payload, max_attempts: nil, backoff: nil, run_after: nil, lease_ttl_s: nil, max_concurrent: nil)` | Inserts one `pending` row and returns the row id. Delegates to the running worker. `max_concurrent` is the kind's own fiber cap; the tightest value seen lowers the next `start`'s cap. |
| `#worker`                               | The running `Worker`, or `nil`.                                           |

### Enqueue-only mode

With `jobs.enabled: false` the worker never starts. `enqueue` still inserts
rows, so callers stage work that another process (with the worker on)
claims. The test config (`config.test.yml`) runs in this mode; specs that
exercise the worker construct `Jobs::Manager` / `Jobs::Worker` explicitly.

---

## Wiring

`main.cr` wiring order:

```crystal
jobs_manager = Facet::Jobs::Manager.new
Facet::Jobs::Manager.instance = jobs_manager
webhook_manager.register_handler(jobs_manager) # BEFORE jobs_manager.start
jobs_manager.start
```

`stop` runs in the `at_exit` block. The webhook registration must precede
`start` — see `register_handler` above.

The handler kinds registered from `main.cr` → `job_handler_entries`:

| Kind | Handler | Runs |
| --- | --- | --- |
| `document_export` | `Document::ExportJob` | once (`max_attempts: 1`), long lease |
| `document_import` | `Document::ImportJob` | once, long lease |
| `domain_export` | `Domain::Portable::ExportJob` | once, long lease |
| `domain_import` | `Domain::Portable::ImportJob` | once, long lease |
| `doctype_reproject` | `Doctype::ReprojectJob` | once, long lease |
| `doctype_migrate_ahead` | `Doctype::AheadMigrationJob` | once, long lease |

---

## Config

`JobsConfig` on `Facet::Config` (`src/config.cr`, `load_jobs`). The
`jobs:` section is optional; the defaults apply when it is absent.

| Key                | Default | Meaning                                                        |
| ------------------ | ------- | -------------------------------------------------------------- |
| `poll_interval_s`  | `5.0`   | Idle wait between claim passes.                                 |
| `lease_ttl_s`      | `60`    | How long a claimed row stays `running` before the sweep requeues it. |
| `long_lease_ttl_s` | `3600`  | The per-row lease horizon long job kinds (document and domain import/export) pass at enqueue. |
| `batch`            | `32`    | Max rows claimed per pass.                                      |
| `max_concurrent`   | `4`     | Max job fibers running at once. A claim pass holds while this many run, so a burst of heavy jobs cannot multiply the process footprint without bound. A kind's own `Handler.max_concurrent` (the import declares `2`) lowers the cap of the next worker start to the tightest enqueue seen. |
| `sweep_interval_s` | `30.0`  | Cadence of the lease sweep; also the cadence of the instance liveness refresh. |
| `retention_days`   | `30`    | Terminal rows older than this are pruned.                       |
| `enabled`          | `true`  | When false, the worker never starts; enqueue-only mode.         |

---

## Example — a webhook delivery handler

`Webhook::Dispatcher` (`src/webhook/dispatcher.cr`) shows the full handler
contract: pure transport, one `Result` per code path, and the attempt hooks
as the write side of the `webhook_calls` call log.

```crystal
class Facet::Webhook::Dispatcher < Facet::Jobs::Handler
  KIND = "webhook_delivery"

  def self.default_max_attempts : Int32
    Facet::Config.instance.webhook.max_attempts
  end

  def self.default_backoff : Array(Int32)
    Facet::Config.instance.webhook.backoff_seconds
  end

  # Pure transport: sign, POST, map the outcome. Never raises.
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    payload = Payload.from_json(job.payload.to_json)
    # ... build the signed request and POST it ...
    if response.status.success?
      Result.new(status: Kind::Succeeded, http_status: response.status.code)
    else
      Result.new(status: Kind::Failed, http_status: response.status.code)
    end
  rescue ex : Exception
    Result.new(status: Kind::Failed, error: ex.message)
  end

  # attempt_started / attempt_finished / attempt_abandoned / prune_expired
  # write the webhook_calls log — see the Webhooks doc.
end
```

Registration and enqueue:

```crystal
jobs_manager = Facet::Jobs::Manager.new
jobs_manager.register_handler(Facet::Webhook::Dispatcher::KIND, Facet::Webhook::Dispatcher)
jobs_manager.start

job_id = Facet::Jobs::Manager.instance.try do |mgr|
  mgr.enqueue("webhook_delivery", payload_json)
end
```

---

## Specs

`spec/jobs/` covers the pieces: `queries_spec.cr` (claim locking,
retry policy, sweep, owner resolution, prune), `worker_spec.cr`
(loop lifecycle, hooks, outcomes, owner-liveness sweep),
`handler_spec.cr` (defaults, hook contracts), `manager_spec.cr`
(singleton, registration, enqueue-only mode), and `liveness_spec.cr`
(key format, Redis fail-open).
