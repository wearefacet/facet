# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/webhook"
require "../../src/mutation/client"

# Persists a `core.Webhook` projection through the raw mutation path. No
# authoring gate runs here — the registry only reads projections, and the
# doctype engine / Lua hook surface is exercised in `doctype_spec.cr`.
# `content` is a JSON string the caller builds, so malformed documents
# (fail-closed cases) can be staged too.
def create_webhook(db, doc_id, content)
  Facet::Mutation::Client.create(
    db, "core", "Webhook",
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
end

# A minimal complete webhook body pointing at the given source doctype.
def webhook_body(source_doctype : String, extra : String = "") : String
  %({"label": "Relay", "url": "https://example.test/hook", "secret": "secret-key-123456", "source_doctype": "#{source_doctype}"#{extra}})
end

module Facet::Webhook
  describe Registry do
    # ── Build picks up bindings from core.Webhook projections ────────────

    it "builds bindings from core.Webhook projections keyed by source doctype" do
      with_db do |db|
        create_webhook(db, "wh-1", webhook_body("accountancy.Contract"))

        registry = Registry.new
        registry.build(db)

        hooks = registry.webhooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        wh = hooks.first
        wh.id.should eq("wh-1")
        wh.source_doctype.should eq("accountancy.Contract")
        # `events` absent → match-all; `enabled` absent → COALESCE to true.
        wh.events.should be_nil
        wh.secret.should eq("secret-key-123456")
        wh.account_id.should be_nil
        wh.role_id.should be_nil

        registry.source_selectors.should eq(Set{"accountancy.Contract"})
      end
    end

    it "returns an empty array for an unknown source doctype" do
      with_db do |db|
        create_webhook(db, "wh-1", webhook_body("accountancy.Contract"))

        registry = Registry.new
        registry.build(db)

        registry.webhooks_for("accountancy.Invoice").should be_empty
      end
    end

    # ── Reference-token source_doctype ──────────────────────────────────

    # `source_doctype` is a `reference` → `core.DocType` field, so the
    # engine persists it as the qualified token
    # `core.DocType.{qualified doctype name}` (B-54). The specs below stage
    # that token form directly — `webhook_body` writes raw content, the
    # same shape `fetch_webhooks` reads back.
    it "keys a reference-token source_doctype under the bare qualified doctype" do
      with_db do |db|
        create_webhook(db, "wh-ref", webhook_body("core.DocType.accountancy.Contract"))

        registry = Registry.new
        registry.build(db)

        hooks = registry.webhooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        hooks.first.id.should eq("wh-ref")
        hooks.first.source_doctype.should eq("accountancy.Contract")
        registry.source_selectors.should eq(Set{"accountancy.Contract"})
        # Nothing is keyed under the raw token form — the stream that the
        # publisher writes (`FACET:RESOURCE:accountancy:Contract$N`) is the
        # one the binding must resolve from.
        registry.webhooks_for("core.DocType.accountancy.Contract").should be_empty
      end
    end

    it "strips the token prefix when the source is core.DocType itself" do
      with_db do |db|
        # Watching `core.DocType` persists as `core.DocType.core.DocType`.
        create_webhook(db, "wh-dt", webhook_body("core.DocType.core.DocType"))

        registry = Registry.new
        registry.build(db)

        registry.webhooks_for("core.DocType").first.id.should eq("wh-dt")
        registry.source_selectors.should eq(Set{"core.DocType"})
      end
    end

    # ── Lazy rebuild on stale flag ──────────────────────────────────────

    it "rebuilds lazily after mark_stale picks up newly-added webhooks" do
      with_db do |db|
        registry = Registry.new
        registry.build(db)
        registry.webhooks_for("accountancy.Contract").should be_empty
        registry.stale?.should be_false

        create_webhook(db, "wh-1", webhook_body("accountancy.Contract"))
        registry.mark_stale
        registry.stale?.should be_true

        hooks = registry.webhooks_for("accountancy.Contract")
        hooks.size.should eq(1)
        hooks.first.id.should eq("wh-1")
        # The read consumed the stale flag — N events, one rebuild.
        registry.stale?.should be_false
      end
    end

    it "propagates staleness from the manager to its registry" do
      with_db do |db|
        manager = Manager.new
        manager.registry.build(db)
        manager.registry.stale?.should be_false

        manager.mark_registry_stale
        manager.registry.stale?.should be_true
      end
    end

    # ── Disabled webhooks are excluded ──────────────────────────────────

    it "excludes disabled webhooks" do
      with_db do |db|
        create_webhook(db, "wh-off", webhook_body("accountancy.Contract", ", \"enabled\": false"))
        create_webhook(db, "wh-on", webhook_body("accountancy.Contract"))

        registry = Registry.new
        registry.build(db)

        hooks = registry.webhooks_for("accountancy.Contract")
        hooks.map(&.id).should eq(["wh-on"])
      end
    end

    # ── Tombstoned webhooks are excluded ────────────────────────────────

    it "excludes tombstoned (deleted) webhooks" do
      with_db do |db|
        create_webhook(db, "wh-gone", webhook_body("accountancy.Contract"))
        Facet::Mutation::Client.delete(db, "core", "Webhook", "wh-gone", actioner_id: "system:test")

        registry = Registry.new
        registry.build(db)

        registry.webhooks_for("accountancy.Contract").should be_empty
      end
    end

    # ── Fail-closed on a corrupt row ────────────────────────────────────

    it "skips a row without source_doctype and still loads the rest" do
      with_db do |db|
        # Corrupt row: no source_doctype. A real create can never produce
        # it (the field is required) — this stages a corrupt projection
        # directly, which is the runtime safety net's job to survive.
        create_webhook(db, "wh-broken", %({"label": "Broken", "secret": "secret-key-123456"}))
        create_webhook(db, "wh-good", webhook_body("accountancy.Contract"))

        registry = Registry.new
        registry.build(db)

        hooks = registry.webhooks_for("accountancy.Contract")
        hooks.map(&.id).should eq(["wh-good"])
        registry.source_selectors.should eq(Set{"accountancy.Contract"})
      end
    end

    # ── events shape ────────────────────────────────────────────────────

    it "treats a non-array events value as match-all" do
      with_db do |db|
        create_webhook(db, "wh-bad", webhook_body("accountancy.Contract", ", \"events\": \"created\""))

        registry = Registry.new
        registry.build(db)

        registry.webhooks_for("accountancy.Contract").first.events.should be_nil
      end
    end

    it "keeps an empty events array as match-none (binding loads, handler filters)" do
      with_db do |db|
        create_webhook(db, "wh-none", webhook_body("accountancy.Contract", ", \"events\": []"))

        registry = Registry.new
        registry.build(db)

        # The binding is present — a webhook that declared `events: []`
        # opted out of every event, so the handler must never fire it.
        wh = registry.webhooks_for("accountancy.Contract").first
        wh.id.should eq("wh-none")
        wh.events.should eq([] of String)
      end
    end

    # ── Draft isolation ─────────────────────────────────────────────────

    it "skips webhooks whose source doctype is in a draft domain" do
      with_db do |db|
        create_webhook(db, "wh-draft", webhook_body("_draft.Thing"))
        create_webhook(db, "wh-live", webhook_body("accountancy.Contract"))

        registry = Registry.new(domain_enabled: ->(d : String) { d != "_draft" })
        registry.build(db)

        registry.webhooks_for("_draft.Thing").should be_empty
        registry.source_selectors.should eq(Set{"accountancy.Contract"})
      end
    end
  end
end
