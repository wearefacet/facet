# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── CLI command registry ───────────────────────────────────────────────────
# One table drives the command surface. The code derives the help banner,
# the usage line for unknown commands, the option check, and dispatch from
# this table. To add a command, add one row.
#
# A row with `takes_options: true` consumes the rest of ARGV as its own
# options. Such a command must be last in a chain. The chain validator
# (`chain.cr`) reads the flag from the row to split a chain into steps
# before any command runs.
#
# The table is an array, not a hash. Crystal hash iteration order is
# undefined. The derived help text needs a stable order.
module Facet
  class CLI
    # One command row. `help` is the text on the help banner.
    # `takes_options` is true when the command parses the trailing
    # arguments as its own options. `handler` runs the command and returns
    # the process exit code.
    record Entry,
      name : String,
      help : String,
      takes_options : Bool,
      handler : Proc(Array(String), Int32)

    # Wraps a handler block into an `Entry`. The block form keeps implicit
    # `self` calls to the private helpers valid.
    private def self.command(name : String, help : String, takes_options : Bool, &block : Array(String) -> Int32) : Entry
      Entry.new(name, help, takes_options, block)
    end

    # The command table, in help-banner order.
    private def self.commands : Array(Entry)
      [
        command("server", "Start the HTTP server (default; long-running, must be last in a chain)", false) do |_trailing|
          run_server
          0
        end,
        command("migrate", "Run database migrations", false) do |_trailing|
          Facet::Database.init
          Facet::Migrate.run
          Facet::Database.close
          0
        end,
        command("migrate:down", "Revert applied migrations (run standalone to pass a target)", true) do |trailing|
          # No `Database.init` — `Migrate.down` opens its own connection, so
          # `--help` works without a reachable database.
          Facet::Migrate::DownCLI.run(trailing)
        end,
        command("db_reset", "Drop, recreate and migrate the database (asks to confirm; --yes skips)", false) do |trailing|
          # `Migrate.db_reset` owns its own singleton-pool lifecycle: it must
          # close any pre-existing pool *before* `DROP DATABASE` (which kills
          # the pooled backends), and re-init it *after* migrations so the
          # spawning index fibers don't check out stale connections. Do NOT
          # wrap it in `Database.init` / `Database.close` here.
          # `DbResetCLI` parses the command's own flags (`--yes`) from the
          # dash tokens the chain validator hands over, then runs the
          # confirmation gate and the destructive workflow.
          Facet::Migrate::DbResetCLI.run(trailing)
        end,
        command("seed:core", "Seed core doctypes and the currency registry (idempotent, non-destructive)", false) do |_trailing|
          # `Migrate.seed_core` owns its own singleton-pool lifecycle, like
          # `db_reset` — do NOT wrap it in `Database.init` / `Database.close`.
          Facet::Migrate.seed_core
          0
        end,
        command("index:retry", "Retry failed index creations (run standalone to pass options)", true) do |trailing|
          # `RetryCLI.run` owns the database pool lifecycle: it parses the
          # options first (so `--help` works without a reachable database),
          # then `Database.init` / `Database.close` around the retry pass.
          # The return value is the process exit code.
          Facet::Index::RetryCLI.run(trailing)
        end,
        command("artifacts:prune", "Soft-delete (or --hard delete) artifacts with no live owner or recent reference", true) do |trailing|
          Facet::Artifact::PruneCLI.run(trailing)
          0
        end,
        command("artifacts:reconcile", "Delete orphaned objects from the artifact store (run standalone to pass options)", true) do |trailing|
          Facet::Artifact::ReconcileCLI.run(trailing)
          0
        end,
        command("artifacts:revoke", "Revoke every signed URL for an artifact (run standalone to pass the artifact id)", true) do |trailing|
          Facet::Artifact::RevokeCLI.run(trailing)
          0
        end,
        command("accounts:list", "List accounts (id, email, display name, status, roles)", false) do |_trailing|
          list_accounts
        end,
        command("accounts:create", "Create an account and print a one-time password (run standalone to pass email and options)", true) do |trailing|
          create_account(trailing)
        end,
        command("roles:list", "List roles (id, name)", false) do |_trailing|
          list_roles
        end,
        command("roles:add", "Assign a role to an account (run standalone to pass account and role)", true) do |trailing|
          add_role(trailing)
        end,
        command("auth:mode", "Pin the authentication mode on the SystemSettings document (run standalone: facet auth:mode {hybrid|oidc_only})", true) do |trailing|
          Facet::IAM::AuthModeCLI.run(trailing)
        end,
        command("seed:dev", "Seed the dev admin (admin@example.tld / admin, refused when APP_ENV=production)", false) do |_trailing|
          seed_dev
        end,
        command("seed:admin", "Create the first admin with a generated one-time password (run standalone to pass the email)", true) do |trailing|
          seed_admin(trailing)
        end,
        command("domain:export", "Export a domain definition to a directory or .tar.gz (run standalone to pass options)", true) do |trailing|
          Facet::Domain::Portable::CLI.run_export(trailing)
        end,
        command("domain:import", "Import a domain definition from a directory or .tar.gz (run standalone to pass options)", true) do |trailing|
          Facet::Domain::Portable::CLI.run_import(trailing)
        end,
        command("doctype:reproject", "Re-project a doctype's search/links/display_name columns for every live document", true) do |trailing|
          Facet::Doctype::ReprojectCLI.run(trailing)
        end,
        command("doctype:migrate-retry", "Re-run lazy migration for documents blocked by a meta.migration_error marker", true) do |trailing|
          Facet::Doctype::MigrationRetryCLI.run(trailing)
        end,
        command("cron:list", "List the boot cron tasks (id, config key, schedule, next run)", false) do |_trailing|
          # Config only — no database pool lifecycle, no Redis. The
          # expressions were already read into the table; the next-run
          # cells come from the same parser the scheduler registers with.
          Facet::Cron::ListCLI.run(Facet::Cron::Tasks.boot_entries)
        end,
      ]
    end

    # Finds a command row by name.
    private def self.find_command(name : String) : Entry?
      commands.find { |candidate| candidate.name == name }
    end

    # Runs one command. Returns the process exit code (0 on success).
    # `trailing` holds the arguments that follow the command name. An
    # unknown command prints the usage line and returns exit code 1.
    #
    # After the command runs, this publishes the events it buffered — see
    # `publish_buffered_events`.
    private def self.dispatch(command : String, trailing : Array(String) = [] of String) : Int32
      entry = find_command(command)
      if entry
        code = entry.handler.call(trailing)
        code = 1 unless publish_buffered_events
        code
      else
        puts "Unknown command: #{command}"
        puts "Usage: facet [#{commands.map(&.name).join("|")}]"
        1
      end
    end

    # Publishes the events the command buffered. Document mutations enqueue
    # into the fiber-local publisher queue; the HTTP routes flush it after
    # each transaction. A CLI process has no boot-time event manager and
    # exits right after the command, so an unflushed queue is a silent
    # loss — running servers keep stale caches until the staleness bound,
    # and no stream consumer ever sees the mutation (the core of QA
    # finding B-135: `facet auth:mode` wrote the document but no server
    # refreshed its policy). One flush point here covers every current and
    # future mutating command.
    #
    # Fails loud: a publish failure returns `false`, which turns the
    # command's exit code to 1. The DB write stands (it is committed), and
    # the staleness bound still converges the caches — but the operator
    # must see that publication did not happen.
    private def self.publish_buffered_events : Bool
      return true if Event::Publisher.pending_count.zero?

      Event::Publisher.ensure_config_manager
      Event::Publisher.flush!
      true
    rescue e : Exception
      puts "Error: the command ran, but publishing its events failed: #{e.message}"
      false
    end

    # Writes one help line per command. The name column spans the longest
    # command name plus two spaces.
    private def self.write_command_help(io : IO) : Nil
      width = commands.max_of(&.name.size) + 2
      commands.each do |entry|
        io.puts "  #{entry.name.ljust(width)}#{entry.help}"
      end
    end

    # ── Command handlers ───────────────────────────────────────────────────

    # Dev bootstrap only: the known default credential with
    # `must_change_pw: false` must never land on a deployed instance.
    private def self.seed_dev : Int32
      if refusal = Facet::IAM::Seed.dev_seed_refusal
        puts "Error: #{refusal}"
        return 1
      end

      # CLI seeding commands use synchronous inline `CREATE INDEX` (no
      # `CONCURRENTLY`) to avoid the deadlock/hang loop that the concurrent
      # path produces here: `Seed.seed` creates doctypes via
      # `Doctype::Create`, which calls `Index::Manager.sync`. In the
      # default concurrent mode that spawns background fibers running
      # `CREATE INDEX CONCURRENTLY`, which (a) take a SHARE lock on
      # `projections` that deadlocks against the seeding writes, and
      # (b) keep checked-out connections when `Database.close` runs at
      # the end of the command, hanging the process. The seeding step is
      # a one-shot dev/CLI workflow — it does not need the non-blocking
      # semantics that the HTTP path requires. See `Index::Manager.synchronous?`.
      # The flag is reset by `run_server` so a chained `... server` does
      # not inherit it.
      Facet::Index::Manager.synchronous = true

      Facet::Database.init
      Facet::Database.with_db do |db|
        Facet::IAM::Seed.seed_dev_admin(db)
      end
      # Synchronous mode means no background fibers are in flight, so
      # `wait_for_pending_fibers` is a no-op here — but `retry_all` is
      # still useful: an inline `CREATE INDEX` may fail (e.g., on a
      # pre-existing INVALID index from a previous interrupted run) and
      # row-level retry re-applies it on a quiet table.
      drain_index_ddl_and_close
      0
    end

    # Runs `seed:admin`. Owns the database pool lifecycle. The CLI module
    # resolves the email, seeds, and prints the one-time password.
    private def self.seed_admin(trailing : Array(String)) : Int32
      Facet::Database.init
      code = Facet::IAM::SeedCLI.seed_admin(trailing)
      Facet::Database.close
      code
    end

    # Lists accounts. Owns the database pool lifecycle.
    private def self.list_accounts : Int32
      Facet::Database.init
      Facet::IAM::AccountCLI.list_accounts
      Facet::Database.close
      0
    end

    # Lists roles. Owns the database pool lifecycle.
    private def self.list_roles : Int32
      Facet::Database.init
      Facet::IAM::AccountCLI.list_roles
      Facet::Database.close
      0
    end

    # Adds a role to an account. Owns the database pool lifecycle.
    private def self.add_role(trailing : Array(String)) : Int32
      Facet::Database.init
      Facet::IAM::AccountCLI.add_role(trailing)
      Facet::Database.close
      0
    end

    # Creates an account. Owns the database pool lifecycle.
    private def self.create_account(trailing : Array(String)) : Int32
      Facet::Database.init
      code = Facet::IAM::AccountCLI.create_account(trailing)
      Facet::Database.close
      code
    end
  end
end
