# Logging

Application logging — one explicit, config-driven setup for every entry point (server and CLI).

## Source files

- `src/logging.cr` — `Facet::Logging`: `setup`, the JSON and text formatters
- `src/config.cr` — the `logs:` section (`LogsConfig`, `load_logs`)
- `src/main.cr` — the call site (`CLI.run`) and the Redis URL hygiene rule

## The problem this solves

The `shrine` shard calls `Log.setup_from_env` at require time (`lib/shrine/src/shrine.cr`). `src/artifact/uploader.cr` requires shrine, and every entry point requires the artifact code — so the whole app inherited an env-driven setup nobody owned: level from `LOG_LEVEL` (default `info`), stdlib `Log::ShortFormat` to STDOUT, all sources. A bare Crystal program with no setup prints nothing, so all logging hung on that one transitive shard call — a shrine upgrade could silently remove it.

`Facet::Logging.setup` is the app's own binding. It runs from `CLI.run` (after the command list is resolved, before dispatch), requires the app code first — so shrine's require-time setup lands first — and then replaces it: `Log.setup` clears the builder before binding, so the explicit setup always wins. Kemal's request logs ride the same binding (Kemal logs through `Log` and does not call `Log.setup` itself).

## Config

The optional `logs:` section of `config.{env}.yml` (defaults shown):

```yaml
logs:
  format: text   # "text" (stdlib short format) or "json" (one JSON object per line)
  level: info    # trace | debug | info | notice | warn | error | fatal
```

Both keys are validated at load — an unknown value raises `ArgumentError` and stops the boot (fail loud, same pattern as the mail adapter gate). The section is absent in `config.test.yml`; the defaults apply.

**`LOG_LEVEL` no longer affects the app process** (config-only level — one source of truth). Shrine still reads it first at require time; the explicit setup then replaces the binding.

## JSON format

One JSON object per line:

```json
{"ts":"2026-10-01T07:52:32Z","level":"INFO","source":"facet.jobs.manager","message":"Jobs manager started (poll_interval_s: 5.0)"}
```

| Field | Content |
| --- | --- |
| `ts` | Entry timestamp, RFC-3339 UTC |
| `level` | Severity label (`INFO`, `WARN`, …) |
| `source` | Log source (e.g. `facet.jobs.manager`, `kemal`); empty for the root source |
| `message` | The entry message |
| `exception` | Object `{class, message}` — only when the entry carries an exception |
| `context` | The fiber-local `Log` context — only when non-empty (`require "log/json"` form) |

No backtrace field — error state is carried by traces (see [`telemetry.md`](telemetry.md)).

## Sources

Application code logs under `facet.*` (`Log = ::Log.for("facet.…")` per module); Kemal logs under the `kemal` source. The setup binds `*` (all sources) at the configured level — the same surface shrine's binding had.

## Log capture in specs

Specs never call `CLI.run`, so the spec suite keeps the require-time (shrine) setup — spec log output is unchanged. Two deliberate exceptions live in the spec tree:

- `spec/dev/domain_watcher_spec.cr` binds a capture backend on the process-wide `Log.builder` in `before_suite`. Because `Log.setup` clears every binding on its target builder, spec code that exercises logging must use an isolated `Log::Builder` (see `spec/logging_spec.cr`) instead of re-binding the global one.
- `spec/shutdown_spec.cr` binds a capture `Log::IOBackend` on the process-wide `Log.builder` for the two shutdown sources (`facet.shutdown`, `facet.websocket.manager`) and removes the binding in its teardown. It uses the **sync dispatcher**: the default async dispatcher queues entries on a background fiber, and the example asserts on the buffer right after the SIGTERM — the entries must be on the buffer before the assertions run.

## Hygiene rule

Log lines must never print credentials. The Redis URL may carry auth (`redis://:password@host`); the event-manager startup line logs `host:port/db` (built from the parsed URI), not the raw URL.
