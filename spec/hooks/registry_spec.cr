# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"
require "../../src/domain"
require "../../src/document"
require "../../src/doctype/seed"
require "../../src/rbac"
require "../../src/mutation/client"

# Re-seeds the core doctype schema definitions (core.DocType, core.Domain,
# etc.) after the per-spec TRUNCATE wipes them. `DefinitionStore.fetch`
# (used by `Document::Update` and `Hooks::Registry`'s neighbours) queries
# `doc_type='DocType' AND id=<qualified>` — so the schema definitions must
# exist as `core.DocType` rows. `Seed.seed` is the canonical path.
private def seed_core_schemas(db)
  restore_seeded_baseline(db)
end

# A minimal valid `event` hook script with the required `on_event` export.
# The registry only inspects `source`/`kind`/`id`, not the script body —
# but the authoring gate (used by `ensure_domain_with_hooks`) rejects
# scripts that fail to compile or export `on_event`.
EVENT_SCRIPT = "local export = {} function export.on_event(ctx) end return export"

# A minimal valid `schedule` hook script with the required `on_schedule`
# export. The registry must skip `schedule` hooks; this script is only
# here so the authoring gate does not reject the domain carrying it.
SCHEDULE_SCRIPT = "local export = {} function export.on_schedule(ctx) end return export"

# Persists a `core.Domain` document with the given `hooks` array via the
# documented document create path, which runs the authoring-time hook
# validation gate. The domain is marked published (no `draft`) unless
# `draft: true` is requested. Idempotent on the doc id.
def ensure_domain_with_hooks(db, domain_id, hooks_json, draft = false)
  body = %({"hooks": #{hooks_json}#{" , \"draft\": true" if draft}})
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain_id,
    content: body,
    actioner_id: "system:test",
  )
end

# Persists a minimal `core.DocType` projection row in the given source
# domain so the registry's domain-wide hook expansion has a doctype to
# expand into. The row carries only the `doctype` and `domain` content
# fields the registry's `fetch_doctypes_in_domain` query reads — full
# schema validation is not exercised here.
def seed_doctype_in_domain(db, source_domain, doctype_name)
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{source_domain}.#{doctype_name}",
    content: %({"doctype": "#{doctype_name}", "domain": "#{source_domain}"}),
    actioner_id: "system:test",
  )
end

module Facet::Hooks
  describe Registry do
    # ── Build picks up event hooks from a published domain ───────────────

    it "builds event hooks from a published domain" do
      with_db do |db|
        seed_core_schemas(db)
        ensure_domain_with_hooks(
          db, "sales",
          %([{"id": "on-contract", "kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy", "doc_type": "Contract"}}]),
        )

        registry = Registry.new
        registry.build(db)

        hooks = registry.hooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        hooks.first.id.should eq("on-contract")
        hooks.first.kind.should eq(:event)
      end
    end

    it "excludes hooks declared on a draft domain" do
      with_db do |db|
        seed_core_schemas(db)
        ensure_domain_with_hooks(
          db, "_draft-sales",
          %([{"id": "h", "kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy"}}]),
          draft: true,
        )

        registry = Registry.new(
          domain_enabled: ->(d : String) { !d.starts_with?('_') },
        )
        registry.build(db)

        registry.hooks_for("accountancy").should be_empty
        registry.source_selectors.should be_empty
      end
    end

    # ── Union of specific + domain-wide entries ──────────────────────────

    it "returns the union of specific and domain-wide hooks, specific first" do
      with_db do |db|
        seed_core_schemas(db)
        # The domain-wide hook expands into every doctype in its source
        # domain — seed two so the expansion has somewhere to land.
        seed_doctype_in_domain(db, "accountancy", "Contract")
        seed_doctype_in_domain(db, "accountancy", "Invoice")
        ensure_domain_with_hooks(
          db, "sales",
          %([
            {"id": "specific",   "kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy", "doc_type": "Contract"}},
            {"id": "domain-wide","kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy"}}
          ]),
        )

        registry = Registry.new
        registry.build(db)

        # The specific hook is indexed under accountancy.Contract; the
        # domain-wide hook is expanded into every doctype in accountancy,
        # so accountancy.Contract gets both (in declaration order).
        hooks = registry.hooks_for("accountancy.Contract")
        hooks.map(&.id).should eq(["specific", "domain-wide"])

        # A doctype without a specific entry still matches the domain-wide hook.
        only_wide = registry.hooks_for("accountancy.Invoice")
        only_wide.map(&.id).should eq(["domain-wide"])
      end
    end

    it "returns an empty array for an unknown source doctype" do
      with_db do |db|
        seed_core_schemas(db)

        registry = Registry.new
        registry.build(db)

        registry.hooks_for("accountancy.Contract").should be_empty
      end
    end

    it "returns an empty array for an unqualified source doctype" do
      with_db do |db|
        seed_core_schemas(db)

        registry = Registry.new
        registry.build(db)

        registry.hooks_for("no-dot-here").should be_empty
      end
    end

    # ── Lazy rebuild on stale flag ──────────────────────────────────────

    it "rebuilds lazily after mark_stale picks up newly-added hooks" do
      with_db do |db|
        seed_core_schemas(db)
        registry = Registry.new
        registry.build(db)
        registry.hooks_for("accountancy.Contract").should be_empty

        # Mutate the domain after the initial build. We bypass the
        # authoring gate here to keep the test focused on the registry's
        # stale/rebuild path; the gate is exercised in `authoring_gate_spec`.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "sales",
          content: %({"hooks": [{"id": "h", "kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy", "doc_type": "Contract"}}]}),
          actioner_id: "system:test",
        )

        registry.mark_stale

        hooks = registry.hooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        hooks.first.id.should eq("h")
      end
    end

    # ── Fail-closed on malformed hook entries ──────────────────────────

    it "skips a malformed hooks array and still loads other domains" do
      with_db do |db|
        seed_core_schemas(db)

        # A domain whose `hooks` value is not an array — `Definition.parse`
        # records a parse error and returns no hooks. The registry logs
        # the error and continues; other domains still load.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "broken",
          # Bypass the gate: the authoring validator would reject this.
          content: %({"hooks": "not-an-array"}),
          actioner_id: "system:test",
        )
        ensure_domain_with_hooks(
          db, "sales",
          %([{"id": "h", "kind": "event", "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy", "doc_type": "Contract"}}]),
        )

        registry = Registry.new
        registry.build(db)

        # The broken domain contributed nothing; the valid domain still loaded.
        registry.hooks_for("accountancy.Contract").map(&.id).should eq(["h"])
      end
    end

    # ── Schedule hooks are not tracked by the registry ─────────────────

    it "does not index schedule hooks (dispatched by the scheduler)" do
      with_db do |db|
        seed_core_schemas(db)
        # The event hook is domain-wide on `accountancy` — seed a doctype
        # so the expansion has somewhere to land.
        seed_doctype_in_domain(db, "accountancy", "Contract")
        ensure_domain_with_hooks(
          db, "sales",
          %([
            {"id": "nightly", "kind": "schedule", "schedule": "0 0 * * *", "script": "#{SCHEDULE_SCRIPT}"},
            {"id": "on-evt",  "kind": "event",     "script": "#{EVENT_SCRIPT}", "source": {"domain": "accountancy"}}
          ]),
        )

        registry = Registry.new
        registry.build(db)

        # Only the event hook lands in the registry, expanded to the
        # concrete accountancy.Contract doctype.
        selectors = registry.source_selectors
        selectors.should eq(Set{"accountancy.Contract"})

        hooks = registry.hooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        hooks.first.id.should eq("on-evt")
      end
    end
  end
end
