# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/stub_event_manager"
require "../../src/hooks"
require "../../src/event/manager"
require "../../src/doctype/seed"
require "../../src/mutation/client"
require "../../src/rbac"

module Facet::Hooks
  describe Manager do
    # ── Singleton accessor ────────────────────────────────────────────

    it ".instance / .instance= installs a process-wide singleton" do
      prev = Manager.instance
      begin
        Manager.instance.should be_nil

        mgr = Manager.new(
          config: Facet::Config.instance,
          service_id: "test-singleton",
          event_manager: StubEventManager.new,
        )
        Manager.instance = mgr
        Manager.instance.should be(mgr)

        # The `DoctypeCache` Pub/Sub path uses the nil-safe `try` form —
        # clearing the singleton must not raise.
        Manager.instance = nil
        Manager.instance.should be_nil
        Manager.instance.try(&.mark_registry_stale).should be_nil
      ensure
        Manager.instance = prev
      end
    end

    # ── Lifecycle: start / stop are idempotent, single transition ─────

    it "start is idempotent and starts the event_manager + scheduler" do
      mgr = Manager.new(
        config: Facet::Config.instance,
        service_id: "test-lifecycle",
        event_manager: StubEventManager.new,
      )
      mgr.started?.should be_false
      mgr.scheduler.running?.should be_false
      mgr.event_manager.started?.should be_false

      with_db { |db| mgr.start(db) }

      mgr.started?.should be_true
      mgr.event_manager.started?.should be_true
      mgr.scheduler.running?.should be_true

      # Second start is a no-op — already-started.
      with_db { |db| mgr.start(db) }
      mgr.started?.should be_true

      mgr.stop
      mgr.started?.should be_false
      mgr.event_manager.started?.should be_false
      mgr.scheduler.running?.should be_false

      # Second stop is a no-op — already-stopped.
      mgr.stop
      mgr.started?.should be_false
    ensure
      mgr.try(&.stop)
    end

    # ── mark_registry_stale delegates to the registry, no DB access ──

    it "mark_registry_stale delegates to the registry" do
      mgr = Manager.new(
        config: Facet::Config.instance,
        service_id: "test-stale",
        event_manager: StubEventManager.new,
      )
      # Build the registry so it is fresh, then mark stale.
      with_db { |db| mgr.build(db) }
      mgr.registry.stale?.should be_false

      mgr.mark_registry_stale
      mgr.registry.stale?.should be_true
    end

    it "registry read rebuilds when the staleness bound expires (fanout lost)" do
      with_db do |db|
        restore_seeded_baseline(db)
        mgr = Manager.new(
          config: Facet::Config.instance,
          service_id: "test-ttl",
          event_manager: StubEventManager.new,
        )
        # Build the registry fresh (no hooks yet — the snapshot stamp
        # starts here).
        mgr.build(db)
        mgr.registry.stale?.should be_false

        # A hook lands in the DB while Redis is down: no fanout fires,
        # so `mark_registry_stale` never runs.
        upsert_domain_with_hooks(db, "sales", [
          {"id": "h-ttl", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
        ])

        with_cache_ttl(1) do
          # Inside the bound the stale snapshot still serves.
          mgr.registry.hooks_for("accountancy.Contract").should be_empty

          # Past the bound the next read rebuilds from the DB and the
          # hook resolves without any invalidation.
          assert_eventually(timeout: 4.0, interval: 0.05) do
            !mgr.registry.hooks_for("accountancy.Contract").empty?
          end
        end
      end
    end

    # ── Subscription registration maps owning_domain → source channels ─

    it "registers subscriptions grouped by owning domain over source channels" do
      with_db do |db|
        restore_seeded_baseline(db)
        # Two owning domains, each hooking a different source doctype.
        upsert_domain_with_hooks(db, "sales", [
          {"id": "h-sales", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
        ])
        upsert_domain_with_hooks(db, "hr", [
          {"id": "h-hr", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "identity", "doc_type": "Account"}},
        ])

        stub = StubEventManager.new
        mgr = Manager.new(
          config: Facet::Config.instance,
          service_id: "test-subs",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          subs = stub.subscriptions
          subs.size.should eq(2)

          sales_sub = subs.find { |s| s.domain == "sales" }
          sales_sub.should_not be_nil
          sales_sub.not_nil!.channel.should eq("FACET:RESOURCE:accountancy:Contract")

          hr_sub = subs.find { |s| s.domain == "hr" }
          hr_sub.should_not be_nil
          hr_sub.not_nil!.channel.should eq("FACET:RESOURCE:identity:Account")

          # Channel providers and add callbacks installed for each owning
          # domain — the add callback pairs runtime-added source channels
          # with dispatch registrations (without it the messages on the new
          # channel are read and silently dropped).
          stub.channel_providers.has_key?("sales").should be_true
          stub.channel_providers.has_key?("hr").should be_true
          stub.channel_add_callbacks.has_key?("sales").should be_true
          stub.channel_add_callbacks.has_key?("hr").should be_true
        ensure
          mgr.stop
        end
      end
    end

    # ── channel_provider reflects registry rebuilds (lazy refresh) ────

    it "channel_provider reflects new source channels after a registry rebuild" do
      with_db do |db|
        restore_seeded_baseline(db)
        upsert_domain_with_hooks(db, "sales", [
          {"id": "h1", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
        ])

        stub = StubEventManager.new
        mgr = Manager.new(
          config: Facet::Config.instance,
          service_id: "test-refresh",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          provider = stub.channel_providers["sales"]
          provider.call.should eq(["FACET:RESOURCE:accountancy:Contract"])

          # Add a second source doctype hook on the same owning domain.
          upsert_domain_with_hooks(db, "sales", [
            {"id": "h1", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
            {"id": "h2", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Invoice"}},
          ])
          mgr.mark_registry_stale

          # The provider reflects the new channel set on the next call —
          # no restart, no re-subscribe.
          channels = provider.call.sort
          channels.should eq(["FACET:RESOURCE:accountancy:Contract", "FACET:RESOURCE:accountancy:Invoice"])
        ensure
          mgr.stop
        end
      end
    end

    # ── Empty registry: start with no hooks is a valid no-op ─────────

    it "starts cleanly with an empty registry (no subscriptions, no providers)" do
      with_db do |db|
        restore_seeded_baseline(db)
        # A published domain with no hooks at all.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "empty",
          content: %({"hooks": []}),
          actioner_id: "system:test",
        )

        stub = StubEventManager.new
        mgr = Manager.new(
          config: Facet::Config.instance,
          service_id: "test-empty",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          stub.subscriptions.should be_empty
          stub.channel_providers.should be_empty
          stub.channel_add_callbacks.should be_empty
          mgr.started?.should be_true
        ensure
          mgr.stop
        end
      end
    end

    # ── Subscriber sync: post-boot owning domains ─────────────────

    it "creates a stream subscriber for an owning domain that gains its first hook after boot" do
      stub = StubEventManager.new
      mgr = Manager.new(
        config: Facet::Config.instance,
        service_id: "test-sync",
        event_manager: stub,
        subscriber_sync_interval: 50.milliseconds,
      )
      begin
        with_db do |db|
          restore_seeded_baseline(db)
          mgr.start(db)
        end

        # A hook lands in a domain that had no hooks at boot; the fanout
        # marks the registry stale on the real Pub/Sub path.
        with_db do |db|
          upsert_domain_with_hooks(db, "sales", [
            {"id": "h-late", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
          ])
        end
        mgr.mark_registry_stale

        # The sync fiber creates the subscriber with the initial channels
        # and the provider + add callback installed.
        assert_eventually(timeout: 4.0, interval: 0.05) do
          stub.stub_subscribers.has_key?("sales")
        end

        subscriber = stub.stub_subscribers["sales"]
        subscriber.channels.should eq(["FACET:RESOURCE:accountancy:Contract"])
        subscriber.provider.not_nil!.call.should eq(["FACET:RESOURCE:accountancy:Contract"])

        # The initial channel set has a dispatch registration — the boot-time
        # registration is absent for a post-boot domain.
        stub.subscriptions.any? { |s| s.domain == "sales" && s.channel == "FACET:RESOURCE:accountancy:Contract" }.should be_true
      ensure
        mgr.try(&.stop)
      end
    end

    it "pairs runtime-added source channels with dispatch registrations via the add callback" do
      stub = StubEventManager.new
      mgr = Manager.new(
        config: Facet::Config.instance,
        service_id: "test-addcb",
        event_manager: stub,
      )
      begin
        with_db do |db|
          restore_seeded_baseline(db)
          upsert_domain_with_hooks(db, "sales", [
            {"id": "h1", "kind": "event", "script": "local e={} function e.on_event(ctx) end return e", "source": {"domain": "accountancy", "doc_type": "Contract"}},
          ])
          mgr.start(db)
        end

        callback = stub.channel_add_callbacks["sales"]
        callback.call(["FACET:RESOURCE:accountancy:Invoice"])

        stub.subscriptions.any? { |s| s.domain == "sales" && s.channel == "FACET:RESOURCE:accountancy:Invoice" }.should be_true
      ensure
        mgr.try(&.stop)
      end
    end
  end
end

# Helper: writes a hooks array onto a `core.Domain` document, bypassing
# the authoring gate (the focus here is lifecycle, not authoring — which
# `authoring_gate_spec.cr` exercises).
private def upsert_domain_with_hooks(db, owning_domain, hooks_array : Array)
  exists = db.query_one?(
    "SELECT 1 FROM projections WHERE domain='core' AND doc_type='Domain' AND id=$1 AND deleted_at IS NULL",
    owning_domain,
    as: Int32,
  )
  body = {"hooks" => hooks_array}.to_json
  if exists.nil?
    Facet::Mutation::Client.create(
      db, "core", "Domain",
      doc_id: owning_domain,
      content: body,
      actioner_id: "system:test",
    )
  else
    Facet::Mutation::Client.update(
      db, "core", "Domain", owning_domain,
      diff_json: %({"set": [{"path": ["hooks"], "value": #{hooks_array.to_json}}]}),
    )
  end
end
