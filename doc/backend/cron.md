# Cron

Cron concern — parses cron expressions and fires registered tasks at their next cron-computed instant via a single-loop scheduler fiber with once-per-cluster tick leases.

**Source files:** `src/cron.cr`, `src/cron/parser.cr`, `src/cron/scheduler.cr`, `src/cron/tasks.cr`, `src/cron/list_cli.cr`

---

## Parser

`Facet::Cron::Parser` is a thin wrapper over the [`cron_parser`](https://github.com/kostya/cron_parser) shard. The expression is validated eagerly in `CronParser.new`, so an invalid cron string raises `ArgumentError` at construction.

Supported syntax: 5-field (`min hour dom mon dow`), 6-field (`sec min hour dom mon dow`), and Vixie-style aliases (`@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`). `@reboot` is rejected — it has no predictable next/last instant.

| Method                                | Returns | Notes                                            |
| ------------------------------------- | ------- | ------------------------------------------------ |
| `Parser.new(expression : String)`     | `Parser`| Raises `ArgumentError` on a malformed expression|
| `#next(from : Time = Time.utc)`       | `Time`  | Next fire time strictly after `from`             |
| `#last(from : Time = Time.utc)`       | `Time`  | Previous fire time strictly before `from`       |
| `#expression`                         | `String` | The raw expression passed to the constructor     |

```crystal
parser = Facet::Cron::Parser.new("30 5 * * *")
parser.next(Time.utc(2024, 1, 1, 0, 0, 0)) # => 2024-01-01 05:30:00 UTC
```

---

## Scheduler

`Facet::Cron::Scheduler` runs one loop fiber under `Util::FiberSupervisor` — a raise that escapes the loop body (task fibers rescue their own errors) restarts the loop after a backoff and counts on `facet_fiber_restarts_total`. The loop sleeps until the earliest task is due, or is woken early by a registry change (register/unregister/stop) through a signal channel. When a task is due, it fires in its own fiber so a slow or failing task never blocks the loop or sibling tasks.

A failing task fiber logs an error via `Log.for("facet.cron.scheduler")` and the scheduler keeps running. This mirrors the `Event::Manager.dispatch_message` fault-isolation pattern.

### Lifecycle

| Method                                          | Effect                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| `Scheduler.new(clock : Proc(Time) = ->{ Time.utc }, acquire_lease : Proc(String, Int32, String, Bool)? = nil, service_id : String = "facet-cron")` | Constructs with an empty task registry. `clock` is injectable for deterministic tests. `acquire_lease` wires the once-per-cluster tick lease (nil disables — see below). |
| `#start`                                        | Spawns the loop fiber. Idempotent.                                 |
| `#stop`                                         | Closes the signal channel; the loop exits on its next `select` turn. Idempotent. In-flight task fibers are not awaited or cancelled. |
| `#register(id, expression, &block)`            | Adds or replaces a task by `id`; wakes the loop. Returns the computed `next_run`. |
| `#unregister(id)`                               | Removes a task by `id`, if present; wakes the loop. Returns `true` if removed. |
| `#running?`                                     | `true` while the loop fiber is running.                           |
| `#tasks`                                        | The registry, kept sorted by `next_run`.                          |
| `#in_flight`                                    | Ids of the tasks whose block fiber is currently running — the loop never awaits them (see `#stop`), so this is the only view of dispatches still unwinding. |

### Reschedule semantics

When a task is dispatched, its `next_run` is advanced synchronously — before the block runs — via `Parser#next(now)`, where `now` is the fire time captured at dispatch, not the scheduled instant. A delayed firing therefore advances the next run from the actual fire time and does not queue a catch-up storm. Because the advance happens before the block runs, the loop can never observe a stale due task: a slow task is dispatched exactly once per instant, and a task removed with `#unregister` while its block is in flight stays unregistered.

### `now_provider` / determinism

The scheduler reads the current time through the injected `clock` proc on every iteration. Tests pass a closure over a mutable cell so they can advance time past a task's `next_run` without sleeping wall-clock minutes.

### Once-per-cluster tick lease

When the wiring passes a lease acquirer, every dispatch first leases the task's scheduled tick via `SET cron:lease:{task_id}:{tick.to_unix} owner NX EX` (owner = the boot's `Facet::Service` id). The first instance to dispatch a tick wins and fires; every other instance skips the fire (debug log, `facet_cron_task_lease_skips_total` counter) — a tick runs exactly once across the cluster. The tick is baked into the key (the same scheme the domain-hooks lease uses), so a lease can never alias a different fire moment. The TTL (`Cron::Scheduler::LEASE_TTL_S`, 120 s) covers only the dispatch jitter between instances — not the task duration: the key auto-expires, and the next tick leases its own key. A Redis error skips the fire too (fail-close): the next tick re-arms, and a lost maintenance pass is safer than a duplicated one. Without an acquirer the scheduler fires unconditionally — the shape specs drive; production passes `Cron::Lease.redis_acquirer` (`src/cron/lease.cr`).

```crystal
scheduler = Facet::Cron::Scheduler.new
scheduler.start

next_run = scheduler.register("cleanup", "0 3 * * *") do
  # nightly cleanup at 03:00 UTC
end

scheduler.stop
```

---

## Wiring

The scheduler is instantiated and started in `Facet::CLI.run_server` (`src/main.cr`) alongside the other long-lived fibers, wired with `Cron::Lease.redis_acquirer` as the tick-lease acquirer so a tick fires exactly once across backend instances. It is stopped in the `at_exit` block. The domain-hooks subsystem runs its own poll loop (`Hooks::Scheduler`) — with its own lease design — and does not register tasks with `Facet::Cron::Scheduler`. Eight tasks are boot-registered from the table in `Cron::Tasks.boot_entries` (`src/cron/tasks.cr`), each with its schedule from config:

| Task id | Service | Schedule key | Purpose |
|---|---|---|---|
| `sidecar.reconcile` | `Cron::SidecarReconcile` | `sidecar.reconcile_cron` | Re-enqueue orphaned sidecar sweeps |
| `tombstone.content_prune` | `Cron::TombstoneContentPrune` | `tombstone.prune_cron` | Clear tombstone payloads after retention (ages on `projections.deleted_at`) |
| `secrets.prune` | `Cron::SecretsPrune` | `secrets.prune_cron` | Drop expired secret slots |
| `assistant.turn_sweep` | `Cron::AssistantTurnSweep` | `assistant.turn_sweep_cron` | Mark stale `running` agent turns `interrupted` |
| `assistant.usage_prune` | `Cron::AssistantUsagePrune` | `assistant.usage_prune_cron` | Delete `assistant_usage` ledger rows of conversations quiet past the retention window (see [`workspace-assistant.md`](workspace-assistant.md) → Usage ledger) |
| `mutations.compaction` | `Cron::MutationCompaction` | `mutations.compaction_cron` | Replace pre-retention mutations with one compaction snapshot (see [`mutation.md`](mutation.md) → Retention compaction) |
| `webhook.reconcile` | `Cron::WebhookReconcile` | `webhook.reconcile_cron` | Repair the webhook enqueue hop from the `mutations` log (see [`webhook.md`](webhook.md) → Reconciler) |
| `event.lag_check` | `Cron::EventLagCheck` | `event.lag_check_cron` | Read consumer-group lag and warn before trim loss (see [`event.md`](event.md) → Consumer-lag check) |

---

## `facet cron:list`

`Facet::Cron::ListCLI` (`src/cron/list_cli.cr`) prints the boot task table — one row per task with the id, the config key that owns the schedule, the expression, and the next fire time computed from the current time (UTC). The command reads config only — no database, no Redis — so it runs offline and chains with other commands (see [`cli.md`](cli.md)).

An expression the parser refuses marks its row and the command exits 1. The server refuses to boot on the same error — `Scheduler#register` builds a `Parser`, which validates at construction — so the listing must not answer 0 while the config holds one.

---

## Task logging

`Cron.run_pass` (`src/cron/pass.cr`) is the shared wrapper for the retention
and sweep passes. One call opens a pooled read-write connection, runs the
work block, and logs one completion line:

```
<label> pass complete: N row(s) touched
```

The line logs at INFO whenever the pass touched rows. A zero-work pass logs
too when the task keeps the heartbeat (`log_zero`, the default) — the daily
retention passes do: mutation compaction, secrets prune, tombstone content
prune, and assistant usage prune. For these the line is the "this ran"
marker. The assistant turn sweep passes `log_zero: false`: it runs often,
so a quiet sweep stays out of the log. A pass whose config disables it logs
one INFO line that names the setting (for example
`mutations.retention_days = 0`) and touches nothing.

Two tasks keep their own completion lines and log only on work done:
sidecar reconcile (`N orphan(s) tombstoned`) and webhook reconcile
(`N delivery job(s) enqueued`). A quiet pass stays silent there; webhook
reconcile logs one INFO line when the webhook manager is not installed.
The event-lag check logs no completion line — it warns when a consumer group
lags and logs an error when the check itself fails (see
[`event.md`](event.md) → Consumer-lag check).

Failures log twice by design: `run_pass` logs `<label> pass failed: …` at
ERROR and re-raises, and the scheduler's task fiber then logs
`Cron task <id> raised: …` and counts `facet_cron_task_failures_total`.
A dispatch that loses the tick lease logs at DEBUG and counts
`facet_cron_task_lease_skips_total`. Both counters carry the `task` label
and sit on `/metrics` (see [`metrics.md`](metrics.md)).
