# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "uri"
# `Migrate.seed_core`'s full surface: the retry-CLI constant the seed tail
# calls (`src/index.cr` alone does not load it).
require "../../src/index/retry_cli"

# `Migrate.seed_core` integration spec — migrate + seed on a scratch
# database, then a second run that must change nothing.
#
# This is the contract the container entrypoint depends on: the chain
# `facet migrate && facet seed:core` boots an empty volume (schema + core
# doctypes + currency registry) and is idempotent on a seeded one. It
# never drops — the scratch database is created and dropped by this spec,
# not by the command under test.

# Top-level constants are program-wide across spec files — the seedcore_
# prefix keeps this one clear of the other migrate specs (db_reset_spec
# owns the plain SCRATCH_DB name).
SEEDCORE_SCRATCH_DB = "facet_test_seedcore_#{Process.pid}"

# Builds the admin (`postgres` database) URL from the current DATABASE_URL.
private def seedcore_admin_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/postgres"
  uri.to_s
end

# Terminates stray backends and drops the scratch database. Idempotent.
private def seedcore_drop_scratch : Nil
  DB.open(seedcore_admin_url) do |db|
    db.exec(
      "SELECT pg_terminate_backend(pg_stat_activity.pid) " \
      "FROM pg_stat_activity " \
      "WHERE pg_stat_activity.datname = $1 AND pid <> pg_backend_pid()",
      SEEDCORE_SCRATCH_DB,
    )
    db.exec(%(DROP DATABASE IF EXISTS "#{SEEDCORE_SCRATCH_DB}"))
  end
end

# Live projection counts the idempotency assertion compares. A second
# `seed_core` run must leave every one of these untouched.
private def seedcore_count(db) : Int64
  db.query_one(
    "SELECT count(*) FROM projections WHERE deleted_at IS NULL",
    as: Int64,
  )
end

# The tickers `data/seeds/core.Currency/documents.yml` carries — the same
# expectation the db_reset spec pins for the registry hydration.
private def seedcore_seed_tickers : Array(String)
  path = File.join(__DIR__, "..", "..", "data", "seeds", "core.Currency", "documents.yml")
  YAML.parse(File.read(path)).as_a.map(&.["content"]["ticker"].as_s)
end

describe "Facet::Migrate.seed_core" do
  it "seeds an empty migrated database and is idempotent on the second run" do
    original_url = ENV.fetch("DATABASE_URL")
    seedcore_drop_scratch

    scratch_url = begin
      uri = URI.parse(original_url)
      uri.path = "/#{SEEDCORE_SCRATCH_DB}"
      uri.to_s
    end

    begin
      ENV["DATABASE_URL"] = scratch_url
      DB.open(seedcore_admin_url) { |db| db.exec(%(CREATE DATABASE "#{SEEDCORE_SCRATCH_DB}")) }

      # The entrypoint chain: migrate first, then seed:core. Neither
      # command may drop anything.
      Facet::Migrate.run
      Facet::Migrate.seed_core

      # The currency registry was hydrated from the scratch database's
      # seeded rows.
      Facet::Currency::Registry.stale?.should be_false
      seed_tickers = seedcore_seed_tickers
      seed_tickers.each do |ticker|
        Facet::Util::Currency.registered?(ticker).should be_true
      end

      # Core doctypes and the currency rows are live projections.
      before = 0_i64
      DB.open(scratch_url) do |db|
        doctypes = db.query_one(
          "SELECT count(*) FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL",
          as: Int64,
        )
        doctypes.should be > 0

        currencies = db.query_one(
          "SELECT count(*) FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'Currency' AND deleted_at IS NULL",
          as: Int64,
        )
        currencies.should eq(seed_tickers.size)

        before = seedcore_count(db)
      end

      # The second run changes nothing: same projection count, and the
      # seeded database reports `All core doctypes already present`.
      Facet::Migrate.seed_core
      DB.open(scratch_url) do |db|
        after = seedcore_count(db)
        after.should eq(before)
      end
    ensure
      ENV["DATABASE_URL"] = original_url
      seedcore_drop_scratch
      # `seed_core` closed the singleton pool (and pointed it at the
      # scratch database before that) — restore the suite's
      # worker-database pool and the in-memory registry the other specs
      # rely on.
      init_suite_database_pool
      register_seed_currencies
    end
  end
end
