# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/assistant/limits"
require "../../src/assistant/usage"

# The token-budget enforcement (`Assistant::Limits`).
#
# The rule: a rolling 30-day window of total tokens (input + output) over
# every conversation of the account, denied when `total >= budget`. An
# unset budget is unlimited and skips the ledger sum; a budget of `0`
# denies immediately. The `recorded_at` seam on `Usage.insert` makes the
# window boundaries a unit test — no SQL backdating.
#
# Roles and accounts come in through the mutation client (the same path
# the seed helper uses), because the budget reads the account projection's
# held roles.

# Inserts an `iam.Roles` document enabling the assistant with an optional
# budget. `id` is the bare role name; the document id becomes the
# qualified `iam.Roles.<id>`.
private def create_budget_role(db, id : String, budget : Int64?) : Nil
  content : Hash(String, JSON::Any) = {
    "name"        => JSON::Any.new(id),
    "description" => JSON::Any.new("Test role #{id}"),
    "permissions" => JSON::Any.new([
      JSON::Any.new({"action" => JSON::Any.new("read"), "on" => JSON::Any.new("*.*")}),
    ]),
    "connectivity" => JSON.parse(%(["assistant"])),
  }
  content["assistant_token_budget"] = JSON::Any.new(budget) if budget
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.#{id}",
    content: content.to_json,
    actioner_id: "system",
  )
end

# Creates a bare `iam.Account` projection holding the given role ids.
private def create_budget_account(db, role_ids : Array(String)) : String
  content : Hash(String, JSON::Any) = {
    "roles" => JSON::Any.new(role_ids.map { |r| JSON::Any.new(r) }),
  }
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: doc_id,
    content: content.to_json,
    actioner_id: "system",
  )
  doc_id
end

# One usage row for the account, `days_ago` inside or outside the window.
private def record_usage(db, account_id : String, total : Int64, days_ago : Int32? = nil) : Nil
  Facet::Assistant::Usage.insert(
    db, account_id, "conv_#{account_id}", "turn_#{Facet::Util::ScriptHelpers.ulid}",
    "test-model", total, 0_i64,
    recorded_at: days_ago ? Time.utc - days_ago.days : nil,
  )
end

describe Facet::Assistant::Limits do
  it "allows an account with no budget set (unlimited)" do
    with_db do |db|
      create_budget_role(db, "free", nil)
      account_id = create_budget_account(db, ["iam.Roles.free"])

      Facet::Assistant::Limits.allow?(db, account_id).should be_true
    end
  end

  it "allows an account under budget" do
    with_db do |db|
      create_budget_role(db, "capped", 1000_i64)
      account_id = create_budget_account(db, ["iam.Roles.capped"])
      record_usage(db, account_id, 999_i64)

      Facet::Assistant::Limits.allow?(db, account_id).should be_true
    end
  end

  it "denies when the usage exactly reaches the budget" do
    with_db do |db|
      create_budget_role(db, "exact", 1000_i64)
      account_id = create_budget_account(db, ["iam.Roles.exact"])
      record_usage(db, account_id, 400_i64)
      record_usage(db, account_id, 600_i64)

      Facet::Assistant::Limits.allow?(db, account_id).should be_false
    end
  end

  it "denies immediately on a zero budget" do
    with_db do |db|
      create_budget_role(db, "zero", 0_i64)
      account_id = create_budget_account(db, ["iam.Roles.zero"])

      Facet::Assistant::Limits.allow?(db, account_id).should be_false
    end
  end

  it "ignores usage older than 30 days and counts recent usage" do
    with_db do |db|
      create_budget_role(db, "window", 1000_i64)
      account_id = create_budget_account(db, ["iam.Roles.window"])

      # 31 days old — outside the rolling window: 1200 tokens alone would
      # exceed the budget, so `allowed` here proves the row is excluded.
      record_usage(db, account_id, 1200_i64, days_ago: 31)
      Facet::Assistant::Limits.allow?(db, account_id).should be_true

      # 29 days old — still inside the window, and it tips over the cap.
      record_usage(db, account_id, 1200_i64, days_ago: 29)
      Facet::Assistant::Limits.allow?(db, account_id).should be_false
    end
  end

  it "allows an unknown account (no roles, no budget)" do
    with_db do |db|
      Facet::Assistant::Limits.allow?(db, "acct_unknown").should be_true
    end
  end
end
