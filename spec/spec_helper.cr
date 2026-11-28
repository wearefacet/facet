# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Process-wide UTC pin ────────────────────────────────────────────────────
# Mirrors src/main.cr: every timestamp column is tz-naive and stores UTC;
# pinning TZ makes an accidental `Time.local` resolve to UTC instead of the
# host zone. The spec suite runs on developer machines in any timezone, so
# the pin must not depend on the shell.
ENV["TZ"] = "UTC"

# Set APP_ENV to "test" before loading any dotenv files so that
# .env.test overrides .env correctly.
ENV["APP_ENV"] = "test"

# ── Dotenv loader (inline, mirrors src/main.cr) ────────────────────────────
# Loads KEY=VALUE pairs from .env and .env.test without pulling in the
# full application (which would start the CLI / Kemal server).
# Precedence: values already present in the real shell environment win over
# both files; the environment-specific file overrides the base file and may
# also introduce new keys.

# Keys captured in *shell_keys* are skipped — shell exports always win.
# The base file's keys are not in *shell_keys*, so the environment-specific
# file overrides them and can add keys the base file does not define.
def load_dotenv_file(path : String, shell_keys : Set(String)) : Nil
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

shell_keys = ENV.keys.to_set
load_dotenv_file(".env", shell_keys)
load_dotenv_file(".env.#{ENV["APP_ENV"]}", shell_keys)

require "file_utils"
require "../src/telemetry"
require "../src/migrate"
require "../src/event"
require "../src/grants"
require "../src/http/auth_handler"
# Money support is hoisted above the suite hooks — `register_seed_currencies`
# is called from `Spec.before_suite`. The remaining support files load below,
# after `require "spec"`.
require "./support/money_helper"

# ── Database template & per-worker test database management ──────────────────
#
# Each spec worker process gets its own clone of the template database,
# ensuring full isolation without connection churn between examples.
# Data tables (mutations, projections) are truncated before each example
# for a clean per-test state.

# Builds an admin URL pointing to the `postgres` database for management ops.
private def admin_database_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/postgres"
  uri.to_s
end

# Builds a DATABASE_URL pointing to a specific database name.
private def build_database_url(db_name : String) : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/#{db_name}"
  uri.to_s
end

# Applies `TEST_SESSION_OPTIONS` to a single PG connection via `SET`. The
# settings persist for the lifetime of the connection (i.e. as long as it
# stays checked out of the pool) — they are *not* per-statement.
#
# This is the only correct way to apply tuning in this project: `crystal-pg`
# 0.30's `ConnInfo` parser silently ignores the libpq `options` URL parameter
# (only host/port/db/user/password/ssl*/application_name/replication are read),
# so URL-embedded `-c key=value` pairs do nothing. `SET` after `connect` is
# the only path that actually reaches the PG backend.
#
# Used in two places:
#   * `Spec.before_suite` registers it on the singleton pool via
#     `Facet::Database.setup_connection`, so every new pooled connection
#     (initial, lazily-created, and background-fiber checkouts) inherits it.
#   * `Spec.before_each` registers it on the transient `DB.open` used for the
#     per-spec TRUNCATE.
private def apply_test_session_tuning(conn : DB::Connection) : Nil
  TEST_SESSION_OPTIONS.each do |k, v|
    # Quote the value as a string literal so memory-size values (e.g. "64MB")
    # are accepted — `SET work_mem = 64MB` fails to parse, `= '64MB'` works.
    # PG string-casts the literal to the parameter's expected type, so this
    # is also fine for `off`, `0`, `1.0`, etc.
    conn.exec("SET #{k} = '#{v}'")
  end
end

# Terminates all backends connected to the named database (except our own).
private def terminate_connections(db_name : String) : Nil
  DB.open(admin_database_url) do |db|
    db.exec("SELECT pg_terminate_backend(pg_stat_activity.pid)
             FROM pg_stat_activity
             WHERE pg_stat_activity.datname = $1
               AND pid <> pg_backend_pid()", db_name)
  end
rescue
  # OK — database may not exist yet
end

TEMPLATE_DB = "facet_test_template"
WORKER_DB   = "facet_test_worker_#{Process.pid}"

# Per-session PostgreSQL tuning applied to every connection that targets the
# worker database. All entries are *user-context* settings (settable by any
# role), so this works regardless of whether the test role is a superuser.
#
# These are applied via `SET #{key} = #{value}` statements in
# `apply_test_session_tuning`, registered as a `setup_connection` hook on
# both the singleton (`Facet::Database`) and the transient (`DB.open`)
# pools so every new connection inherits them. Tweak values here to
# experiment; remove an entry to opt out of that adjustment.
#
# Skipped on purpose:
#   * `seq_page_cost`        — default is already 1.0 (no-op).
#   * `track_activities`, `track_counts`, `log_statement` — superuser-only;
#     the wins are marginal and they would emit `permission denied`
#     warnings on non-superuser CI runs.
TEST_SESSION_OPTIONS = {
  "synchronous_commit" => "off", # biggest win — skip WAL flush on every write
  # "jit"                             => "off",   # JIT compile cost dominates on tiny test queries
  "work_mem"                        => "128MB",   # JSONB sorts/hashes stay in-memory
  "maintenance_work_mem"            => "256MB",   # speeds CREATE INDEX in fixtures
  "max_parallel_workers_per_gather" => "0",       # no parallel-worker spinup on tiny scans
  "random_page_cost"                => "1.0",     # test DB fits in cache — treat random I/O as cheap
  "client_min_messages"             => "warning", # drop NOTICE/INFO noise from per-spec output
}

# Creates (or recreates) the shared template database.
#
# Runs migrations and seeds core doctypes/documents so every worker
# starts from the same baseline. Protected by a PostgreSQL advisory
# lock so concurrent workers don't race.
private def setup_template_database : Nil
  admin_url = admin_database_url

  DB.open(admin_url) do |db|
    db.exec("SELECT pg_advisory_lock(42)")
    begin
      terminate_connections(TEMPLATE_DB)
      db.exec("DROP DATABASE IF EXISTS \"#{TEMPLATE_DB}\"")
      db.exec("CREATE DATABASE \"#{TEMPLATE_DB}\"")

      # Temporarily point DATABASE_URL at the template so Migrate.run
      # and Seed.seed write into the template.
      original_url = ENV.fetch("DATABASE_URL")
      template_url = build_database_url(TEMPLATE_DB)
      ENV["DATABASE_URL"] = template_url

      begin
        Facet::Migrate.run

        DB.open(template_url) do |tpl_db|
          conn = tpl_db.checkout
          begin
            Facet::Doctype::Seed.seed(conn)
          ensure
            conn.release
          end
        end
      ensure
        ENV["DATABASE_URL"] = original_url
      end
    ensure
      db.exec("SELECT pg_advisory_unlock(42)")
    end
  end
end

# Creates (or recreates) the per-worker test database by cloning the
# template. Sets DATABASE_URL so all subsequent connections within
# this worker process go to the worker's private DB.
private def provision_worker_database : Nil
  admin_url = admin_database_url

  DB.open(admin_url) do |db|
    terminate_connections(WORKER_DB)
    db.exec("DROP DATABASE IF EXISTS \"#{WORKER_DB}\"")
    db.exec("CREATE DATABASE \"#{WORKER_DB}\" TEMPLATE \"#{TEMPLATE_DB}\"")
  end

  ENV["DATABASE_URL"] = build_database_url(WORKER_DB)
end

# Recursively removes the per-suite test upload directory. The shrine
# FileSystem storage for the test env is rooted at `tmp/uploads/test`
# (see `config.test.yml`); specs that exercise `Artifact::Uploader.upload`
# write artifacts there. Without this hook those files accumulate across
# runs. Best-effort: a hard-killed worker may orphan files, identical to the
# worker-DB teardown contract below.
private def teardown_test_uploads : Nil
  dir = File.expand_path("tmp/uploads/test")
  FileUtils.rm_r(dir) if Dir.exists?(dir)
rescue
  # Best-effort cleanup
end

# Drops the per-worker test database on suite teardown.
private def teardown_worker_database : Nil
  DB.open(admin_database_url) do |db|
    terminate_connections(WORKER_DB)
    db.exec("DROP DATABASE IF EXISTS \"#{WORKER_DB}\"")
  end
rescue
  # Best-effort cleanup
end

# ── Spec lifecycle hooks ────────────────────────────────────────────────────

# Opens the singleton pools against the worker database and registers
# per-session tuning on every pooled connection (existing and future).
#
# `Spec.before_suite` calls this; specs that re-initialize the pool (e.g.
# the statement-timeout examples in `database_spec.cr`) call it again to
# restore the suite setup exactly.
#
# The cluster comes from `config.test.yml`'s `database:` section via
# `Config.instance` — main at the worker database plus a same-URL replica
# with read-only enforcement, the suite-wide tripwire (see
# `Facet::Config::DatabaseConfig` and `doc/backend/test-database.md`).
def init_suite_database_pool : Nil
  Facet::Database.init(
    Facet::Config.instance.database.cluster,
    statement_timeout_ms: Facet::Config.instance.database.statement_timeout_ms,
  )

  Facet::Database.setup_connection do |conn|
    apply_test_session_tuning(conn)
  end
end

# Fails the suite fast with a clear instruction when the test PostgreSQL
# is not reachable. Without this check the suite would die deeper inside
# `setup_template_database` with a bare connection error.
#
# `DB::ConnectionRefused` is what crystal-db raises when the pool cannot
# build its first connection; `PQ::ConnectionError` covers mid-handshake
# failures. Auth problems raise `PQ::PQError` and are deliberately not
# caught — they must show their real message.
private def verify_test_database : Nil
  DB.open(admin_database_url) do |db|
    db.query_one("SELECT 1", as: Int32)
  end
rescue ex : DB::ConnectionRefused | PQ::ConnectionError | IO::Error
  abort "Test PostgreSQL is not reachable: #{ex.message}\n" \
        "Start the test database with: make test_db_up"
end

Spec.before_suite do
  # Run `Index::Manager.sync` in synchronous mode for the duration of the
  # spec suite. This swaps the production non-blocking behaviour
  # (`CREATE INDEX CONCURRENTLY` + background fiber + per-test drain) for
  # an inline `CREATE INDEX` on a fresh singleton-pool connection. Two
  # reasons: (a) `CREATE INDEX` is significantly faster than `CONCURRENTLY`
  # on the small test DB (single table scan, no waiting for in-flight
  # transactions); (b) the synchronous path takes no SHARE lock, so the
  # per-test `TRUNCATE` cannot deadlock against in-flight DDL. The
  # concurrent path is still exercised in `spec/index/manager_spec.cr`'s
  # "concurrent mode" example group — see `Manager.synchronous?`'s doc for
  # the production default and the pattern (mirrors
  # `Event::Publisher.manager = InProcessManager.new`).
  Facet::Index::Manager.synchronous = true

  # Skip the `core.Currency` seed *documents* for every re-seed in this
  # suite. Money validation reads the in-memory registry registered just
  # below — it never consults the currency rows — and re-creating ~160
  # currency documents through the full document pipeline on every
  # per-example `Seed.seed` call dominated the suite's runtime (~300 ms of
  # each ~500 ms re-seed). Definitions still seed; the DB-coupled currency
  # hydration path stays covered by `spec/currency_spec.cr`, which
  # builds its own currency rows.
  Facet::Doctype::Seed.document_exclusions = ["core.Currency"]

  # Register the currency seed set into the in-memory registry so money
  # fixture seeding (which writes `{"currency":"USD"}` money objects) passes
  # per-value `MoneyType#validate`, and so money filter parsing in list specs
  # can resolve known tickers. The per-example truncation wipes the seeded
  # `core.Currency` projections, so specs rely on the in-memory registration;
  # the DB-coupled hydration path is exercised in `spec/currency_spec.cr`.
  register_seed_currencies

  verify_test_database
  setup_template_database
  provision_worker_database

  # Snapshot the seeded baseline before anything truncates it. Every later
  # `restore_seeded_baseline` call copies these rows back in ~13 ms instead
  # of re-running the ~320 ms seed pipeline (see seeded_baseline_helper.cr).
  DB.open(ENV.fetch("DATABASE_URL")) do |db|
    conn = db.checkout
    begin
      SeededBaseline.create_snapshot(conn)
    ensure
      conn.release
    end
  end

  # Reload the config before the pools open. Seeding the template runs the
  # document pipeline, and its hooks read `Config.instance` — the first
  # load froze `!env DATABASE_URL` expansions while ENV still pointed at
  # the template database. The cluster's pool URLs must point at the
  # worker database this process owns, so drop the cached instance; the
  # next access reloads config.test.yml against the worker URL.
  Facet::Config.reset!

  # Initialize the singleton connection pool for the worker's private DB.
  # Initialize OpenTelemetry with NullExporter for tests
  Facet::Telemetry.init

  init_suite_database_pool

  # Set up an InProcessManager so specs that touch Publisher.enqueue/flush
  # work without a real Redis connection. Events are stored in memory.
  Facet::Event::Publisher.manager = Facet::Event::InProcessManager.new

  # Snapshot the managed indexes and statistics objects present at suite
  # start. The per-example `reset_managed_indexes` drops only what this
  # snapshot does not contain, so a seeded index (and its `doctype_indexes`
  # row) survives — `sync` then keeps it `active` and never re-creates a
  # physical unique index over seeded rows (which would reject a legitimate
  # duplicate insert, e.g. two `test@example.com` accounts). See
  # `reset_managed_indexes`.
  DB.open(ENV.fetch("DATABASE_URL")) do |db|
    ManagedIndexBaseline.capture(db)
  end
end

Spec.before_each do
  # Reset data tables before each example. The connection is opened once per
  # worker and reused (see `truncate_db`) — no per-example connection churn.
  # This is a global hook that fires before every spec example, including
  # any local before_each hooks defined in describe blocks.
  #
  # In synchronous mode (`@synchronous = true` above) `Index::Manager.sync`
  # runs DDL inline on the caller's stack — no background fibers, no SHARE
  # lock, no concurrent path that could still be in flight. The
  # `truncate_with_retry` deadlock-retry below is therefore a defensive
  # fallback rather than the main code path; it costs nothing when not
  # engaged. It also resets the accumulated managed indexes and statistics
  # objects before truncating; see `reset_managed_indexes`.
  truncate_with_retry

  # Clear the fiber-local doctype definition cache to prevent tests from
  # seeing stale definitions (e.g. a doctype definition that was loaded in
  # a previous example but whose projection was truncated).
  Facet::Doctype::DefinitionStore.cache.clear

  # The grants registry is a module-level cache — the per-example TRUNCATE
  # wipes the underlying `core.DomainGrant` rows, so the cached entries
  # must not serve the next example. Mark stale: the next read rebuilds
  # from the (now empty) projections table.
  Facet::Grants::Registry.mark_stale

  # Clear the fiber-local auth context. If a previous example (e.g. the
  # auth_flow spec) set __auth_context to a Real principal, subsequent
  # requests would hit WriteEnforcer/ReadEnforcer checks with a stale
  # restricted role instead of the system bypass AuthContext.system,
  # producing spurious 403 errors.
  Fiber.current.auth_context = nil

  # ERROR-level log capture for the HTTP debug harness (SpecLogCapture /
  # SpecHttpDebug): `run_handler` attaches the lines emitted during a
  # request to failing 5xx bodies. Re-bound every example so a mid-example
  # `Log.setup` (a `Log.setup` clears the whole builder) cannot disable it
  # for the rest of the suite.
  Log.builder.bind("*", Log::Severity::Error, SpecLogCapture.backend)
end

# Holds the per-worker truncate connection. A `class` (not a constant)
# because Crystal constants are immutable and this is assigned lazily.
#
# `setup_connection` is applied by `truncate_db` on first use rather than in
# the initializer, because `apply_test_session_tuning` is a top-level private
# method and is not visible inside this class body.
class TruncateConnection
  @@db : DB::Database? = nil
  @@url : String? = nil
  @@tuned = false

  # Returns the cached pool, reopening it when `DATABASE_URL` changed.
  # Specs such as `migrate/db_reset_spec.cr` repoint `DATABASE_URL` at a
  # scratch database and restore it afterwards; a cached pool must never
  # keep truncating the wrong database after such an example.
  def self.get : DB::Database
    url = ENV.fetch("DATABASE_URL")
    if (db = @@db) && @@url == url
      return db
    end
    release
    @@url = url
    @@db = DB.open(url)
  end

  def self.tuned? : Bool
    @@tuned
  end

  def self.tuned! : Nil
    @@tuned = true
  end

  def self.release : Nil
    @@db.try(&.close)
    @@db = nil
    @@url = nil
    @@tuned = false
  end
end

private def truncate_db : DB::Database
  db = TruncateConnection.get
  # Tune once per worker, not once per example: `setup_connection` also
  # iterates existing connections, so the first call covers the initial
  # connection and any lazily-created ones inherit the hook. A reopened pool
  # (URL changed) starts untuned, so the flag resets in `release`.
  unless TruncateConnection.tuned?
    db.setup_connection { |conn| apply_test_session_tuning(conn) }
    TruncateConnection.tuned!
    at_exit { TruncateConnection.release }
  end
  db
end

# Runs the per-example TRUNCATE with a bounded retry on PG deadlock
# (SQLSTATE 40P01). The deadlock is benign — it means a background DDL
# fiber is mid-work; the retry waits for it to release its locks.
#
# The connection is opened once per worker and reused for every example.
# Opening a fresh `DB.open` per example cost ~6 ms of connect plus ~0.6 ms
# of session tuning each time; across a few thousand examples that was a
# measurable share of the suite's runtime. One long-lived connection keeps
# the same isolation guarantee because `TRUNCATE` is autocommitted here
# (no surrounding transaction), so no state carries between examples.
#
# ── Managed-index reset ─────────────────────────────────────────────────
#
# `Index::Manager.sync` creates a physical partial index (and, for btree
# fields, an extended statistics object) on the shared `projections` table
# for every indexed field a spec's doctype declares. Those are DDL objects,
# so the per-example `TRUNCATE` does not remove them: they pile up across
# the run. `TRUNCATE` must open a new relfilenode for the table *and every
# one of its indexes*, so the cost of every later example grows with the
# total left behind (measured: ~0.26 ms per index — 7 indexes = 6 ms, 207
# indexes = 60 ms; the complete suite reached 207). The statistics objects
# also slow every query, because the planner loads each one on `projections`.
#
# `reset_managed_indexes` drops the managed indexes and statistics objects
# that appeared *after* the suite started, together with their
# `doctype_indexes` rows. The baseline captured in `before_suite` is left
# untouched, so a seeded index keeps its tracking row and `sync` never
# re-creates a physical unique index over seeded rows. That matters: the
# unique enforcement on a seeded doctype (e.g. `iam.Account.email`) is
# validation-level in the template, and a freshly created physical unique
# index would reject legitimate spec data (two `test@example.com` accounts).
# Dropping a spec-created index with its row is safe — `sync` re-creates
# whatever the next spec actually needs.
#
# Only used by the spec hook — production drops a domain's indexes through
# `Index::Manager.dispose_domain_indexes` (see `Domain::Scratch`).
module ManagedIndexBaseline
  @@index_names = Set(String).new
  @@statistics_names = Set(String).new

  # Records the managed indexes and statistics objects present at suite
  # start. Called once, in `before_suite`.
  def self.capture(db : DB::Database) : Nil
    @@index_names = db.query_all(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'projections' AND indexname LIKE 'idx_env_%'",
      as: String,
    ).to_set
    @@statistics_names = db.query_all(
      "SELECT stxname FROM pg_statistic_ext WHERE stxrelid = 'projections'::regclass AND stxname LIKE 'idx_env_%'",
      as: String,
    ).to_set
  end

  def self.index_names : Set(String)
    @@index_names
  end

  def self.statistics_names : Set(String)
    @@statistics_names
  end
end

# Drops the managed indexes and statistics objects created after the suite
# started (everything not in `ManagedIndexBaseline`), plus their
# `doctype_indexes` rows. The `doctype_indexes` rows go with the indexes: a
# dropped index left marked `active` would make `sync` skip re-creating it.
private def reset_managed_indexes(db : DB::Database) : Nil
  baseline_indexes = ManagedIndexBaseline.index_names
  baseline_stats = ManagedIndexBaseline.statistics_names

  db.using_connection do |conn|
    stale_indexes = conn.query_all(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'projections' AND indexname LIKE 'idx_env_%'",
      as: String,
    ).reject { |name| baseline_indexes.includes?(name) }

    stale_stats = conn.query_all(
      "SELECT stxname FROM pg_statistic_ext WHERE stxrelid = 'projections'::regclass AND stxname LIKE 'idx_env_%'",
      as: String,
    ).reject { |name| baseline_stats.includes?(name) }

    return if stale_indexes.empty? && stale_stats.empty?

    stale_indexes.each do |name|
      conn.exec("DROP INDEX IF EXISTS #{quote_ident(name)}")
    end
    stale_stats.each do |name|
      conn.exec("DROP STATISTICS IF EXISTS #{quote_ident(name)}")
    end

    # Delete the tracking rows for the dropped indexes. `doctype_indexes`
    # stores `index_name`, so the deleted rows match exactly what was dropped.
    stale_indexes.each do |name|
      conn.exec("DELETE FROM doctype_indexes WHERE index_name = $1", name)
    end
  end
end

private def quote_ident(name : String) : String
  %("#{name.gsub('"', "\"\"")}")
end

private def truncate_with_retry(max_attempts : Int = 5) : Nil
  db = truncate_db
  reset_managed_indexes(db)
  attempts = 0
  loop do
    db.exec(SeededBaseline::TRUNCATE_SQL)
    return
  rescue ex : PQ::PQError
    # SQLSTATE lives in the field tagged `:code`. 40P01 = deadlock_detected.
    sqlstate = ex.fields.find(&.name.==(:code)).try(&.message)
    raise ex unless sqlstate == "40P01"
    attempts += 1
    raise ex if attempts >= max_attempts
    sleep 25.milliseconds * (2 ** (attempts - 1))
  end
end

Spec.after_each do
  # Reset AuthHandler to disabled after every example so any spec that
  # toggles it on (e.g. auth flow) cannot leak state to other specs.
  Facet::HTTP::AuthHandler.enabled = false

  # Drop the error-log capture binding installed by before_each. A
  # mid-example `Log.setup` clears the whole builder — then there is
  # nothing left to unbind.
  begin
    Log.builder.unbind("*", Log::Severity::Error, SpecLogCapture.backend)
  rescue ArgumentError
    # Binding was cleared mid-example — nothing to remove.
  end
end

# Spec.after_suite only fires on a clean suite exit, so a worker killed by
# Ctrl+C, a crash, or an uncaught exception would orphan its database.
# at_exit also runs in those cases, making the worker DB cleanup far more
# reliable. This mirrors Spec.after_suite's behavior and supersedes it;
# both are kept for clarity but teardown_worker_database is idempotent.
# The same contract applies to the test upload directory: at_exit runs even
# on a killed worker, so the `tmp/uploads/test` tree is swept reliably.
at_exit do
  teardown_worker_database
  teardown_test_uploads
end

Spec.after_suite do
  teardown_worker_database
  teardown_test_uploads
end

# ── Database reset helper (kept for backward compat) ──────────────────────

def db_reset : Nil
  # No-op: the database lifecycle is managed by the spec hooks above.
  # Individual specs should not call db_reset directly.
end

require "spec"

# ── Load shared spec support ────────────────────────────────────────────────
require "./support/db_helper"
require "./support/io_helper"
require "./support/cache_freshness_helper"
require "./support/doctype_helper"
require "./support/seeded_baseline_helper"
require "./support/result_helper"
require "./support/wait_helper"
require "./support/redis_helper"
require "./support/redis_proxy"
require "./support/event_helper"
require "./support/iam_helper"
require "./support/rbac_helper"
require "./support/app_helper"
require "./support/oauth_helper"
require "./support/system_settings_helper"
require "./support/secrets_helper"
require "./support/log_capture"
