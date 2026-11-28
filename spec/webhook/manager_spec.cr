# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../support/stub_event_manager"
require "../support/webhook_helper"
require "../../src/webhook"
require "../../src/event/manager"
require "../../src/doctype/seed"
require "../../src/mutation/client"
require "../../src/jobs"

module Facet
  describe Webhook::Manager do
    before_each do
      # `background_jobs` is not in the global truncation list.
      with_db(&.exec("DELETE FROM background_jobs"))
      Webhook::Manager.reset!
      Jobs::Manager.reset!
    end

    after_each do
      Jobs::Manager.instance.try(&.stop)
      Jobs::Manager.reset!
      Webhook::Manager.reset!
    end

    # ── Singleton accessor ────────────────────────────────────────────

    it ".instance / .instance= / .reset! mirror Hooks::Manager" do
      prev = Webhook::Manager.instance
      begin
        Webhook::Manager.instance.should be_nil

        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-singleton",
          event_manager: StubEventManager.new,
        )
        Webhook::Manager.instance = mgr
        Webhook::Manager.instance.should be(mgr)

        Webhook::Manager.reset!
        Webhook::Manager.instance.should be_nil
      ensure
        Webhook::Manager.instance = prev
      end
    end

    it "mark_registry_stale is safe when no manager is installed" do
      prev = Webhook::Manager.instance
      begin
        Webhook::Manager.reset!
        Webhook::Manager.instance.should be_nil
        # The `DoctypeCache` subscriber path uses the nil-safe `try` form —
        # no manager, no Redis, no raise.
        Webhook::Manager.instance.try(&.mark_registry_stale).should be_nil
      ensure
        Webhook::Manager.instance = prev
      end
    end

    # ── Lifecycle: start / stop are idempotent, single transition ─────

    it "start and stop are idempotent, single transition" do
      mgr = Webhook::Manager.new(
        config: Facet::Config.instance,
        service_id: "test-lifecycle",
        event_manager: StubEventManager.new,
      )
      mgr.started?.should be_false
      mgr.event_manager.started?.should be_false

      with_db { |db| mgr.start(db) }

      mgr.started?.should be_true
      mgr.event_manager.started?.should be_true

      # Second start is a no-op — already-started.
      with_db { |db| mgr.start(db) }
      mgr.started?.should be_true

      mgr.stop
      mgr.started?.should be_false
      mgr.event_manager.started?.should be_false

      # Second stop is a no-op — already-stopped.
      mgr.stop
      mgr.started?.should be_false
    ensure
      mgr.try(&.stop)
    end

    it "mark_registry_stale delegates to the registry" do
      mgr = Webhook::Manager.new(
        config: Facet::Config.instance,
        service_id: "test-stale",
        event_manager: StubEventManager.new,
      )
      with_db { |db| mgr.build(db) }
      mgr.registry.stale?.should be_false

      mgr.mark_registry_stale
      mgr.registry.stale?.should be_true
    end

    it "registry read rebuilds when the staleness bound expires (fanout lost)" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_webhook_source(db)

        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-ttl",
          event_manager: StubEventManager.new,
        )
        # Build the registry fresh (no webhooks yet — the snapshot stamp
        # starts here).
        mgr.build(db)
        mgr.registry.stale?.should be_false

        # A webhook lands in the DB while Redis is down: no fanout fires,
        # so `mark_registry_stale` never runs. No bound account/role — the
        # registry indexes the binding regardless; the handler resolves
        # enqueue-time RBAC per event.
        create_bound_webhook(db, "wh-ttl", "sales.Invoice", nil, nil)

        with_cache_ttl(1) do
          # Inside the bound the stale snapshot still serves.
          mgr.registry.webhooks_for("sales.Invoice").should be_empty

          # Past the bound the next read rebuilds from the DB and the
          # binding resolves without any invalidation.
          assert_eventually(timeout: 4.0, interval: 0.05) do
            !mgr.registry.webhooks_for("sales.Invoice").empty?
          end
        end
      end
    end

    # ── Subscription registration + channel provider on core ──────────

    it "registers every source stream under the owning domain core and installs the channel provider" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-sub", "sales.Invoice", account_id, role_id)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-subs",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          # One subscription per source doctype, all under `core`.
          subs = stub.subscriptions
          subs.size.should eq(1)
          subs.first.domain.should eq("core")
          subs.first.channel.should eq("FACET:RESOURCE:sales:Invoice")

          # The channel provider is installed on `core` — the single owning
          # domain behind the `cg:webhooks:core` consumer group.
          stub.channel_providers.has_key?("core").should be_true
          stub.channel_providers["core"].call.should eq(["FACET:RESOURCE:sales:Invoice"])
        ensure
          mgr.stop
        end
      end
    end

    it "channel_provider reflects new source channels after a registry rebuild" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-refresh",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          provider = stub.channel_providers["core"]
          provider.call.should eq(["FACET:RESOURCE:sales:Invoice"])

          # Add a second webhook on another source doctype.
          Facet::Mutation::Client.create(
            db, "core", "DocType", doc_id: "sales.Quote",
            content: %({"doctype": "Quote", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
            actioner_id: "system:test",
          )
          create_bound_webhook(db, "wh-2", "sales.Quote", account_id, role_id)
          mgr.mark_registry_stale

          # The provider reflects the new channel set on the next call —
          # no restart, no re-subscribe.
          channels = provider.call.sort
          channels.should eq(["FACET:RESOURCE:sales:Invoice", "FACET:RESOURCE:sales:Quote"])
        ensure
          mgr.stop
        end
      end
    end

    # ── B-54: live delivery without a restart ─────────────────────────

    it "creates the core stream subscriber at boot even with zero webhooks" do
      with_db do |db|
        restore_seeded_baseline(db)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-b54-boot",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          # With zero webhooks, `event_manager.start` creates no subscriber
          # for `core` — the manager must create it itself, wired with the
          # provider and the add callback, so a webhook created later arms
          # live delivery without a restart.
          subscriber = stub.stub_subscribers["core"]?
          subscriber.should_not be_nil
          core = subscriber.not_nil!
          core.channels.should be_empty
          core.provider.should_not be_nil
          core.on_channels_added.should_not be_nil

          # No dispatch registrations yet — no webhook, no registration.
          stub.subscriptions.should be_empty
        ensure
          mgr.stop
        end
      end
    end

    it "arms live delivery for a webhook created after boot: provider grows and the add callback registers the dispatch subscription" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_webhook_source(db)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-b54-live",
          event_manager: stub,
        )
        begin
          mgr.start(db)
          core = stub.stub_subscribers["core"].not_nil!
          core.channels.should be_empty

          # The webhook lands the way production does: a mutation, the
          # DoctypeCache fanout, `mark_registry_stale`, and the next
          # registry read rebuilds from the DB.
          role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
          account_id = create_test_account(db, roles: [role_id], default_role: role_id)
          create_bound_webhook(db, "wh-late", "sales.Invoice", account_id, role_id)
          mgr.mark_registry_stale

          # Next polling turn: the provider consults the rebuilt registry.
          channels = core.provider.not_nil!.call
          channels.should eq(["FACET:RESOURCE:sales:Invoice"])

          # The subscriber adds the channel, and the add callback pairs it
          # with a dispatch registration — without it the messages would be
          # read and silently dropped.
          core.on_channels_added.not_nil!.call(channels)
          subs = stub.subscriptions
          subs.size.should eq(1)
          subs.first.domain.should eq("core")
          subs.first.channel.should eq("FACET:RESOURCE:sales:Invoice")
        ensure
          mgr.stop
        end
      end
    end

    it "boot with webhooks: the core subscriber carries the initial channel and registrations are not doubled" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-boot", "sales.Invoice", account_id, role_id)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-b54-bootwebhook",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          core = stub.stub_subscribers["core"]?
          core.should_not be_nil
          core.not_nil!.channels.should eq(["FACET:RESOURCE:sales:Invoice"])

          # One dispatch registration per source channel — the pre-start
          # registration and the ensure-path re-registration de-duplicate.
          subs = stub.subscriptions
          subs.size.should eq(1)
          subs.first.domain.should eq("core")
          subs.first.channel.should eq("FACET:RESOURCE:sales:Invoice")

          # The add callback is wired for post-boot source-doctype additions.
          stub.channel_add_callbacks.has_key?("core").should be_true
        ensure
          mgr.stop
        end
      end
    end

    # ── Dispatcher registration into Jobs::Manager ─────────────────────

    it "registers the webhook_delivery handler before Jobs::Manager.start, and the started worker carries it" do
      with_db do |db|
        restore_seeded_baseline(db)

        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-dispatcher",
          event_manager: StubEventManager.new,
        )
        jobs = Jobs::Manager.new(Facet::Config::JobsConfig.new(enabled: true, poll_interval_s: 60.0))

        mgr.register_handler(jobs)
        # The map entry exists before start — the contract the worker
        # snapshot depends on.
        jobs.handler_for("webhook_delivery").should eq(Webhook::Dispatcher)

        begin
          jobs.start
          jobs.worker.should_not be_nil
          jobs.worker.not_nil!.handlers["webhook_delivery"]?.should eq(Webhook::Dispatcher)
        ensure
          jobs.stop
        end
      end
    end

    # ── Empty registry: start with no webhooks is a valid no-op ────────

    it "starts cleanly with an empty registry (no subscriptions, provider returns an empty set)" do
      with_db do |db|
        restore_seeded_baseline(db)

        stub = StubEventManager.new
        mgr = Webhook::Manager.new(
          config: Facet::Config.instance,
          service_id: "test-empty",
          event_manager: stub,
        )
        begin
          mgr.start(db)

          stub.subscriptions.should be_empty
          stub.channel_providers.has_key?("core").should be_true
          stub.channel_providers["core"].call.should be_empty
          mgr.started?.should be_true
        ensure
          mgr.stop
        end
      end
    end
  end
end
