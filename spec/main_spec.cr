# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-205 — the boot schema gate. The server's first boot query reads
# `projections` (the currency-registry warm-up); on a database the
# migrations never built, that read died with a raw PQError and a long
# backtrace. The boot path (src/main.cr, `run_server`) now probes the
# table before the warm-up and raises "database not migrated — run facet
# migrate" when it is absent, so an un-migrated database names the
# problem and the remedy like every other boot failure.
#
# `require_migrated` is a file-private helper in src/main.cr, which
# cannot be required from specs (it runs `Facet::CLI.run` at load time;
# spec_helper mirrors its dotenv/TZ handling inline instead). This spec
# therefore pins the probe contract the helper implements: the
# `to_regclass('projections')` predicate answers true on a migrated
# database and false when the table is not on the search path — the two
# outcomes the gate's raise/not-raise decision turns on.

require "./spec_helper"

describe "Boot schema gate probe (B-205)" do
  it "answers true on a migrated database" do
    with_db do |db|
      db.query_one("SELECT to_regclass('projections') IS NOT NULL", as: Bool).should be_true
    end
  end

  it "answers false when projections is not on the search path" do
    conn = db_open
    begin
      conn.exec("SET search_path = pg_catalog")
      conn.query_one("SELECT to_regclass('projections') IS NOT NULL", as: Bool).should be_false
    ensure
      conn.close
    end
  end
end
