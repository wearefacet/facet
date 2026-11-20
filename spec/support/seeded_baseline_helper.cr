# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Seeded baseline restore ────────────────────────────────────────────────
#
# Fast fixture re-seed for specs that need the production corpus after the
# per-example TRUNCATE. `Facet::Doctype::Seed.seed` rebuilds the corpus
# through the full mutation pipeline (~320 ms per call); this helper copies
# the seeded rows back from snapshot tables (~13 ms).
#
# The snapshot is taken in `Spec.before_suite` (spec_helper.cr) right after
# the worker database is cloned from the seeded template: one
# `spec_baseline_<table>` copy per truncated table. Each worker process owns
# its database, so snapshots are never shared or stale, and they die with
# the worker database at suite teardown.
#
# The restore is additive and idempotent, matching `Seed.seed` semantics:
# baseline rows go back with `ON CONFLICT DO NOTHING`, rows the example
# already created stay untouched. Restored rows are byte-identical to
# seeded rows except the default `core.CollectionView` projection ids,
# which `Seed.seed` mints fresh on every run (the seed writes those views
# without a fixed doc_id). Specs address seeded views by `parent_id`,
# never by projection id, so the difference is invisible to the suite.
#
# Use `restore_seeded_baseline` for fixture setup only. Specs that test
# `Doctype::Seed` behaviour itself (seed projection staging, seeded view
# children, view idempotency) call `Doctype::Seed.seed` directly.
module SeededBaseline
  # The tables the per-example TRUNCATE wipes. The same list builds the
  # snapshot, the restore, and the TRUNCATE statement. FK children of
  # `projections` (`secrets`, `auth_state`) are handled by the TRUNCATE's
  # CASCADE, exactly as the spec hook does.
  TABLES = %w[mutations projections agent_conversations agent_turns assistant_usage account_settings secret_staging]

  TRUNCATE_SQL = "TRUNCATE #{TABLES.join(", ")} RESTART IDENTITY CASCADE"

  # Copies the worker database's seeded baseline into snapshot tables.
  # Runs once per suite, before any example can truncate the corpus.
  def self.create_snapshot(db : DB::Connection) : Nil
    TABLES.each do |table|
      db.exec("DROP TABLE IF EXISTS spec_baseline_#{table}")
      db.exec("CREATE TABLE spec_baseline_#{table} AS SELECT * FROM #{table}")
    end
  end

  # True when this database owns a seeded-baseline snapshot.
  private def self.snapshot_present?(db : DB::Connection) : Bool
    db.query_one?(
      "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'spec_baseline_projections'",
      as: Int32,
    ) == 1
  end

  # Restores the seeded baseline on *db*. Additive and idempotent, exactly
  # like `Seed.seed`: baseline rows are inserted with `ON CONFLICT DO
  # NOTHING` and example-created rows are left alone. The per-example
  # TRUNCATE hook provides the clean slate; when the helper runs mid-example
  # (after `ensure_domain`, account fixtures, ...), earlier fixture rows
  # must survive — the seed preserved them, and so does the restore.
  #
  # `harness.bypass_projection_triggers` must be set while the baseline
  # `mutations` rows go back in, or the projection upsert trigger re-fires
  # on all 72 rows. The GUC is set at session scope and reset in an `ensure`,
  # NOT with `SET LOCAL`: a restore inside a caller's outer transaction
  # would otherwise keep the bypass armed until that outer transaction ends
  # and silently swallow every later projection upsert in the example
  # (observed: `Draft.create` failed with `DB::NoResultsError`).
  #
  # Falls back to the real seed on databases without a snapshot (e.g. a
  # scratch database a spec repointed `DATABASE_URL` at).
  def self.restore(db : DB::Connection) : Nil
    unless snapshot_present?(db)
      Facet::Doctype::Seed.seed(db)
      return
    end

    Facet::Database.with_transaction(db, ignore_if_set: true) do |conn|
      conn.exec("SET harness.bypass_projection_triggers = 'baseline_restore'")
      begin
        TABLES.each do |table|
          conn.exec("INSERT INTO #{table} SELECT * FROM spec_baseline_#{table} ON CONFLICT DO NOTHING")
        end
      ensure
        conn.exec("RESET harness.bypass_projection_triggers")
      end
    end

    # The restore bypasses the seed's per-doctype cache invalidations.
    Facet::Doctype::DefinitionStore.cache.clear
  end
end

# Fixture helper: brings back the seeded corpus after the per-example
# TRUNCATE. Drop-in replacement for `Facet::Doctype::Seed.seed` in specs
# that only need the corpus present.
def restore_seeded_baseline(db : DB::Connection) : Nil
  SeededBaseline.restore(db)
end
