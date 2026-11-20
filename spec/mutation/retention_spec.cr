# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/system_settings_helper"
require "../../src/mutation/retention"

# The single home of the effective mutation-retention window. Compaction
# (`Cron::MutationCompaction`) and the rollback 404 body
# (`Audit::Rollback.fetch_mutation`) must read the same numbers: the
# runtime pin on `core.SystemSettings` wins over the file value, the
# per-doctype override applies over a non-zero base, and a base of `0`
# keeps history forever — overrides included.
describe "Mutation::Retention" do
  it "resolves the base window from the file config when no pin exists" do
    with_db do |db|
      expected = Facet::Config.instance.mutations.retention_days
      Facet::Mutation::Retention.base_days(db).should eq(expected)
    end
  end

  it "prefers the runtime pin over the file value" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"mutations": {"retention_days": 5}}))
      begin
        Facet::Mutation::Retention.base_days(db).should eq(5)
      ensure
        pin_settings(db, %({"mutations": {"retention_days": null}}))
      end
    end
  end

  it "applies the per-doctype override over a non-zero base" do
    cfg = Facet::Config.instance
    cfg.mutations.retention_overrides["retentionspec.Widget"] = 7
    begin
      with_db do |db|
        base = Facet::Config.instance.mutations.retention_days
        Facet::Mutation::Retention.effective_days(db, "retentionspec", "Widget").should eq(7)
        Facet::Mutation::Retention.effective_days(db, "retentionspec", "Other").should eq(base)
      end
    ensure
      cfg.mutations.retention_overrides.delete("retentionspec.Widget")
    end
  end

  it "ignores the override when the base window is 0 (keep forever)" do
    cfg = Facet::Config.instance
    cfg.mutations.retention_overrides["retentionspec.Widget"] = 7
    begin
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"mutations": {"retention_days": 0}}))
        begin
          Facet::Mutation::Retention.base_days(db).should eq(0)
          Facet::Mutation::Retention.effective_days(db, "retentionspec", "Widget").should eq(0)
        ensure
          pin_settings(db, %({"mutations": {"retention_days": null}}))
        end
      end
    ensure
      cfg.mutations.retention_overrides.delete("retentionspec.Widget")
    end
  end
end
