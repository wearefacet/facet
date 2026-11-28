# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "pg"
require "../database"
require "../doctype"
require "../index"

module Facet
  module Index
    # CLI subcommand for retrying failed index creations.
    #
    # Usage:
    #   facet index:retry
    #   facet index:retry --dry-run
    #   facet index:retry --domain hr
    #   facet index:retry --domain hr --doctype Employee
    module RetryCLI
      # A `pending` row younger than this is mid-flight in the server's
      # DDL fiber — retrying it would race the live CREATE under the DDL
      # gate. Only stale rows (left behind by a fiber that died before
      # completing its batch — pool closed, connection lost, process
      # killed) are picked up.
      PENDING_STALE_MINUTES = 10

      # The `fetch_retryable_rows` projection: one retryable row of
      # `doctype_indexes`. A type alias (not a record) because
      # `query_all(as:)` reads it positionally and `recheck_indexes`
      # destructures it.
      alias RetryableRow = {String, String, String, String, String, String, String?}

      # Outcome of re-checking one errored row against the current doctype
      # definition: `retry` (the index is still desired), `missing` (the
      # field no longer exists — mark as dropped), `skip` (doctype not
      # found or could not be parsed).
      record RecheckResult,
        status : String,
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        index_name : String,
        # The doctype's full desired index set — read for the `missing`
        # rows so the drop path can tell whether a sibling btree variant of
        # the same field still needs the shared statistics object.
        desired : Set(DesiredIndex) = Set(DesiredIndex).new

      # Public entry point for in-process callers (e.g. `Migrate.db_reset`)
      # that want to retry every errored index without going through the CLI
      # argument parser. Equivalent to `RetryCLI.run([])` but takes the
      # connection the caller already holds, so we don't open a second pool.
      #
      # The optional filters narrow the retryable set the same way the CLI's
      # `--domain` / `--doctype` options do: they AND onto the status
      # predicate and never qualify a row on their own. No dry-run.
      # Idempotent. With `quiet: true` the pass prints nothing when no row
      # is retryable — a seeding or transfer command must not print index
      # noise. The explicit CLI keeps its output.
      def self.retry_all(
        db : DB::Connection,
        domain_filter : String? = nil,
        doctype_filter : String? = nil,
        quiet : Bool = false,
      ) : Nil
        retry_failed(db, domain_filter, doctype_filter, false, quiet)
      end

      # Runs the command against the live database and returns the process
      # exit code (0 on success, 1 when any row failed). Initialises the
      # database pool itself. Options are parsed first, so `--help` works
      # without a reachable database — the same contract as `migrate:down`.
      def self.run(args : Array(String)) : Int32
        dry_run = false
        domain_filter = nil
        doctype_filter = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet index:retry [options]"

          parser.on("--dry-run", "Print what would be done without executing DDL") do
            dry_run = true
          end

          parser.on("--domain DOMAIN", "Only retry indexes for this domain") do |d|
            domain_filter = d
          end

          parser.on("--doctype DOCTYPE", "Only retry indexes for this doctype") do |d|
            doctype_filter = d
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        Database.init
        exit_code = 0
        begin
          Database.with_db(:read_write) do |db|
            exit_code = retry_failed(db, domain_filter, doctype_filter, dry_run)
          end
        ensure
          Database.close
        end
        exit_code
      end

      # Fetches every retryable row: `error` rows always, `pending` rows
      # once stale beyond `PENDING_STALE_MINUTES` (a fresh `pending` row
      # belongs to a live DDL fiber and must not be touched). The optional
      # filters narrow this set — they AND onto the status predicate, they
      # never qualify a row on their own.
      private def self.fetch_retryable_rows(
        db : DB::Connection,
        domain_filter : String?,
        doctype_filter : String?,
      ) : Array(RetryableRow)
        # Status predicate — the only way a row becomes retryable. The
        # filters below narrow this set; they must not widen it (B-50: an
        # OR-join let any filter qualify a row regardless of status).
        status_conditions = [
          "status = 'error'",
          "(status = 'pending' AND updated_at < now() - make_interval(mins => #{PENDING_STALE_MINUTES}))",
        ]
        where_clause = "(#{status_conditions.join(" OR ")})"

        params = [] of String
        filter_conditions = [] of String

        if domain_filter
          filter_conditions << "domain = $#{params.size + 1}"
          params << domain_filter
        end

        if doctype_filter
          filter_conditions << "doc_type = $#{params.size + 1}"
          params << doctype_filter
        end

        where_clause += " AND #{filter_conditions.join(" AND ")}" unless filter_conditions.empty?

        # One query; the empty filter list binds zero params.
        db.query_all(
          <<-SQL,
            SELECT domain, doc_type, field_name, index_type, index_name, status, error_message
            FROM doctype_indexes
            WHERE #{where_clause}
            ORDER BY domain, doc_type
          SQL


          args: params,
          as: {String, String, String, String, String, String, String?},
        )
      end

      # Prints the retryable rows before any DDL runs, one block per row.
      private def self.print_error_rows(rows)
        rows.each do |domain, doc_type, field_name, index_type, index_name, status, error_message|
          puts "  #{index_name}"
          puts "    domain:    #{domain}"
          puts "    doc_type:  #{doc_type}"
          puts "    field:     #{field_name}"
          puts "    type:      #{index_type}"
          puts "    status:    #{status}"
          if error_msg = error_message
            first_line = error_msg.lines.first
            puts "    error:     #{first_line}"
          end
          puts
        end
      end

      # Prints what the retry would do without running any DDL.
      private def self.execute_dry_run(recheck_results : Array(RecheckResult))
        puts "Dry-run mode — no DDL executed."
        recheck_results.each do |r|
          case r.status
          when "retry"
            puts "  Would CREATE INDEX CONCURRENTLY #{r.index_name}"
          when "missing"
            puts "  Would DROP INDEX CONCURRENTLY #{r.index_name} and mark as dropped"
          end
        end
      end

      # Runs one DDL action per retryable row. Rows are attempted
      # independently — one failure is reported and counted, it does not
      # stop the remaining rows. Returns the process exit code: 0 when
      # every attempt succeeded, 1 when at least one failed.
      private def self.execute_recheck_results(
        db : DB::Connection,
        recheck_results : Array(RecheckResult),
      ) : Int32
        retried = 0
        dropped = 0
        failed = 0

        recheck_results.each do |r|
          case r.status
          when "retry"
            print "  Creating #{r.index_name}... "
            begin
              execute_retry(db, r.domain, r.doc_type, r.field_name, r.index_type, r.index_name)
              puts "done"
              retried += 1
            rescue ex
              puts "FAILED (#{ex.class}: #{ex.message})"
              failed += 1
            end
          when "missing"
            print "  Dropping #{r.index_name} (field removed)... "
            begin
              execute_drop(db, r.domain, r.doc_type, r.field_name, r.index_type, r.index_name, r.desired)
              puts "done"
              dropped += 1
            rescue ex
              puts "FAILED (#{ex.class}: #{ex.message})"
              failed += 1
            end
          end
        end

        skipped_count = recheck_results.count { |r| r.status == "skip" }
        puts "\nFinished: #{retried} retried, #{dropped} dropped, #{skipped_count} skipped, #{failed} failed."
        failed.zero? ? 0 : 1
      end

      # Runs one retry pass and returns the process exit code (0 on
      # success, 1 when any row failed). `quiet` drops only the empty-set
      # line — a pass that finds rows still prints, so a teardown reports
      # the DDL it ran.
      private def self.retry_failed(
        db : DB::Connection,
        domain_filter : String?,
        doctype_filter : String?,
        dry_run : Bool,
        quiet : Bool = false,
      ) : Int32
        rows = fetch_retryable_rows(db, domain_filter, doctype_filter)

        if rows.empty?
          puts "No failed or stale-pending indexes found." unless quiet
          return 0
        end

        puts "Found #{rows.size} retryable index(es):\n\n"
        print_error_rows(rows)

        recheck_results = recheck_indexes(db, rows)

        retry_count = recheck_results.count { |r| r.status == "retry" }
        missing_count = recheck_results.count { |r| r.status == "missing" }
        failed_count = recheck_results.count { |r| r.status == "skip" }

        puts "After re-checking against current doctype definitions:"
        puts "  #{retry_count} to retry"
        puts "  #{missing_count} field no longer exists — will mark as dropped"
        puts "  #{failed_count} doctype not found or could not be parsed — skipped"
        puts

        if dry_run
          execute_dry_run(recheck_results)
          return 0
        end

        execute_recheck_results(db, recheck_results)
      end

      # For each retryable row, fetch the current doctype definition and
      # check whether the index is still desired.
      private def self.recheck_indexes(
        db : DB::Connection,
        rows : Array(RetryableRow),
      ) : Array(RecheckResult)
        results = [] of RecheckResult

        rows.each do |domain, doc_type, field_name, index_type, index_name, _status, _error_message|
          doctype_id = "#{domain}.#{doc_type}"

          defn = begin
            Doctype::DefinitionStore.fetch(db, doctype_id)
          rescue
            nil
          end

          if defn.nil?
            add_result(results, "skip", domain, doc_type, field_name, index_type, index_name)
            next
          end

          desired = Planner.compute_desired(defn)
          still_desired = desired.any? { |d| d.field_name == field_name && d.index_type == index_type }

          add_result(results, still_desired ? "retry" : "missing",
            domain, doc_type, field_name, index_type, index_name, desired)
        end

        results
      end

      # Appends one re-check outcome. `desired` carries the doctype's
      # desired index set for the drop path; the `skip` rows pass the
      # default empty set (they run no DDL).
      private def self.add_result(
        results : Array(RecheckResult),
        status : String,
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        index_name : String,
        desired : Set(DesiredIndex) = Set(DesiredIndex).new,
      ) : Nil
        results << RecheckResult.new(
          status: status,
          domain: domain,
          doc_type: doc_type,
          field_name: field_name,
          index_type: index_type,
          index_name: index_name,
          desired: desired,
        )
      end

      # Executes a retry: reset to pending, run CREATE INDEX CONCURRENTLY,
      # then update to active or error.
      private def self.execute_retry(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        index_name : String,
      ) : Nil
        # Reset to pending first
        db.exec(
          "UPDATE doctype_indexes SET status = 'pending', error_message = NULL, updated_at = now() WHERE index_name = $1",
          index_name
        )

        begin
          sql = Naming.create_index_sql(domain, doc_type, field_name, index_type)
          drop_sql = Naming.drop_index_sql(domain, doc_type, field_name, index_type)

          # The gate serialises this retry against the running server's
          # index DDL. Two `CREATE INDEX CONCURRENTLY` statements on
          # `projections` deadlock when they overlap, and the server may
          # be scheduling its own DDL while this CLI runs.
          #
          # The leftover removal runs inside the gate too: if a failed
          # attempt left a half-built index behind and the removal
          # silently failed outside the gate, the CREATE's
          # `IF NOT EXISTS` would match the leftover by name and mark an
          # INVALID index `active`.
          Manager.with_ddl_gate(db) do
            begin
              db.exec(drop_sql)
            rescue
              # Best-effort cleanup
            end
            Manager.exec_ddl_with_deadlock_retry(db, sql, drop_sql, max_attempts: 5)
            # A retried index also recreates its field's statistics object
            # when an earlier attempt failed before reaching it (see
            # `Naming.create_statistics_sql`).
            if stats_sql = Naming.create_statistics_sql(domain, doc_type, field_name, index_type)
              Manager.exec_ddl_with_deadlock_retry(db, stats_sql, max_attempts: 5)
            end
          end

          db.exec(
            "UPDATE doctype_indexes SET status = 'active', updated_at = now() WHERE index_name = $1",
            index_name
          )
        rescue ex
          error_message = "#{ex.class}: #{ex.message || "(no message)"}"

          Manager::Log.error(exception: ex) do
            "Index retry failed for #{domain}.#{doc_type}.#{field_name} " \
            "(#{index_type}, index_name=#{index_name}): #{error_message} | SQL: #{sql}"
          end

          db.exec(
            "UPDATE doctype_indexes SET status = 'error', error_message = $1, updated_at = now() WHERE index_name = $2",
            error_message,
            index_name
          )
          raise ex
        end
      end

      # Drops an index and marks it as dropped. The field's statistics
      # object goes with the last btree variant of the field: the recheck
      # already knows whether a sibling btree variant of the same field is
      # still desired (`desired`), and only a field with no remaining
      # btree index loses its statistics.
      private def self.execute_drop(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        index_name : String,
        desired : Set(DesiredIndex) = Set(DesiredIndex).new,
      ) : Nil
        begin
          # First gate attempt: the DDL statement under the DDL gate, so
          # it cannot deadlock against the server's index DDL.
          Manager.with_ddl_gate(db) do
            Manager.exec_ddl_with_deadlock_retry(
              db,
              Naming.drop_index_sql(domain, doc_type, field_name, index_type),
              max_attempts: 5,
            )
            still_needed = desired.any? do |other|
              other.field_name == field_name &&
                !Naming.create_statistics_sql(other.domain, other.doc_type, other.field_name, other.index_type).nil?
            end
            unless still_needed || Naming.create_statistics_sql(domain, doc_type, field_name, index_type).nil?
              Manager.exec_ddl_with_deadlock_retry(
                db,
                Naming.drop_statistics_sql(domain, doc_type, field_name),
                max_attempts: 5,
              )
            end
          end
        rescue ex
          Manager::Log.warn(exception: ex) do
            "Index retry DROP failed for #{domain}.#{doc_type}.#{field_name}: #{ex.class}: #{ex.message}"
          end
        end

        db.exec(
          "UPDATE doctype_indexes SET status = 'dropped', updated_at = now() WHERE index_name = $1",
          index_name
        )
      end
    end
  end
end
