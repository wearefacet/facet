# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "uri"
require "option_parser"
require "./database"
require "./index"
require "./doctype/seed"
require "./currency"

module Facet
  # Runs the SQL migrations embedded in the binary.
  #
  # Migration SQL files from `db/migrations/` are baked into the binary at
  # compile time (`MIGRATION_SOURCES`), so `migrate`, `migrate:down`, and
  # `db_reset` need no `db/` tree on disk. The directory stays the source
  # of truth; a changed migration file requires a rebuild (the Makefile
  # tracks the files as build dependencies).
  #
  # Migrations apply in filename order. Each file is expected to contain an
  # `-- UP` section (applied) and optionally a `-- DOWN` section (revert).
  # Already-applied migrations are tracked in a `_migrations` table and
  # skipped on subsequent runs. `migrate:down` (`DownCLI`) reverts applied
  # migrations through their `-- DOWN` sections.
  module Migrate
    # Embedded migration SQL, keyed by filename. Filled at compile time from
    # `db/migrations/*.sql` — the directory stays the source of truth.
    MIGRATION_SOURCES = {% begin %}
      {% files = `find #{__DIR__}/../db/migrations -maxdepth 1 -type f -name '*.sql' | sed "s|^.*/||" | LC_ALL=C sort`.lines.reject(&.empty?) %}
      {% raise "Facet::Migrate: no db/migrations/*.sql found at compile time" if files.empty? %}
      {
        {% for file in files %}
          {{ file }} => {{ read_file("#{__DIR__}/../db/migrations/#{file.id}") }},
        {% end %}
      }
    {% end %}

    # Splits a migration file into its `-- UP` and `-- DOWN` sections.
    #
    # The marker is a comment line on its own: `-- DOWN` followed by the line
    # end. The trailing `$` matters — without it, prose such as
    # `-- DOWN restores the function body …` in the file header matches, and
    # the `-- UP` section truncates to the header comments.
    SECTION_SPLIT_RE = /^--\s*DOWN[ \t]*$/im

    # Raised when a revert plan cannot be executed. Raised before any SQL
    # runs, so a failed plan leaves the database untouched.
    class DownError < Exception
    end

    # ── Public API ──────────────────────────────────────────────────────

    # Runs all pending migrations against the database pointed to by
    # `DATABASE_URL`.
    def self.run
      database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL environment variable is required") }

      puts "Connecting to database..."
      DB.open(database_url) do |db|
        ensure_migrations_table(db)

        filenames = migration_files

        if filenames.empty?
          puts "No migrations are embedded in this build"
          return
        end

        filenames.each do |filename|
          if migration_ran?(db, filename)
            puts "  SKIP #{filename} (already applied)"
            next
          end

          sql = MIGRATION_SOURCES[filename]

          # Extract only the UP section (everything before "-- DOWN")
          up_sql = up_section(sql)

          puts "  APPLY #{filename}..."
          exec_multi(db, up_sql)
          record_migration(db, filename)
          puts "  DONE  #{filename}"
        end

        puts "Migrations complete."
      end
    end

    # Reverts applied migrations by executing their `-- DOWN` sections.
    #
    # Without a `target`, reverts the single most recently applied migration.
    # With a `target` (full filename or its `NNNN` number prefix), reverts
    # every applied migration newer than the target — the target itself
    # stays applied. Migrations revert in reverse filename order, one
    # transaction per file: the `-- DOWN` statements and the deletion of the
    # migration's `_migrations` row commit together or not at all.
    #
    # The plan is fully validated before anything runs; an unknown target, a
    # target that is not applied, or a file with a missing or empty `-- DOWN`
    # section raises `DownError` and changes nothing. Without `yes`, the
    # revert plan is printed and confirmed on the terminal — stdin that is
    # not a TTY aborts the command, so scripted callers must pass `yes`.
    def self.down(target : String? = nil, yes : Bool = false) : Nil
      database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL environment variable is required") }

      DB.open(database_url) do |db|
        ensure_migrations_table(db)
        applied = applied_migrations(db)
        plan = revert_plan(target, applied)

        if plan.empty?
          puts "Nothing to revert."
          return
        end

        puts "Reverting #{plan.size} migration(s):"
        plan.each { |(filename, _)| puts "  #{filename}" }
        confirm!("migrate:down") unless yes

        plan.each do |filename, down_sql|
          puts "  REVERT #{filename}..."
          revert_one(db, filename, down_sql)
          puts "  DONE   #{filename}"
        end

        puts "Rollback complete."
      end
    end

    # Drops, recreates the database specified in `DATABASE_URL`, runs all
    # migrations from scratch, then seeds the core doctypes. Creates no
    # account — bootstrap the first admin with `facet seed:admin` (or the
    # dev credential with `facet seed:dev`, refused in production).
    #
    # Asks for confirmation before the drop unless `yes` — the same gate
    # `migrate:down` uses. Stdin that is not a terminal aborts the command
    # (scripted callers must pass `yes`, the CLI flag `--yes`), and any
    # answer but `y`/`yes` on the prompt aborts. The gate runs before any
    # destructive step, so a refusal changes nothing.
    #
    # Uses synchronous inline `CREATE INDEX` (no `CONCURRENTLY`) for the
    # seeded doctypes' index DDL — see `Index::Manager.synchronous?`. The
    # concurrent path deadlocks against the seeding writes (the background
    # `CREATE INDEX CONCURRENTLY` fibers take a SHARE lock on `projections`
    # that deadlocks against the admin-account insert) and may hang on pool
    # close. `db_reset` is a one-shot CLI workflow — it does not need the
    # non-blocking semantics that the HTTP path requires. Every other CLI
    # seeding command (`seed:dev`, `domain:import`, `domain:export`) sets the
    # same flag; `run_server` resets it to `false` so a chained `... server`
    # does not inherit it.
    #
    # Owns its own singleton-pool lifecycle: closes any pre-existing
    # `Facet::Database` pool at the start (so `DROP DATABASE`'s
    # `pg_terminate_backend` doesn't leave the pool with dead connections
    # that the next `Database.with_db` caller would check out and fail on),
    # and re-initialises it after migrations so the synchronous index DDL has
    # a live pool pointing at the freshly created database.
    def self.db_reset(yes : Bool = false) : Nil
      database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL environment variable is required") }

      uri = URI.parse(database_url)
      db_name = uri.path.sub(/^\//, "")

      if db_name.empty?
        abort("Cannot parse database name from DATABASE_URL: #{database_url}")
      end

      # Confirmation gate — before any destructive step. The plan prints
      # first, then `confirm!` prompts or refuses, mirroring `Migrate.down`.
      unless yes
        puts "About to drop database '#{db_name}' and rebuild it from all migrations."
        confirm!("db_reset")
      end

      # Set synchronous mode BEFORE the seed call. The flag is read by
      # `Index::Manager.sync` (invoked from `Doctype::Create` inside
      # `Seed.seed`); setting it after `Database.init` but before `Seed.seed`
      # is the earliest correct position.
      Index::Manager.synchronous = true

      # Build a connection string to the default `postgres` database so we
      # can drop the target database while nobody is connected to it.
      admin_uri = uri.dup
      admin_uri.path = "/postgres"
      admin_url = admin_uri.to_s

      # Tear down any existing singleton pool BEFORE the DROP. Otherwise
      # `pg_terminate_backend` (below) kills the pooled backends and the
      # next `Database.with_db` caller (e.g. an `Index::Manager` fiber)
      # would check out a dead connection and fail with `DB::ConnectionLost`
      # / `IO::EOFError`. Idempotent — safe when no pool exists.
      Database.close

      puts "Dropping database '#{db_name}'..."
      DB.open(admin_url) do |db|
        # Terminate existing connections to the target database (PG >= 8.4)
        db.exec("SELECT pg_terminate_backend(pg_stat_activity.pid)
                 FROM pg_stat_activity
                 WHERE pg_stat_activity.datname = $1
                   AND pid <> pg_backend_pid()", db_name)
        db.exec("DROP DATABASE IF EXISTS \"#{db_name}\"")
      end

      puts "Creating database '#{db_name}'..."
      DB.open(admin_url) do |db|
        db.exec("CREATE DATABASE \"#{db_name}\"")
      end

      puts "Running migrations..."
      run

      # Now that the database exists, (re)initialise the singleton pool.
      # Synchronous index DDL (`Index::Manager.sync` invoked from
      # `Doctype::Create` inside `Seed.seed` below) runs `CREATE INDEX` on
      # the caller's connection — no background fibers, no separate
      # connection checkout — but the pool must still point at the freshly
      # created database (not the killed backends from before the DROP),
      # otherwise the inline DDL would hit a `DB::ConnectionLost`.
      Database.init(database_url)

      puts "Seeding core doctypes..."
      DB.open(database_url) do |db|
        conn = db.checkout
        begin
          report = Doctype::Seed.seed_full(conn)
          report.created.each { |id| puts "  SEED    #{id}" }
          report.updated.each { |id| puts "  UPDATE  #{id}" }
          puts "  All core doctypes already present" if report.empty?

          # Hydrate the currency registry from the just-seeded
          # `core.Currency` rows so seed and fixture money values validate
          # against live data. Currency rows carry no money fields, so the
          # seed itself never blocks on the registry.
          Currency::Registry.refresh(conn)
          puts "  Currency registry: #{Util::Currency.all.size} currencies"

          # Synchronous mode guarantees no background fibers were spawned,
          # so there is nothing to drain before the admin insert — but
          # `RetryCLI.retry_all` is still useful: the inline `CREATE INDEX`
          # may fail (e.g., on a pre-existing INVALID index row from a
          # previous interrupted run) and row-level retry re-applies it on
          # a quiet table. Idempotent. Quiet: the pass prints nothing when
          # no row is retryable.
          Index::RetryCLI.retry_all(conn, quiet: true)
        ensure
          conn.release
        end
      end

      # Defensive: with synchronous mode set, no background DDL fibers are
      # in flight at this point, so `wait_for_pending_fibers` is a no-op —
      # but the call is kept as a safety net so the helper stays correct
      # even if a future caller changes the synchronous-mode contract.
      unless Index::Manager.wait_for_pending_fibers
        Log.for("facet.migrate").warn do
          "Background index fibers did not drain within the timeout — " \
          "some indexes may be left in 'pending' status; run `facet index:retry` to finish them."
        end
      end

      Database.close
    end

    # Seeds core doctypes and the currency registry on an existing,
    # migrated database — the tail of `db_reset` without the drop.
    #
    # `db_reset` is the only command that seeds core doctypes, and it
    # drops the database first: a migrate-only bootstrap cannot boot an
    # empty volume (schema without `core.*` / `iam.*` definitions boots
    # broken). This command closes that gap. It is idempotent and
    # non-destructive — safe on every boot (`facet migrate && facet
    # seed:core`), never a substitute for `db_reset` in dev.
    #
    # Steps mirror `db_reset`'s tail: synchronous inline index DDL,
    # `Doctype::Seed.seed` (prints `All core doctypes already present`
    # on a seeded database), `Currency::Registry.refresh`, and the
    # `Index::RetryCLI.retry_all` pass. Owns its singleton-pool
    # lifecycle: re-initialises it against `DATABASE_URL` and closes it
    # at the end (the `db_reset` pattern).
    def self.seed_core : Nil
      # Set synchronous mode BEFORE the seed call — same position as
      # `db_reset`. The flag is read by `Index::Manager.sync` (invoked
      # from `Doctype::Create` inside `Seed.seed`).
      Index::Manager.synchronous = true

      database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL environment variable is required") }

      Database.init(database_url)

      puts "Seeding core doctypes..."
      DB.open(database_url) do |db|
        conn = db.checkout
        begin
          report = Doctype::Seed.seed_full(conn)
          report.created.each { |id| puts "  SEED    #{id}" }
          report.updated.each { |id| puts "  UPDATE  #{id}" }
          puts "  All core doctypes already present" if report.empty?

          # Hydrate the currency registry from the seeded `core.Currency`
          # rows so seed and fixture money values validate against live
          # data. Currency rows carry no money fields, so the seed itself
          # never blocks on the registry.
          Currency::Registry.refresh(conn)
          puts "  Currency registry: #{Util::Currency.all.size} currencies"

          # The inline `CREATE INDEX` may fail (e.g., on a pre-existing
          # INVALID index row from a previous interrupted run) and
          # row-level retry re-applies it on a quiet table. Idempotent.
          # Quiet: the pass prints nothing when no row is retryable.
          Index::RetryCLI.retry_all(conn, quiet: true)
        ensure
          conn.release
        end
      end

      # Defensive: with synchronous mode set, no background DDL fibers
      # are in flight at this point, so `wait_for_pending_fibers` is a
      # no-op — but the call is kept as a safety net so the helper stays
      # correct even if a future caller changes the synchronous-mode
      # contract. Mirrors the drain in `db_reset`.
      unless Index::Manager.wait_for_pending_fibers
        Log.for("facet.migrate").warn do
          "Background index fibers did not drain within the timeout — " \
          "some indexes may be left in 'pending' status; run `facet index:retry` to finish them."
        end
      end

      Database.close
    end

    # ── Revert (DOWN) ───────────────────────────────────────────────────

    # Returns the `-- UP` section of a migration file: everything before the
    # `-- DOWN` marker (the whole file when the marker is absent).
    def self.up_section(sql : String) : String
      sql.split(SECTION_SPLIT_RE).first
    end

    # Returns the `-- DOWN` section of a migration file: everything after
    # the `-- DOWN` marker. Returns `nil` when the marker is absent or only
    # whitespace follows it.
    def self.down_section(sql : String) : String?
      rest = sql.split(SECTION_SPLIT_RE)[1]?
      return nil if rest.nil? || rest.strip.empty?
      rest
    end

    # CLI subcommand for reverting applied migrations.
    #
    # Usage:
    #   facet migrate:down             # revert the most recent applied migration
    #   facet migrate:down 0008        # revert everything applied after 0008_jobs.sql
    #   facet migrate:down --yes       # skip the confirmation prompt
    module DownCLI
      # Parses `args`, then runs `Migrate.down`. Returns the process exit
      # code (0 on success, 1 on a malformed command line or an invalid
      # revert plan). SQL failures raise and surface as the process's
      # unhandled-exception exit, mirroring `migrate`.
      def self.run(args : Array(String)) : Int32
        assume_yes = false

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet migrate:down [target] [options]"

          parser.on("--yes", "-y", "Skip the confirmation prompt (required when stdin is not a terminal)") do
            assume_yes = true
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        if args.size > 1
          puts "Error: migrate:down accepts at most one target (full filename or NNNN prefix)."
          return 1
        end

        begin
          Migrate.down(args.first?, assume_yes)
        rescue e : Migrate::DownError
          puts "Error: #{e.message}"
          return 1
        end
        0
      end
    end

    # CLI subcommand for the drop → create → migrate → seed workflow.
    #
    # Usage:
    #   facet db_reset          # print the plan and ask for confirmation
    #   facet db_reset --yes    # skip the confirmation prompt
    #
    # The command stays chainable (`facet db_reset --yes seed:dev`): the
    # chain validator hands it the dash tokens after its name and keeps the
    # bare tokens as the next commands.
    module DbResetCLI
      record Options, assume_yes : Bool

      # Parses `args`, then runs `Migrate.db_reset`. Returns the process
      # exit code. An unknown flag raises `OptionParser::InvalidOption`
      # before any destructive action runs.
      def self.run(args : Array(String)) : Int32
        Migrate.db_reset(parse(args).assume_yes)
        0
      end

      # Pure flag parsing, separate from `run` so specs cover it without
      # executing the destructive workflow.
      def self.parse(args : Array(String)) : Options
        assume_yes = false

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet db_reset [options]"

          parser.on("--yes", "-y", "Skip the confirmation prompt (required when stdin is not a terminal)") do
            assume_yes = true
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        Options.new(assume_yes)
      end
    end

    # ── Private helpers ────────────────────────────────────────────────

    # Executes a SQL string that may contain multiple statements separated
    # by semicolons. Uses the simple-query protocol by calling raw_exec
    # instead of the prepared-statement path.
    private def self.exec_multi(db, sql : String)
      db.using_connection do |conn|
        conn.as(PG::Connection).exec_all(sql)
      end
    end

    private def self.ensure_migrations_table(db)
      db.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS _migrations (
          filename    text PRIMARY KEY,
          applied_at  timestamp NOT NULL DEFAULT now()
        )
      SQL
    end

    private def self.migration_ran?(db, filename) : Bool
      result = db.query_one?("SELECT 1 FROM _migrations WHERE filename = $1", filename, as: Int32)
      !result.nil?
    end

    private def self.record_migration(db, filename)
      db.exec("INSERT INTO _migrations (filename) VALUES ($1)", filename)
    end

    # Applied migration filenames in ascending filename order. Filenames are
    # zero-padded, so filename order equals apply order.
    private def self.applied_migrations(db) : Array(String)
      db.query_all("SELECT filename FROM _migrations ORDER BY filename", as: String)
    end

    # Embedded migration filenames, sorted.
    private def self.migration_files : Array(String)
      MIGRATION_SOURCES.keys.sort!
    end

    # Builds the revert plan: `(filename, down_sql)` pairs in reverse
    # filename order. Without a target this is the latest applied migration;
    # with a target it is every applied migration newer than the target. A
    # plan that cannot be executed (unknown target, target not applied, file
    # missing, `-- DOWN` section missing or empty) raises `DownError` here —
    # before any SQL runs.
    private def self.revert_plan(target : String?, applied : Array(String)) : Array(Tuple(String, String))
      filenames =
        if target.nil?
          applied.empty? ? [] of String : [applied.last]
        else
          boundary = resolve_target(target)
          unless applied.includes?(boundary)
            raise DownError.new("#{boundary} is not applied — nothing to revert")
          end
          applied.select { |file| file > boundary }.reverse!
        end

      filenames.map do |filename|
        {filename, down_section!(filename)}
      end
    end

    # Resolves a CLI target against the embedded migrations. Accepts the
    # exact filename or its `NNNN` number prefix.
    private def self.resolve_target(target : String) : String
      name = File.basename(target)
      files = migration_files

      return name if files.includes?(name)

      unless name.matches?(/^\d{4}$/)
        raise DownError.new("unknown migration: #{target} — expected the full filename or its NNNN prefix")
      end

      matches = files.select(&.starts_with?("#{name}_"))
      if matches.size == 1
        return matches.first
      end

      if matches.empty?
        raise DownError.new("unknown migration: #{target} — this build has no migration numbered #{name}")
      end

      raise DownError.new("ambiguous target: #{target} matches #{matches.join(", ")}")
    end

    # Reads `filename`'s `-- DOWN` section, raising `DownError` when the
    # migration is missing from this build or the section is unusable.
    private def self.down_section!(filename : String) : String
      sql = MIGRATION_SOURCES[filename]?
      raise DownError.new("#{filename} is recorded in _migrations but is not embedded in this build") if sql.nil?

      section = down_section(sql)
      if section.nil?
        raise DownError.new("#{filename} has no usable -- DOWN section")
      end
      section
    end

    # Runs one migration's `-- DOWN` section and deletes its `_migrations`
    # row in a single transaction, so the schema and the applied list can
    # never disagree about the migration's state.
    private def self.revert_one(db : DB::Database, filename : String, down_sql : String) : Nil
      db.transaction do |tx|
        conn = tx.connection
        conn.as(PG::Connection).exec_all(down_sql)
        conn.exec("DELETE FROM _migrations WHERE filename = $1", filename)
      end
    end

    # Outcome of the interactive confirmation gate (`ask`).
    enum ConfirmResult
      Accepted
      Declined
      NeedsTerminal
    end

    # Pure decision pass of the interactive confirmation gate. Prints the
    # prompt, reads one answer line, and classifies it. Never terminates
    # the process — `confirm!` turns a refusal into the abort exit. `tty`,
    # `input` and `output` are injectable, so specs drive the gate without
    # a terminal.
    def self.ask(tty : Bool = STDIN.tty?, input : IO = STDIN, output : IO = STDOUT) : ConfirmResult
      return ConfirmResult::NeedsTerminal unless tty

      output.print "Proceed? [y/N] "
      answer =
        begin
          input.read_line
        rescue IO::EOFError
          ""
        end

      return ConfirmResult::Accepted if {"y", "yes"}.includes?(answer.strip.downcase)
      ConfirmResult::Declined
    end

    # Interactive confirmation gate for the destructive migration commands
    # (`migrate:down`, `db_reset`). Refuses to run when stdin is not a
    # terminal — scripted callers must pass `--yes` explicitly. An EOF on
    # the prompt declines, like any other answer but `y`/`yes`.
    private def self.confirm!(command : String) : Nil
      result = ask
      abort("Aborted.") if result.declined?
      unless result.accepted?
        abort("#{command} needs a terminal to confirm — re-run with --yes to skip the prompt")
      end
    end
  end
end
