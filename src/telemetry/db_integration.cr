# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Lightweight DB instrumentation for OpenTelemetry compatible with crystal-db 0.14.x.
#
# The upstream opentelemetry/integrations/db.cr depends on `connection.context.uri`
# which does not exist in crystal-db 0.14.0 (ConnectionContext is an abstract module
# with no `.uri` method). This file provides a compatible alternative.
#
# Two hook points:
#
# - `DB::Statement#around_query_or_exec` — one `db.query` span per SQL statement.
#   Pooled calls, connection-level calls, and transaction calls all pass here.
#   crystal-db 0.14 defines `def_around_query_or_exec` on `DB::Statement` itself,
#   so reopening the class after `pg` is loaded works (the hook chains through
#   `previous_def` and keeps crystal-db's own query logging).
# - `DB::BeginTransaction#transaction` — one `db.transaction` span per
#   transaction block.
#
# Known limit: for a read (`query`) call the span ends when the driver receives
# the row description. The time spent reading rows back lands on the enclosing
# span. `exec` calls consume the full result, so their spans are exact.
#
# `PG::Connection#exec_all` (used by migrations) bypasses `DB::Statement` and
# stays uninstrumented.
#
# See also: mutation/client.cr for granular mutation.create/update/delete spans.
require "opentelemetry"
require "db"

# Instrument DB::BeginTransaction#transaction
module DB::BeginTransaction
  def transaction(& : Transaction -> T) : T? forall T
    Facet::Telemetry.trace "db.transaction" do |_span|
      previous_def do |txn|
        yield txn
      end
    end
  end
end

module DB
  class Statement
    # Lower-case text of statements that only open or close a transaction.
    # The enclosing `db.transaction` span already measures them, so they get
    # no span of their own. Savepoints stay instrumented: they show the
    # nested-transaction structure.
    TRANSACTION_CONTROL_STATEMENTS = {"begin", "commit", "rollback"}

    # Maximum size of the `db.statement` span attribute. Long list filters
    # and mutation SQL would bloat trace exports otherwise.
    MAX_STATEMENT_ATTRIBUTE_SIZE = 2000

    def_around_query_or_exec do |_args|
      if telemetry_control_statement?
        yield
      else
        Facet::Telemetry.trace("db.query") do |span|
          span["db.system"] = "postgresql"
          span["db.statement"] = telemetry_statement_attribute
          yield
        end
      end
    end

    private def telemetry_control_statement? : Bool
      TRANSACTION_CONTROL_STATEMENTS.includes?(command.strip.downcase)
    end

    private def telemetry_statement_attribute : String
      sql = command.strip
      sql.size <= MAX_STATEMENT_ATTRIBUTE_SIZE ? sql : sql[0, MAX_STATEMENT_ATTRIBUTE_SIZE]
    end
  end
end
