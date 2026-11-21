# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "uri"

# `Migrate.down` integration spec — the full revert cycle against a scratch
# database: every migration up, then one-step revert, down-to-target, the
# error paths, and a full revert back to an empty `_migrations` table.
#
# One sequential `it` pays the migrate cost once and walks the state machine
# in order — the same pattern as `spec/migrate/db_reset_spec.cr`.

MIGRATEDOWN_SCRATCH_DB = "facet_test_migratedown_#{Process.pid}"

MIGRATEDOWN_MIGRATIONS_DIR = File.expand_path("../../db/migrations", __DIR__)

# Builds the admin (`postgres` database) URL from the current DATABASE_URL.
private def migratedown_admin_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/postgres"
  uri.to_s
end

# Builds the scratch database URL from the current DATABASE_URL.
private def migratedown_scratch_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/#{MIGRATEDOWN_SCRATCH_DB}"
  uri.to_s
end

# Terminates stray backends and drops the scratch database. Idempotent.
private def migratedown_drop_scratch : Nil
  DB.open(migratedown_admin_url) do |db|
    db.exec(
      "SELECT pg_terminate_backend(pg_stat_activity.pid) " \
      "FROM pg_stat_activity " \
      "WHERE pg_stat_activity.datname = $1 AND pid <> pg_backend_pid()",
      MIGRATEDOWN_SCRATCH_DB,
    )
    db.exec(%(DROP DATABASE IF EXISTS "#{MIGRATEDOWN_SCRATCH_DB}"))
  end
end

private def migratedown_create_scratch : Nil
  DB.open(migratedown_admin_url) do |db|
    db.exec(%(CREATE DATABASE "#{MIGRATEDOWN_SCRATCH_DB}"))
  end
end

private def migratedown_table_exists?(url : String, table : String) : Bool
  DB.open(url) do |db|
    count = db.query_one(
      "SELECT count(*) FROM information_schema.tables WHERE table_name = $1",
      table, as: Int64)
    count > 0
  end
end

private def migratedown_column_exists?(url : String, table : String, column : String) : Bool
  DB.open(url) do |db|
    count = db.query_one(
      "SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
      table, column, as: Int64)
    count > 0
  end
end

private def migratedown_applied(url : String) : Array(String)
  DB.open(url) do |db|
    db.query_all("SELECT filename FROM _migrations ORDER BY filename", as: String)
  end
end

private def migratedown_index_count(url : String, index_name : String) : Int64
  DB.open(url) do |db|
    db.query_one(
      "SELECT COUNT(*) FROM pg_indexes WHERE indexname = $1", index_name, as: Int64)
  end
end

describe "Facet::Migrate.down" do
  it "reverts migrations in reverse filename order with down-to-target semantics" do
    original_url = ENV.fetch("DATABASE_URL")
    migratedown_drop_scratch
    migratedown_create_scratch

    scratch_url = migratedown_scratch_url
    all_files = Dir.glob(File.join(MIGRATEDOWN_MIGRATIONS_DIR, "*.sql"))
      .map { |file| File.basename(file) }
      .sort!
    all_files.should_not be_empty # sanity: the full chain is present

    begin
      ENV["DATABASE_URL"] = scratch_url

      # All migrations up.
      Facet::Migrate.run
      migratedown_applied(scratch_url).should eq(all_files)

      # One step: the latest applied migration reverts and leaves the rest.
      Facet::Migrate.down(nil, yes: true)
      migratedown_applied(scratch_url).should eq(all_files[0..-2])

      # Down to a `NNNN` prefix target: everything newer reverts, the target
      # itself stays applied.
      Facet::Migrate.down("0008", yes: true)
      migratedown_applied(scratch_url).should eq(all_files[0..7]) # 0001..0008
      migratedown_table_exists?(scratch_url, "notifications").should be_false
      migratedown_table_exists?(scratch_url, "api_keys").should be_false
      migratedown_table_exists?(scratch_url, "background_jobs").should be_true
      # 0011 reverts in this pass — the secret store goes away.
      migratedown_table_exists?(scratch_url, "secret_staging").should be_false

      # Error paths leave the applied list untouched.
      expect_raises(Facet::Migrate::DownError, "unknown migration") do
        Facet::Migrate.down("0099", yes: true)
      end
      expect_raises(Facet::Migrate::DownError, "not applied") do
        Facet::Migrate.down("0009", yes: true)
      end
      migratedown_applied(scratch_url).should eq(all_files[0..7])

      # Down to the first migration: everything after 0001 reverts, the
      # document store itself stays. The artifact child-table indexes folded
      # into 0003 drop with their tables.
      Facet::Migrate.down("0001", yes: true)
      migratedown_applied(scratch_url).should eq([all_files.first])
      migratedown_table_exists?(scratch_url, "background_jobs").should be_false
      migratedown_table_exists?(scratch_url, "projections").should be_true
      migratedown_index_count(scratch_url, "artifact_grants_artifact_idx").should eq(0)

      # The final step reverts 0001 itself — back to an empty database.
      Facet::Migrate.down(nil, yes: true)
      migratedown_applied(scratch_url).should be_empty
      migratedown_table_exists?(scratch_url, "projections").should be_false
      migratedown_table_exists?(scratch_url, "mutations").should be_false

      # Nothing left to revert — a no-op, not an error.
      Facet::Migrate.down(nil, yes: true)
      migratedown_applied(scratch_url).should be_empty
    ensure
      ENV["DATABASE_URL"] = original_url
      migratedown_drop_scratch
    end
  end
end

describe "Facet::Migrate sections" do
  it "splits the UP and DOWN sections" do
    sql = "-- UP\nCREATE TABLE a(id int);\n\n-- DOWN\nDROP TABLE a;\n"
    up = Facet::Migrate.up_section(sql)
    up.should contain("CREATE TABLE a")
    up.should_not contain("DROP TABLE")

    down = Facet::Migrate.down_section(sql)
    down.should_not be_nil
    down.not_nil!.should contain("DROP TABLE a")
  end

  it "treats a missing or whitespace-only DOWN section as nil" do
    Facet::Migrate.down_section("-- UP\nCREATE TABLE a;").should be_nil
    Facet::Migrate.down_section("-- UP\nCREATE TABLE a;\n-- DOWN\n\n").should be_nil
  end

  it "ignores prose that starts with the marker word" do
    sql = "-- UP\n-- DOWN restores the function body from 0001.\nCREATE TABLE a;\n-- DOWN\nDROP TABLE a;\n"

    up = Facet::Migrate.up_section(sql)
    up.should contain("DOWN restores the function body")
    up.should contain("CREATE TABLE a")
    Facet::Migrate.down_section(sql).not_nil!.should contain("DROP TABLE a")
  end

  it "treats a marker with trailing spaces as a marker" do
    sql = "-- UP\nCREATE TABLE a;\n-- DOWN   \nDROP TABLE a;\n"
    Facet::Migrate.down_section(sql).not_nil!.should contain("DROP TABLE a")
  end
end
