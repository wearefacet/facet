# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/assistant/usage"
require "json"

# Per-account token usage ledger (`assistant_usage` table).
#
# Covers the write path (`Usage.insert` — including the `estimated` flag
# and the `recorded_at` seam) and the read path (`Usage.total_for_account`)
# — per-account separation, window filtering, and the zero totals for an
# unknown account.

private def insert_usage(db, account_id, turn_id, input, output, **opts) : Nil
  Facet::Assistant::Usage.insert(
    db, account_id, "conv_#{account_id}", turn_id, "test-model", input, output, **opts
  )
end

# Reads one ledger row's `estimated` flag by turn id.
private def estimated_flag(db, turn_id) : Bool
  db.query_one(
    "SELECT estimated FROM assistant_usage WHERE turn_id = $1", turn_id, as: Bool)
end

describe Facet::Assistant::Usage do
  it "sums exact input and output totals per account over a window" do
    with_db do |db|
      insert_usage(db, "acct_1", "turn_1", 100, 20)
      insert_usage(db, "acct_1", "turn_2", 50, 10)
      insert_usage(db, "acct_2", "turn_3", 7, 3)

      # Backdate the first row so a short window can exclude it while the
      # two `now()` rows stay inside.
      db.exec(
        "UPDATE assistant_usage SET recorded_at = now() - interval '2 days' WHERE turn_id = 'turn_1'",
      )

      day_start = Time.utc.at_beginning_of_day
      day_end = Time.utc + 1.day

      # The windowed sum sees only the row recorded today.
      totals = Facet::Assistant::Usage.total_for_account(db, "acct_1", day_start, day_end)
      totals.input.should eq(50)
      totals.output.should eq(10)
      totals.total.should eq(60)

      # The unbounded sum sees both rows.
      all_time = Facet::Assistant::Usage.total_for_account(db, "acct_1")
      all_time.input.should eq(150)
      all_time.output.should eq(30)
      all_time.total.should eq(180)

      # The `since` bound is inclusive, the `to` bound exclusive.
      from_here = Facet::Assistant::Usage.total_for_account(db, "acct_1", day_start)
      from_here.total.should eq(60)
      until_there = Facet::Assistant::Usage.total_for_account(db, "acct_1", nil, day_start)
      until_there.total.should eq(120)

      # The second account's numbers stay separate.
      other = Facet::Assistant::Usage.total_for_account(db, "acct_2")
      other.input.should eq(7)
      other.output.should eq(3)
      other.total.should eq(10)
    end
  end

  it "returns zeros for an unknown account" do
    with_db do |db|
      totals = Facet::Assistant::Usage.total_for_account(db, "acct_unknown")
      totals.input.should eq(0)
      totals.output.should eq(0)
      totals.total.should eq(0)
    end
  end

  it "defaults to estimated = false and now() recording" do
    with_db do |db|
      insert_usage(db, "acct_est", "turn_est_real", 10, 5)

      estimated_flag(db, "turn_est_real").should be_false
      recorded = db.query_one(
        "SELECT recorded_at FROM assistant_usage WHERE turn_id = 'turn_est_real'", as: Time)
      # The column default `now()` is pinned to UTC; the row must land
      # within a minute of the spec clock.
      (Time.utc - recorded).abs.should be < 1.minute
    end
  end

  it "writes an estimated row when the flag is set" do
    with_db do |db|
      insert_usage(db, "acct_est", "turn_est_flag", 30, 8, estimated: true)

      estimated_flag(db, "turn_est_flag").should be_true
      totals = Facet::Assistant::Usage.total_for_account(db, "acct_est")
      totals.total.should eq(38)
    end
  end

  it "writes an explicit recorded_at outside the default clock" do
    with_db do |db|
      backdated = Time.utc - 45.days
      insert_usage(db, "acct_back", "turn_back", 100, 0, recorded_at: backdated)

      # The windowed sum at 30 days excludes it; the unbounded sum sees it.
      Facet::Assistant::Usage.total_for_account(
        db, "acct_back", since: Time.utc - 30.days
      ).total.should eq(0)
      Facet::Assistant::Usage.total_for_account(db, "acct_back").total.should eq(100)
    end
  end
end
