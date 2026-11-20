# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/domain"
require "../../src/document"
require "../../src/doctype/seed"
require "../../src/rbac"
require "../../src/mutation/client"

# Re-seeds the core doctype schema definitions (core.DocType, core.Domain,
# etc.) after the per-spec TRUNCATE wipes them. `Document::Update` resolves
# the doctype definition via `DefinitionStore.fetch`, which queries
# `doc_type='DocType' AND id=<qualified>` — so the schema definitions must
# exist as `core.DocType` rows. `Seed.seed` is the canonical path that
# does this (it is idempotent and safe to call per-test).
private def seed_core_schemas(db)
  restore_seeded_baseline(db)
end

# Integration: the authoring-time hook validation gate in
# `Document::Update.validate_rbac_definitions?` rejects malformed hooks on a
# `core.Domain` document, and `Domain::Check` surfaces the same issues as
# `:hooks` warnings. Mirrors the pattern in `spec/domain/check_spec.cr`.
module Facet::Domain
  describe "hook authoring gate" do
    it "rejects a core.Domain PATCH with a syntax-error hook script" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-hooks-syntax"
        ensure_domain(db, domain_id)

        patch = %({"hooks": [{"id": "bad", "kind": "event", "script": "this is not lua", "source": {"domain": "x"}}]})
        result = Facet::Document::Update.call(
          db, "core", "Domain", domain_id, patch,
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("hooks validation failed")
        err.details.should_not be_nil
        err.details.not_nil!.any?(&.message.includes?("syntax")).should be_true
      end
    end

    it "rejects a core.Domain PATCH with a missing required export" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-hooks-missing-export"
        ensure_domain(db, domain_id)

        patch = %({"hooks": [{"id": "h", "kind": "event", "script": "local export = {} return export", "source": {"domain": "x"}}]})
        result = Facet::Document::Update.call(
          db, "core", "Domain", domain_id, patch,
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.any?(&.message.includes?("on_event")).should be_true
      end
    end

    it "rejects a core.Domain PATCH with an invalid cron expression" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-hooks-bad-cron"
        ensure_domain(db, domain_id)

        patch = %({"hooks": [{"id": "h", "kind": "schedule", "schedule": "@daily", "script": "local export = {} function export.on_schedule(ctx) end return export"}]})
        result = Facet::Document::Update.call(
          db, "core", "Domain", domain_id, patch,
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.any?(&.message.includes?("not in the supported form")).should be_true
      end
    end

    it "accepts a core.Domain PATCH with valid hooks" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-hooks-valid"
        ensure_domain(db, domain_id)

        patch = %({"hooks": [{"id": "h", "kind": "event", "script": "local export = {} function export.on_event(ctx) end return export", "source": {"domain": "x"}}]})
        result = Facet::Document::Update.call(
          db, "core", "Domain", domain_id, patch,
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "accepts a core.Domain PATCH with no hooks (backward compat)" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-hooks-none"
        ensure_domain(db, domain_id)

        patch = %({"description": "no hooks on this domain"})
        result = Facet::Document::Update.call(
          db, "core", "Domain", domain_id, patch,
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Update::Result)
      end
    end
  end

  describe Check do
    it "surfaces hooks issues as :hooks domain warnings" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-check-hooks"
        ensure_domain(db, domain_id)

        # Persist a domain with a broken hook (missing on_event) directly —
        # bypassing the authoring gate which would otherwise reject it.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: domain_id,
          content: %({"hooks": [{"id": "broken", "kind": "event", "script": "local export = {} return export", "source": {"domain": "x"}}]}),
          actioner_id: "system:test",
        )

        result = Check.call(db, domain_id).as(Check::Result)
        hooks_issues = result.domain_issues.select(&.category.==(:hooks))
        hooks_issues.size.should be >= 1
        hooks_issues.first.field.should eq("hooks.broken.script")
        hooks_issues.first.message.should contain("'on_event'")
      end
    end

    it "does not surface :hooks issues for a domain with no hooks" do
      with_db do |db|
        domain_id = "test-check-no-hooks"
        ensure_domain(db, domain_id)

        result = Check.call(db, domain_id).as(Check::Result)
        result.domain_issues.none?(&.category.==(:hooks)).should be_true
      end
    end

    it "does not surface :hooks issues for a domain with valid hooks" do
      with_db do |db|
        seed_core_schemas(db)
        domain_id = "test-check-valid-hooks"
        ensure_domain(db, domain_id)
        # Persist valid hooks directly — bypassing the gate to test the read
        # path in isolation.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: domain_id,
          content: %({"hooks": [{"id": "h", "kind": "event", "script": "local export = {} function export.on_event(ctx) end return export", "source": {"domain": "x"}}]}),
          actioner_id: "system:test",
        )

        result = Check.call(db, domain_id).as(Check::Result)
        result.domain_issues.none?(&.category.==(:hooks)).should be_true
      end
    end
  end
end
