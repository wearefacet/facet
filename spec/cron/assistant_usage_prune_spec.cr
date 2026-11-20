# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/cron/assistant_usage_prune"
require "../../src/assistant/usage"
require "../../src/assistant/conversation"
require "../../src/util/script_helpers"

# Usage-ledger retention (`Cron::AssistantUsagePrune`).
#
# The prune anchors on conversation staleness: a row is prunable when it
# is older than the retention window AND its conversation has not been
# updated within the window (or is gone — the ledger carries no FK).
# Specs age rows and conversations directly with SQL and pass explicit
# retention windows to `AssistantUsagePrune.prune`, like the tombstone
# prune specs do.
#
# The suite truncates `mutations` and `projections` between examples but
# not the assistant tables, so the local `before_each` clears them to
# keep the count assertions exact.

# ── Helpers ──────────────────────────────────────────────────────────────

# Creates one conversation row and returns its id.
def seed_prune_conversation(db : DB::Connection) : String
  unique = Facet::Util::ScriptHelpers.ulid
  result = Facet::Assistant::Conversation.create(
    db, "session-#{unique}", "cache-#{unique}", nil, "{}",
  )
  unless result.is_a?(Facet::Assistant::Conversation::Result::Created)
    raise "conversation create failed: #{result}"
  end
  result.record.id
end

# Creates one ledger row for the conversation and returns the row id.
# `Usage.insert` generates the row id internally, so the id is read back
# through the (unique) turn id.
def seed_prune_usage(db : DB::Connection, conversation_id : String) : String
  turn_id = "turn-#{Facet::Util::ScriptHelpers.ulid}"
  Facet::Assistant::Usage.insert(
    db, "acct-prune-spec", conversation_id, turn_id, "test-model", 100, 20
  )
  db.query_one("SELECT id FROM assistant_usage WHERE turn_id = $1", turn_id, as: String)
end

def age_prune_usage(db : DB::Connection, usage_id : String, days : Int32) : Nil
  db.exec(
    "UPDATE assistant_usage SET recorded_at = now() - make_interval(days => $1) WHERE id = $2",
    days, usage_id,
  )
end

def age_prune_conversation(db : DB::Connection, conversation_id : String, days : Int32) : Nil
  db.exec(
    "UPDATE agent_conversations SET updated_at = now() - make_interval(days => $1) WHERE id = $2",
    days, conversation_id,
  )
end

def prune_usage_row_count(db : DB::Connection) : Int64
  db.query_one("SELECT COUNT(*) FROM assistant_usage", as: Int64)
end

# ── Specs ────────────────────────────────────────────────────────────────

describe Facet::Cron::AssistantUsagePrune do
  before_each do
    with_db do |db|
      db.exec("DELETE FROM assistant_usage")
      db.exec("DELETE FROM agent_conversations")
    end
  end

  it "prunes rows of a conversation not updated within the window" do
    with_db do |db|
      stale_conv = seed_prune_conversation(db)
      fresh_conv = seed_prune_conversation(db)
      stale_row = seed_prune_usage(db, stale_conv)
      seed_prune_usage(db, fresh_conv)
      age_prune_usage(db, stale_row, 40)
      age_prune_conversation(db, stale_conv, 40)

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30)
      deleted.should eq(1)
      prune_usage_row_count(db).should eq(1)
    end
  end

  it "keeps every row of a conversation updated within the window, however old the rows are" do
    with_db do |db|
      conv = seed_prune_conversation(db)
      old_row = seed_prune_usage(db, conv)
      seed_prune_usage(db, conv)
      age_prune_usage(db, old_row, 400)

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30)
      deleted.should eq(0)
      prune_usage_row_count(db).should eq(2)
    end
  end

  it "keeps a row recorded inside the window even when its conversation is stale" do
    with_db do |db|
      conv = seed_prune_conversation(db)
      row = seed_prune_usage(db, conv)
      # The conversation went quiet 40 days ago, but this row was
      # recorded 10 days ago — a turn whose write lagged the last
      # `Conversation.touch` (the touch fires at turn start, the ledger
      # write at turn end). The `recorded_at` floor keeps it.
      age_prune_conversation(db, conv, 40)
      age_prune_usage(db, row, 10)

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30)
      deleted.should eq(0)
      prune_usage_row_count(db).should eq(1)
    end
  end

  it "prunes orphaned rows (conversation gone) once they age past the window" do
    with_db do |db|
      # The ledger carries no FK, so a row can point at a conversation
      # row that does not exist.
      row = seed_prune_usage(db, "conv-#{Facet::Util::ScriptHelpers.ulid}")
      age_prune_usage(db, row, 31)

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30)
      deleted.should eq(1)
      prune_usage_row_count(db).should eq(0)
    end
  end

  it "keeps a young orphaned row until it ages past the window" do
    with_db do |db|
      seed_prune_usage(db, "conv-#{Facet::Util::ScriptHelpers.ulid}")

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30)
      deleted.should eq(0)
      prune_usage_row_count(db).should eq(1)
    end
  end

  it "never deletes when the retention window is 0" do
    with_db do |db|
      conv = seed_prune_conversation(db)
      row = seed_prune_usage(db, conv)
      age_prune_usage(db, row, 400)
      age_prune_conversation(db, conv, 400)

      deleted = Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 0)
      deleted.should eq(0)
      prune_usage_row_count(db).should eq(1)
    end
  end

  it "runs as a no-op pass with the default config (retention 0 = never)" do
    Facet::Config.instance.assistant.usage_retention_days.should eq(0)

    with_db do |db|
      conv = seed_prune_conversation(db)
      row = seed_prune_usage(db, conv)
      age_prune_usage(db, row, 400)
      age_prune_conversation(db, conv, 400)
    end

    Facet::Cron::AssistantUsagePrune.call

    with_db do |db|
      prune_usage_row_count(db).should eq(1)
    end
  end

  it "is idempotent: a second pass deletes nothing" do
    with_db do |db|
      conv = seed_prune_conversation(db)
      row = seed_prune_usage(db, conv)
      age_prune_usage(db, row, 31)
      age_prune_conversation(db, conv, 31)

      Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30).should eq(1)
      Facet::Cron::AssistantUsagePrune.prune(db, retention_days: 30).should eq(0)
      prune_usage_row_count(db).should eq(0)
    end
  end
end
