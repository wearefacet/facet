# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "uri"
# `Migrate.db_reset`'s full surface: the retry-CLI constant `db_reset` calls
# (`src/index.cr` alone does not load it) and the IAM seed that inserts the
# dev admin account.
require "../../src/index/retry_cli"
require "../../src/iam/seed"

# `Migrate.db_reset` integration spec — the full drop → create → migrate →
# seed → hydrate cycle against a scratch database.
#
# This is the only spec that exercises the db_reset wiring end to end
# (boot and `db_reset` itself are only compile-checked elsewhere), so it pays
# the one-shot cost of a fresh migrate + seed run. It asserts the contract the
# boot path depends on: after `db_reset`, the currency registry is warm and
# built from the seeded `core.Currency` rows. The confirmation gate is
# skipped with `yes: true` — the gate's pure decision pass is covered in
# `spec/cli/chain_spec.cr`.

SCRATCH_DB = "facet_test_dbreset_#{Process.pid}"

# Builds the admin (`postgres` database) URL from the current DATABASE_URL.
private def dbreset_admin_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/postgres"
  uri.to_s
end

# Terminates stray backends and drops the scratch database. Idempotent.
private def dbreset_drop_scratch : Nil
  DB.open(dbreset_admin_url) do |db|
    db.exec(
      "SELECT pg_terminate_backend(pg_stat_activity.pid) " \
      "FROM pg_stat_activity " \
      "WHERE pg_stat_activity.datname = $1 AND pid <> pg_backend_pid()",
      SCRATCH_DB,
    )
    db.exec(%(DROP DATABASE IF EXISTS "#{SCRATCH_DB}"))
  end
end

# The tickers `data/seeds/core.Currency/documents.yml` carries. The registry
# keys on `content.ticker`; the seed ids equal the tickers.
private def dbreset_seed_tickers : Array(String)
  path = File.join(__DIR__, "..", "..", "data", "seeds", "core.Currency", "documents.yml")
  YAML.parse(File.read(path)).as_a.map(&.["content"]["ticker"].as_s)
end

describe "Facet::Migrate.db_reset" do
  it "ends with a warm registry hydrated from the seeded core.Currency rows" do
    original_url = ENV.fetch("DATABASE_URL")
    dbreset_drop_scratch

    scratch_url = begin
      uri = URI.parse(original_url)
      uri.path = "/#{SCRATCH_DB}"
      uri.to_s
    end

    begin
      ENV["DATABASE_URL"] = scratch_url
      Facet::Migrate.db_reset(yes: true)

      # The registry was refreshed from the scratch database's seeded rows.
      Facet::Currency::Registry.stale?.should be_false

      seed_tickers = dbreset_seed_tickers
      seed_tickers.each do |ticker|
        Facet::Util::Currency.registered?(ticker).should be_true
      end
      Facet::Util::Currency.all.size.should eq(seed_tickers.size)

      # The seed landed every row as a live projection on the fresh database.
      DB.open(scratch_url) do |db|
        rows = db.query_one(
          "SELECT count(*) FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'Currency' AND deleted_at IS NULL",
          as: Int64,
        )
        rows.should eq(seed_tickers.size)
      end
    ensure
      ENV["DATABASE_URL"] = original_url
      dbreset_drop_scratch
      # `db_reset` closed the singleton pool (and pointed it at the scratch
      # database before that) — restore the suite's worker-database pool and
      # the in-memory registry the other specs rely on.
      init_suite_database_pool
      register_seed_currencies
    end
  end
end
