# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Process-wide UTC pin ────────────────────────────────────────────────────
# Every timestamp column is tz-naive and stores UTC; the codebase uses only
# `Time.utc`. Pinning TZ makes an accidental `Time.local` resolve to UTC
# instead of the host zone, so a non-UTC Time can never be bound to SQL —
# PostgreSQL would silently drop the offset when casting it into a naive
# column. Must run before anything that could touch `Time.local`.
ENV["TZ"] = "UTC"

require "option_parser"
require "kemal"
require "http/params"
require "./database"
require "./http/server"
require "./migrate"
require "./event"
require "./doctype/seed"
require "./iam/account_cli"
require "./iam/seed_cli"
require "./iam/auth_mode_cli"
require "./rbac"
require "./audit"
require "./index/retry_cli"
require "./artifact/prune"
require "./artifact/purge"
require "./artifact/reconcile"
require "./artifact/revoke"
require "./telemetry"
require "./logging"
require "./metrics"
require "./websocket"
require "./replication"
require "./hooks"
require "./webhook"
require "./notifications"
require "./jobs"
require "./domain/portable"
require "./cron"
require "./cron/sidecar_reconcile"
require "./cron/tombstone_content_prune"
require "./cron/assistant_turn_sweep"
require "./cron/assistant_usage_prune"
require "./cron/secrets_prune"
require "./cron/mutation_compaction"
require "./cron/webhook_reconcile"
require "./cron/event_lag_check"
require "./cron/tasks"
require "./cron/list_cli"
require "./secrets"
require "./service"
require "./boot"
require "./shutdown"
require "./currency"
require "./import_export/csv_serializer"
require "./import_export/export"
require "./import_export/import"
require "./import_export/export_job"
require "./import_export/import_job"
require "./import_export/routes"
require "./event/subscriber/sidecar_sweep"
require "./doctype/reproject_cli"
require "./doctype/migration_retry_cli"
require "./dev/config"
require "./dev/domain_watcher"
require "./cli/chain"
require "./cli/commands"

# ── Dotenv loader ──────────────────────────────────────────────────────
# Loads KEY=VALUE pairs from a `.env` file without pulling in a dependency,
# then from `.env.#{Service.app_env}`. Precedence: the real shell environment
# wins over both files; the environment-specific file overrides the base
# file and may also introduce new keys. Unset APP_ENV means "dev" — the
# same rule `Config.app_env` applies, so `.env.dev` loads whenever
# `config.dev.yml` does.
def load_dotenv : Nil
  # Keys present before any file loads. No dotenv file may override these.
  shell_keys = ENV.keys.to_set

  # Base file first, then the environment-specific file.
  load_dotenv_file(".env", shell_keys)
  load_dotenv_file(".env.#{Facet::Service.app_env}", shell_keys)
end

# Sets `KEY=VALUE` pairs from *path*. Keys captured in *shell_keys* are
# skipped — shell exports always win. The base file's keys are not in
# *shell_keys*, so the environment-specific file overrides them and can add
# keys the base file does not define.
private def load_dotenv_file(path : String, shell_keys : Set(String)) : Nil
  return unless File.exists?(path)

  File.read_lines(path).each do |line|
    line = line.strip
    next if line.empty? || line.starts_with?('#')

    if eq = line.index('=')
      key = line[0...eq].strip
      value = line[(eq + 1)..].strip
      ENV[key] = value unless shell_keys.includes?(key)
    end
  end
end

# The schema gate for the server boot. The first boot query reads
# `projections` (the currency-registry warm-up); on a database the
# migrations never built, that read dies with a raw PQError and a long
# backtrace. The probe answers a named, actionable error instead (B-205).
private def require_migrated(db : DB::Connection) : Nil
  present = db.query_one("SELECT to_regclass('projections') IS NOT NULL", as: Bool)
  raise "database not migrated — run facet migrate" unless present
end

load_dotenv

# ── CLI ────────────────────────────────────────────────────────────────────
module Facet
  class CLI
    def self.run
      # Process global flags first (e.g. --help). Non-option arguments are
      # left in ARGV and treated as the command list below.
      #
      # `before_each` + `stop` halt the parser at the first positional
      # argument (the command name), so a subcommand's own options are
      # never consumed by this global parser and `--help` reaches the
      # subcommand's own parser.
      OptionParser.parse do |parser|
        parser.banner = String.build do |io|
          io.puts "Usage: facet <command> [command ...]"
          io.puts
          io.puts "Multiple commands may be chained and executed in order, e.g.:"
          io.puts "  facet db_reset seed:dev"
          io.puts
          io.puts "A dash argument after a command belongs to that command, e.g.:"
          io.puts "  facet db_reset --yes seed:dev"
          io.puts
          io.puts "Commands:"
          write_command_help(io)
          io.puts
          io.puts "Options:"
        end

        parser.on("-h", "--help", "Show help") do
          puts parser
          exit 0
        end

        parser.before_each do |_arg|
          # `before_each` fires for non-flag arguments (i.e. positionals).
          # The first positional is the command name — stop here so the
          # command's own options (starting with the next arg) stay in
          # ARGV for the subcommand parser to consume.
          parser.stop
        end
      end

      # All remaining positional arguments are commands, run in order.
      # `ARGV.to_a` returns ARGV itself (not a copy), so `dup` is required
      # before `ARGV.clear` mutates the snapshot.
      commands = ARGV.dup
      ARGV.clear
      commands = ["server"] if commands.empty?

      # Explicit, config-driven logging. Runs after the command list is
      # resolved (so `--help` still prints without a config file) and
      # before any command dispatch — one place covers `server` and every
      # CLI command. `CLI.run` requires the app code first, so shrine's
      # require-time `Log.setup_from_env` binds before ours; `Log.setup`
      # clears the builder and replaces that binding. See
      # `doc/backend/logging.md`.
      Facet::Logging.setup(Facet::Config.instance.logs)

      # The dev-adapter mail warning fires here, after the log binding
      # installs — never during the config load inside the `Logging.setup`
      # expression above: at load time the configured formatter does not
      # exist yet, so the warning would bypass `logs.format` as one
      # non-JSON line per boot. See `doc/backend/config.md`.
      Facet::Config.warn_dev_mail_adapter_once

      # `server` blocks forever (Kemal.run). If it appears in a chain it must
      # be the last command, otherwise later commands would never execute.
      if commands.size > 1 && commands.includes?("server") && commands.last != "server"
        puts "Error: 'server' is long-running and must be the last command in a chain."
        puts "Usage: facet <command> [command ...]"
        exit 1
      end

      # Validate the whole chain BEFORE any command runs. An unknown bare
      # token (e.g. a misspelled command after `db_reset`) must fail the
      # run before the first — possibly destructive — command executes.
      steps = validated_chain(commands)

      # Run the validated steps in order. During validation an
      # option-taking command (e.g. `facet artifacts:prune --hard`) already
      # consumed the rest of the list as its own options, so its step is
      # always the last one. A chainable command's step carries only its
      # own dash flags (e.g. `--yes`); the bare tokens became the following
      # steps.
      steps.each do |step|
        puts "\n== facet #{step.name} ==" unless commands.size == 1
        code = dispatch(step.name, step.flags)
        exit code unless code.zero?
      end
    end

    # Validates the command chain for `run` and returns the steps to
    # execute. On an unknown bare token prints the same message `dispatch`
    # uses and exits 1 — nothing has executed yet.
    private def self.validated_chain(tokens : Array(String)) : Array(ChainStep)
      parse_chain(
        tokens,
        commands.map(&.name),
        commands.select(&.takes_options).map(&.name),
      )
    rescue e : ChainError
      puts e.message
      puts "Usage: facet [#{commands.map(&.name).join("|")}]"
      exit 1
    end

    # Drains any in-flight `Index::Manager` background DDL fibers spawned
    # by seeding commands before closing the singleton pool, then retries
    # any index rows that errored. The seeding command (`seed:dev`) sets
    # `Index::Manager.synchronous = true`, so normally no fibers are in
    # flight and `wait_for_pending_fibers` is a no-op — but the call is
    # kept as a defensive net so the helper stays correct even if a future
    # caller disables synchronous mode. The retry pass runs quiet: it
    # prints nothing when no row is retryable. Mirrors the drain+retry
    # pattern in `Migrate.db_reset`.
    private def self.drain_index_ddl_and_close : Nil
      unless Facet::Index::Manager.wait_for_pending_fibers
        Log.for("facet.cli").warn do
          "Background index fibers did not drain within the timeout — " \
          "some indexes may be left in 'pending' status; run `facet index:retry` to finish them."
        end
      end

      Facet::Database.with_db(:read_write) do |db|
        Facet::Index::RetryCLI.retry_all(db, quiet: true)
      end

      Facet::Database.close
    end

    private def self.run_server
      # Defensive: reset synchronous mode to its production default. A
      # chaining caller (e.g. `bin/facet db_reset seed:dev server`) would
      # otherwise inherit the synchronous=true flag set by the seeding
      # command, which is wrong for the HTTP path — production requires
      # `CREATE INDEX CONCURRENTLY` + background fibers so doctype mutations
      # do not block HTTP responses.
      Facet::Index::Manager.synchronous = false

      # Trap the termination signals before anything starts, so a SIGTERM
      # during boot also exits cleanly instead of dying on the default
      # disposition. The handler drains HTTP (Kemal.stop + WebSocket close
      # frames); the ordered subsystem teardown below runs from `at_exit`.
      Facet::Shutdown.install

      # Teardown slots. The `at_exit` block is registered before any
      # subsystem starts so a termination request during boot tears down
      # whatever has started so far; each slot is assigned as its subsystem
      # comes up. The closure must only ever reference the slots — a local
      # captured by a closure never flow-narrows, so the boot code below
      # keeps its own non-captured variables and mirrors them into the
      # slots.
      event_manager_slot : Facet::Event::Manager? = nil
      cache_subscribers_slot : Array(Facet::Boot::CacheSubscriber)? = nil
      replication_manager_slot : Facet::Replication::Manager? = nil
      hooks_manager_slot : Facet::Hooks::Manager? = nil
      sidecar_sweep_manager_slot : Facet::Event::Subscriber::SidecarSweep::Manager? = nil
      webhook_manager_slot : Facet::Webhook::Manager? = nil
      jobs_manager_slot : Facet::Jobs::Manager? = nil
      ws_manager_slot : Facet::Websocket::Manager? = nil
      cron_scheduler_slot : Facet::Cron::Scheduler? = nil
      dev_watcher_slot : Facet::Dev::DomainWatcher? = nil

      # Clean shutdown of all long-lived fibres on exit / signal. The order
      # is explicit: newest subsystems first, the base event manager last.
      # The cache subscribers stop in the order they started (doctype, app,
      # role). HTTP is drained before this runs — the shutdown handler
      # closes the listeners and the WebSocket sockets, then `Kemal.run`
      # waits for the in-flight requests. The database pool closes last.
      at_exit do
        Log.info { "graceful shutdown — stopping subsystems" }
        Facet::Shutdown.stop_quietly("dev domain watcher") { dev_watcher_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("cron scheduler") { cron_scheduler_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("jobs manager") { jobs_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("hooks manager") { hooks_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("webhook manager") { webhook_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("sidecar sweep manager") { sidecar_sweep_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("replication manager") { replication_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("cache subscribers") { cache_subscribers_slot.try(&.each(&.stop)) }
        Facet::Shutdown.stop_quietly("websocket fanout") { ws_manager_slot.try(&.stop) }
        Facet::Shutdown.stop_quietly("event manager") { event_manager_slot.try(&.stop) }
        # Background DDL fibers hold pooled connections; closing the pool
        # under them kills the CREATE INDEX mid-flight. Bound the wait — a
        # stuck index stays `pending` and `facet index:retry` finishes it.
        Facet::Shutdown.stop_quietly("index DDL drain") do
          unless Facet::Index::Manager.wait_for_pending_fibers(timeout: 5.seconds)
            Log.warn { "background index DDL fibers did not drain — run `facet index:retry` to finish them" }
          end
        end
        Facet::Shutdown.stop_quietly("database pool") { Facet::Database.close }
        Log.info { "graceful shutdown complete" }
      end

      # Initialize the connection pools before handling any requests. The
      # server process carries the configured `statement_timeout` on every
      # pooled session, and the optional `database.cluster` route table
      # (per-database pools, read-only enforcement). CLI entry points keep
      # no timeout and a single pool so long-running migration DDL and
      # reproject workers cannot be cancelled.
      Facet::Database.init(
        Facet::Config.instance.database.cluster,
        statement_timeout_ms: Facet::Config.instance.database.statement_timeout_ms,
      )

      # Initialize the event manager from config — Redis is required.
      # One instance id per boot (`Facet::Service`): every manager and
      # subscriber derives its service id from it, so two instances of one
      # environment never share a lock or liveness identity.
      app_env = Facet::Service.app_env
      Log.info { "Service instance #{Facet::Service.instance_id} (env: #{Facet::Service.app_env})" }
      event_config = Facet::Config.instance.event
      event_manager = Facet::Event::Manager.new(
        config: event_config,
        service_id: Facet::Service.service_id("facet"),
      )
      Facet::Event::Publisher.manager = event_manager
      event_manager_slot = event_manager
      # The URL may carry auth (`redis://:password@host`). Log host, port,
      # and database index only — never the userinfo.
      redis_uri = URI.parse(event_config.url)
      Log.info { "Event manager initialized with Redis at #{redis_uri.host || "localhost"}:#{redis_uri.port || 6379}#{redis_uri.path}" }

      # Start the general-purpose event manager — subscribes to resource
      # streams grouped by consuming domain. Independent of the WebSocket
      # Fanout (which is a Redis Pub/Sub path started by ws_manager below).
      event_manager.start

      # Swap the request-local doctype cache for a process-wide one so
      # that Pub/Sub-driven evictions are visible across fibers. See
      # `Doctype::DefinitionStore` and `Event::Subscriber::DoctypeCache`.
      Facet::Doctype::DefinitionStore.cache =
        Facet::Doctype::ProcessDefinitionCache.new

      # Same for the role-content cache: the RoleCache subscriber evicts the
      # mutated role's entry on every `iam.Roles` mutation; the staleness
      # bound (`cache.staleness_ttl_s`) is the lost-fanout backstop. Swapped
      # in before the subscribers start so no eviction lands on the
      # pass-through default. See `IAM::RoleStore`.
      Facet::IAM::RoleStore.cache =
        Facet::IAM::RoleStore::ProcessCache.new

      # Same for the OIDC provider registry: the OidcProviderCache
      # subscriber clears the enabled-provider list on every
      # `iam.OIDCProvider` mutation; the staleness bound
      # (`cache.staleness_ttl_s`) is the lost-fanout backstop. Swapped in
      # before the subscribers start so no eviction lands on the
      # pass-through default. See `IAM::OIDC::ProviderStore`.
      Facet::IAM::OIDC::ProviderStore.cache =
        Facet::IAM::OIDC::ProviderStore::ProcessCache.new

      # Start the three cache Pub/Sub subscribers BEFORE mounting HTTP
      # routes. Subscribe-before-fetch ordering is load-bearing: any
      # cache-owning mutation published after startup is observed, even
      # before any request has warmed the cache (doctype cache, OAuth
      # origin cache, MCP tools cache — in that order).
      cache_subscribers = Facet::Boot.start_cache_subscribers(event_config.url)
      cache_subscribers_slot = cache_subscribers

      # Schema gate before the first boot query: the currency-registry
      # warm-up below reads `projections`. On a database the migrations
      # never built, that read dies with a raw PQError; probe the table
      # first and name the remedy instead (B-205).
      Facet::Database.with_db(:read_only) do |db|
        require_migrated(db)
      end

      # Seed reconcile — the embedded corpus is the source of truth for
      # system doctypes. Definitions missing from the database are created
      # (a migrate-only bootstrap boots complete), definitions that drifted
      # from their seed file are updated through the schema-evolution
      # pipeline, and missing seed documents are created. Runs before the
      # currency warm-up so new `core.Currency` rows hydrate in the same
      # boot. Synchronous index DDL: system tables are small, and inline
      # DDL finishes before HTTP mounts (the `seed_core` pattern) — the
      # flag returns to the HTTP default right after.
      Facet::Index::Manager.synchronous = true
      seed_report = Facet::Database.with_db(:read_write) do |db|
        Facet::Doctype::Seed.seed_full(db)
      end
      Facet::Index::Manager.synchronous = false

      # The inline CREATE INDEX may fail on a pre-existing INVALID index
      # row — the row-level retry re-applies it (the `seed_core` pattern).
      # Quiet: the pass prints nothing when no row is retryable.
      Facet::Database.with_db(:read_write) do |db|
        Facet::Index::RetryCLI.retry_all(db, quiet: true)
      end

      # The reconcile enqueued doctype events on this boot fiber; the HTTP
      # layer never runs on it, so flush here. At-most-once, like every bus
      # delivery — a failed flush is counted on `Event::Loss`.
      Facet::Event::Publisher.flush

      unless seed_report.empty?
        Log.info do
          "Seed reconcile: created #{seed_report.created.join(", ")} — updated #{seed_report.updated.join(", ")}"
        end
      end

      # Warm the currency registry from the database. The DoctypeCache
      # subscriber (started above) marks it stale on every `core.Currency`
      # fanout; the write services re-hydrate on demand.
      Facet::Database.with_db(:read_only) do |db|
        Facet::Currency::Registry.ensure_fresh(db)
      end

      # Build & start the replication manager. Owns its own event manager
      # instance (consumer_group_prefix `cg:repl:`) plus the registry and
      # the source-event handler. Subscribes to source doctype streams
      # grouped by consuming domain.
      replication_manager = Facet::Replication::Manager.new(
        config: Facet::Config.instance,
        service_id: Facet::Service.service_id("facet-repl"),
      )
      # Boot starts the manager after the singleton is installed, so the
      # `DoctypeCache` Pub/Sub subscriber can invalidate the replication
      # registry via `Replication::Manager.instance.try(&.mark_registry_stale)`
      # on every `core.DocType` fanout event from the first event onward.
      # The next registry read rebuilds lazily from the DB — no eager
      # refresh on the doctype mutation paths.
      Facet::Replication::Manager.instance = replication_manager
      Facet::Boot.start_manager(replication_manager)
      replication_manager_slot = replication_manager

      # Build the hooks subsystem manager. Owns its own event manager
      # instance (consumer_group_prefix `cg:hooks:`), the registry, the
      # source-event handler, and the cron scheduler fiber. Subscribes to
      # source doctype streams grouped by owning domain; the scheduler reads
      # `Registry#schedule_hooks` on each poll. The `DoctypeCache` Pub/Sub
      # subscriber invalidates the registry via
      # `Hooks::Manager.instance.try(&.mark_registry_stale)` on every
      # `fanout:core.Domain:*` event; the next registry read rebuilds
      # lazily. OpenTelemetry spans are opened inside `Hooks::Executor`
      # (one span per hook fire).
      hooks_manager = Facet::Hooks::Manager.new(
        config: Facet::Config.instance,
        service_id: Facet::Service.service_id("facet-hooks"),
      )
      Facet::Hooks::Manager.instance = hooks_manager
      Facet::Boot.start_manager(hooks_manager)
      hooks_manager_slot = hooks_manager

      # Build & start the sidecar sweep manager. Owns its own event manager
      # instance (consumer_group_prefix `cg:sidecar:`) and subscribes to the
      # `deleted` event on every host doctype that declares a `sidecars` map.
      # A channel provider re-queries the host set on every stream poll so a
      # doctype create/update that adds or removes a `sidecars` entry is
      # reflected without a restart (same approach `Replication::Manager`
      # uses for source-doctype set changes).
      sidecar_sweep_manager = Facet::Event::Subscriber::SidecarSweep::Manager.new(
        event_config: event_config,
        service_id: Facet::Service.service_id("facet-sidecar-sweep"),
      )
      Facet::Database.with_db(:read_write) do |db|
        sidecar_sweep_manager.start(db)
      end
      sidecar_sweep_manager_slot = sidecar_sweep_manager

      # Build the webhook subsystem manager. Owns its own event manager
      # (consumer_group_prefix `cg:webhooks:`), the webhook registry, and
      # the source-event handler that enqueues webhook_delivery jobs. All
      # subscriptions are grouped under the single owning domain `core` —
      # webhooks live in core but consume their source doctypes' streams.
      # The `DoctypeCache` Pub/Sub subscriber invalidates the registry via
      # `Webhook::Manager.instance.try(&.mark_registry_stale)` on every
      # `fanout:core.Webhook:*` event; the next registry read rebuilds
      # lazily.
      webhook_manager = Facet::Webhook::Manager.new(
        config: Facet::Config.instance,
        service_id: Facet::Service.service_id("facet-webhook"),
      )
      Facet::Webhook::Manager.instance = webhook_manager
      Facet::Boot.start_manager(webhook_manager)
      webhook_manager_slot = webhook_manager

      # Build the background-jobs manager. Owns the poll-loop worker that
      # claims due rows from `background_jobs` and runs their handlers
      # (dispatch is the worker's flat kind → Handler map). With
      # `jobs.enabled: false` the worker never starts and the manager
      # stays in enqueue-only mode: rows are inserted, nothing claims
      # them. Installed as the process-wide singleton so subsystems can
      # enqueue via `Jobs::Manager.instance.try(&.enqueue(...))`.
      jobs_manager = Facet::Jobs::Manager.new
      Facet::Jobs::Manager.instance = jobs_manager
      jobs_manager_slot = jobs_manager
      # Register the webhook dispatcher into the Jobs::Manager handlers map
      # BEFORE start — the worker snapshots the map at start, so the
      # webhook_delivery kind is dispatchable from the first claim.
      webhook_manager.register_handler(jobs_manager)
      # Register the document import/export handlers and the portable-domain
      # handlers from the table. The kinds run with a per-row long lease (set
      # at enqueue) and `max_attempts: 1` — the handlers own their policy.
      job_handler_entries.each do |entry|
        jobs_manager.register_handler(entry.kind, entry.handler)
      end
      jobs_manager.start

      # Initialize OpenTelemetry
      Facet::Telemetry.init
      Log.info { "OpenTelemetry initialized (exporter: #{ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]? || "null"})" }

      # Build the WebSocket Manager — wraps the existing Subscriber::Fanout
      # as its pub/sub driver.
      ws_manager = Facet::Websocket::Manager.new(
        Facet::Event::Subscriber::Fanout.new(
          redis_url: event_config.url,
          service_id: Facet::Service.service_id("facet-ws"),
        ) do |channel, message|
          Facet::Websocket::Manager.instance.dispatch(channel, message)
        end
      )

      ws_manager.start
      Facet::Websocket::Manager.instance = ws_manager
      ws_manager_slot = ws_manager

      Facet::HTTP::Server.routes
      Facet::Websocket::Route.register

      # Start the cron scheduler. Owns a single loop fiber that fires
      # registered cron tasks in their own fibers. The boot tasks come from
      # `Cron::Tasks.boot_entries`; the domain-hooks subsystem runs its own
      # poll loop (`Hooks::Scheduler`) and never registers tasks here.
      # Every dispatch first leases the task's tick in Redis, so more than
      # one backend instance still fires a tick exactly once across the
      # cluster.
      cron_scheduler = Facet::Cron::Scheduler.new(
        acquire_lease: Facet::Cron::Lease.redis_acquirer(event_config.url),
        service_id: Facet::Service.service_id("facet-cron"),
      )
      Facet::Cron::Tasks.boot_entries.each do |entry|
        cron_scheduler.register(entry.id, entry.cron) { entry.task.call }
      end
      cron_scheduler.start
      cron_scheduler_slot = cron_scheduler

      # Start the dev domain watcher after the cron scheduler. The section
      # lives in config.dev.yml only; the boot code refuses to start the
      # watcher when the resolved environment is production, even if the
      # section is present. An initial scan + sync runs on the watcher's
      # first tick, so bundles that exist before boot are applied once the
      # server is ready.
      if Facet::Dev::DomainWatcher.allowed?(app_env) && (domain_watch = Facet::Config.instance.dev.domain_watch)
        dev_watcher = Facet::Dev::DomainWatcher.new(domain_watch)
        dev_watcher.start
        dev_watcher_slot = dev_watcher
        Log.info { "Dev domain watcher started on '#{domain_watch.path}' (documents: #{domain_watch.documents})" }
      end

      # `trap_signal: false` — the termination signals are handled by
      # `Facet::Shutdown` (installed above): it stops the listeners, closes
      # the WebSocket sockets with close frames, and lets `Kemal.run`
      # return so the `at_exit` teardown runs. Kemal's built-in trap would
      # only close the listeners and leave the drain wedged on every open
      # WebSocket socket (Kemal counts an open socket as in-flight).
      Kemal.run trap_signal: false
    end

    # One background-jobs handler row: the job kind and its handler class.
    record JobsHandlerEntry, kind : String, handler : Facet::Jobs::Handler.class

    # The background-jobs handlers registered at boot, in registration
    # order. The webhook dispatcher registers itself inside `run_server`.
    private def self.job_handler_entries : Array(JobsHandlerEntry)
      [
        JobsHandlerEntry.new(Facet::Document::ExportJob::KIND, Facet::Document::ExportJob),
        JobsHandlerEntry.new(Facet::Document::ImportJob::KIND, Facet::Document::ImportJob),
        JobsHandlerEntry.new(Facet::Domain::Portable::ExportJob::KIND, Facet::Domain::Portable::ExportJob),
        JobsHandlerEntry.new(Facet::Domain::Portable::ImportJob::KIND, Facet::Domain::Portable::ImportJob),
        JobsHandlerEntry.new(Facet::Doctype::ReprojectJob::KIND, Facet::Doctype::ReprojectJob),
        JobsHandlerEntry.new(Facet::Doctype::AheadMigrationJob::KIND, Facet::Doctype::AheadMigrationJob),
      ]
    end
  end
end

Facet::CLI.run
