# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe Validation do
    # ── Migration validation: no migration needed ─────────────────────

    it "returns no migration errors when schema_version is 1" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 1
      )
      errors = Validation.validate(defn, current_version: 1)
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    it "returns no migration errors when current_version == schema_version" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      errors = Validation.validate(defn, current_version: 3)
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    # ── Migration validation: complete coverage ───────────────────────

    it "validates when all migrations from current_version to schema_version-1 are present" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      errors = Validation.validate(defn, current_version: 1)
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    it "validates migration from version 2 to 3 when current_version is 2" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      errors = Validation.validate(defn, current_version: 2)
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    # ── Migration validation: gaps detected ───────────────────────────

    it "detects missing migration from v1 to v2" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {} of String => String
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.should_not be_empty
      migration_errors.any?(&.message.includes?("v1")).should be_true
    end

    it "detects missing migration from v2 to v3 when v1 is present" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1"}
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.any?(&.message.includes?("v2")).should be_true
      # v1 should not be in errors
      migration_errors.any?(&.message.includes?("v1")).should be_false
    end

    it "reports all missing migration gaps" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 5,
        migrations: {} of String => String
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.size.should eq(4)
      migration_errors.any?(&.message.includes?("v1")).should be_true
      migration_errors.any?(&.message.includes?("v2")).should be_true
      migration_errors.any?(&.message.includes?("v3")).should be_true
      migration_errors.any?(&.message.includes?("v4")).should be_true
    end

    # ── Migration validation: invalid entries ─────────────────────────

    it "rejects a migration version key that is not a valid integer" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {"foo" => "migrate_from_1"}
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.any? { |e| e.message.includes?("foo") && e.message.includes?("valid integer") }.should be_true
    end

    it "rejects a migration version key >= schema_version" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.any? { |e| e.message.includes?(">= current schema_version") }.should be_true
    end

    it "rejects an empty migration function name" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {"1" => ""}
      )
      errors = Validation.validate(defn, current_version: 1)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.any?(&.message.includes?("empty")).should be_true
    end

    # ── Combined validation (basic + migration) ───────────────────────

    it "returns both basic validation errors and migration errors together" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 0, # invalid (basic validation fails)
        migrations: {} of String => String
      )
      errors = Validation.validate(defn, current_version: 0)
      # Should have basic error about schema_version
      errors.any? { |e| e.message.includes?("schema_version") && e.message.includes?("0") }.should be_true
      # No migration error expected since range (0...0) is empty
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    it "returns no migration errors when gap is covered by current_version being higher" do
      # current_version=2, schema_version=3, migration from 2 exists
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"2" => "migrate_from_2"}
      )
      errors = Validation.validate(defn, current_version: 2)
      migration_errors = errors.select(&.message.includes?("Migration"))
      migration_errors.should be_empty
    end

    # ── Schema v1 edge cases ──────────────────────────────────────────

    it "requires no migrations when bumping from v1 to v2 if migration is present" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {"1" => "migrate_from_1"}
      )
      errors = Validation.validate(defn, current_version: 1)
      errors.select(&.message.includes?("Migration")).should be_empty
    end

    it "reports error when bumping from v1 to v2 with missing migration" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2
      )
      errors = Validation.validate(defn, current_version: 1)
      errors.any? { |e| e.message.includes?("Migration") && e.message.includes?("v1") }.should be_true
    end
  end
end
