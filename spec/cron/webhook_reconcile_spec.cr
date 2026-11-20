# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/webhook"
require "../../src/cron/webhook_reconcile"
require "../../src/jobs/manager"
require "../../src/mutation/client"
require "../support/webhook_helper"

# `Cron::WebhookReconcile` — the at-least-once backstop for the webhook
# enqueue hop. It derives delivery state from `mutations` and
# `background_jobs` (never marks), skips reentrant clusters the same way
# the stream path does, maps mutation rows to event names, and honours the
# window plus the binding `created_at` bound.
# Seeds the readable source doctype + document, a bound role/account,
# and the webhook itself. Mutations emitted from here on are AFTER the
# binding's `created_at`, so the new-binding bound never fires for
# them. Returns the webhook document id.
private def seed_bound_pipeline(db, webhook_id = "wh-1", extra = "") : String
  seed_webhook_source(db)
  role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
  account_id = create_test_account(db, roles: [role_id], default_role: role_id)
  create_bound_webhook(db, webhook_id, "sales.Invoice", account_id, role_id, extra)
  webhook_id
end

private def reconcile_delivery_payloads_for(db, mutation_id) : Array(JSON::Any)
  db.query_all(
    "SELECT payload FROM background_jobs WHERE kind = 'webhook_delivery' AND payload->>'mutation_id' = $1",
    mutation_id,
    as: JSON::Any,
  )
end

private def reconcile_delivery_count(db) : Int64
  db.query_one("SELECT count(*) FROM background_jobs WHERE kind = 'webhook_delivery'", as: Int64)
end

# Inserts a `webhook_delivery` job row in the given status for the
# (mutation_id, webhook_id) pair — the dedupe authority.
private def insert_delivery_row(db, mutation_id, webhook_id, status) : Nil
  db.exec(
    <<-SQL,
      INSERT INTO background_jobs (id, kind, payload, status)
      VALUES ($1, 'webhook_delivery', $2::jsonb, $3)
    SQL
    Facet::Util::ScriptHelpers.ulid,
    %({"mutation_id": "#{mutation_id}", "webhook_id": "#{webhook_id}"}),
    status,
  )
end

module Facet
  describe Cron::WebhookReconcile do
    # `background_jobs` is not in the global truncation list — clean it per
    # example (mirrors `spec/webhook/handler_spec.cr`). The jobs manager is
    # installed in enqueue-only mode (no worker) so enqueues insert rows
    # synchronously.
    #
    # The webhook manager is installed because the reconciler reaches the
    # shared handler through `Webhook::Manager.instance.registry`. Its
    # `Event::Manager` holds a lazy Redis client that never connects — the
    # reconciler never starts it.
    before_each do
      with_db(&.exec("DELETE FROM background_jobs"))
      Facet::Jobs::Manager.instance = Facet::Jobs::Manager.new
      Facet::Webhook::Manager.instance = Facet::Webhook::Manager.new(
        config: Facet::Config.instance,
        service_id: "webhook-reconcile-spec",
      )
    end

    after_each do
      Facet::Jobs::Manager.reset!
      Facet::Webhook::Manager.reset!
    end

    # ── Repair ─────────────────────────────────────────────────────────

    it "repairs a missed enqueue with the derived event and original ids" do
      with_db do |db|
        seed_bound_pipeline(db)

        mut_id = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-2",
          content: %({"total": 200}),
          actioner_id: "act-reconcile",
        )

        Cron::WebhookReconcile.call

        payloads = reconcile_delivery_payloads_for(db, mut_id)
        payloads.size.should eq(1)
        payload = payloads.first
        payload["webhook_id"].as_s.should eq("wh-1")
        payload["event"].as_s.should eq("created")
        payload["mutation_id"].as_s.should eq(mut_id)
        payload["actioner_id"].as_s.should eq("act-reconcile")
        # The repaired delivery keeps the mutation's emission instant, not
        # the reconcile time — receivers can detect and reorder.
        payload["emitted_at"].as_s.should_not be_empty
        # The cause header rides from the typed cause columns.
        payload["cause"]["trace"].as_s.should eq(mut_id)
        payload["content"]["id"].as_s.should eq("inv-2")
        payload["url"].as_s.should eq("https://receiver.test/hook")
      end
    end

    it "is idempotent: a second pass adds no duplicate delivery" do
      with_db do |db|
        seed_bound_pipeline(db)

        Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-2",
          content: %({"total": 200}),
        )

        Cron::WebhookReconcile.call
        before = reconcile_delivery_count(db)
        Cron::WebhookReconcile.call

        reconcile_delivery_count(db).should eq(before)
      end
    end

    # ── Dedupe ────────────────────────────────────────────────────────

    it "skips an enqueued pair in any job status" do
      with_db do |db|
        seed_bound_pipeline(db)

        mut_id = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-2",
          content: %({"total": 200}),
        )

        # A failed row has exhausted its retries; re-enqueueing would
        # bypass the retry policy. Same for every other status.
        {"pending", "running", "succeeded", "failed"}.each do |status|
          insert_delivery_row(db, mut_id, "wh-1", status)

          Cron::WebhookReconcile.call
          reconcile_delivery_payloads_for(db, mut_id).size.should eq(1),
            "expected exactly the seeded row for status #{status}"

          db.exec(
            "DELETE FROM background_jobs WHERE kind = 'webhook_delivery' AND payload->>'mutation_id' = $1",
            mut_id,
          )
        end
      end
    end

    it "repairs only the binding whose pair is missing" do
      with_db do |db|
        seed_bound_pipeline(db)
        role_id = seed_role(db, "inv_reader_2", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, email: "second@example.com", roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-2", "sales.Invoice", account_id, role_id)

        mut_id = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-2",
          content: %({"total": 200}),
        )
        insert_delivery_row(db, mut_id, "wh-1", "succeeded")

        Cron::WebhookReconcile.call

        payloads = reconcile_delivery_payloads_for(db, mut_id)
        payloads.size.should eq(2)
        payloads.map(&.["webhook_id"].as_s).sort!.should eq(["wh-1", "wh-2"])
      end
    end

    # ── Reentrancy ────────────────────────────────────────────────────

    it "skips hook and replication writes (own cause kind)" do
      with_db do |db|
        seed_bound_pipeline(db)

        Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-hook",
          content: %({"total": 1}),
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::HookEvent,
            name: "hook-1", event: "updated",
            parent: "some-source-mut", trace: "some-source-mut",
          ),
        )
        Facet::Mutation::Client.update(
          db, "sales", "Invoice", "inv-hook",
          %({"set": [{"path": ["total"], "value": 2}]}),
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Replication,
            name: "sales.Invoice.total", event: "updated",
            parent: "some-source-mut", trace: "some-source-mut",
          ),
        )

        Cron::WebhookReconcile.call

        reconcile_delivery_count(db).should eq(0)
      end
    end

    it "skips a cascade child under a hook-driven delete (cluster root lookup)" do
      with_db do |db|
        # Seed the source doctype and the two documents the cluster will
        # tombstone BEFORE the webhook exists, so their create mutations
        # are outside the binding bound and cannot add deliveries.
        seed_webhook_source(db)
        Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-parent",
          content: %({"total": 1}),
        )
        Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-child",
          content: %({"total": 2}),
        )

        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        # A hook-driven delete of the parent: the hook's write is the
        # cluster root (a schedule fire mints its own trace). The cascade
        # child carries `cause_kind = 'cascade'` and inherits the trace —
        # the own-kind check alone would wrongly repair it, so the root
        # lookup must reach the `hook_schedule` verdict.
        fire_trace = Facet::Util::ScriptHelpers.ulid
        Facet::Mutation::Client.delete(
          db, "sales", "Invoice", "inv-parent",
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::HookSchedule,
            name: "hook-sched-1", trace: fire_trace,
          ),
        )
        child_mut = Facet::Mutation::Client.delete(
          db, "sales", "Invoice", "inv-child",
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Cascade,
            source: "sales.Invoice:inv-parent",
            parent: fire_trace, trace: fire_trace,
          ),
        )

        Cron::WebhookReconcile.call

        reconcile_delivery_payloads_for(db, child_mut).should be_empty
        reconcile_delivery_count(db).should eq(0)
      end
    end

    # ── Selection exclusions ──────────────────────────────────────────

    it "skips core-domain mutations" do
      with_db do |db|
        seed_bound_pipeline(db)

        # The webhook lives in core; a mutation on a core doctype must not
        # map to an event (core.DocType uses registered/updated, outside
        # the action→event map).
        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: "sales",
          content: %({"name": "sales"}),
        )

        Cron::WebhookReconcile.call

        reconcile_delivery_count(db).should eq(0)
      end
    end

    it "skips periodic_snapshot and webhook_test mutations" do
      with_db do |db|
        seed_bound_pipeline(db)

        periodic = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-3",
          content: %({"total": 3}),
          cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::PeriodicSnapshot),
        )
        tested = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-4",
          content: %({"total": 4}),
          cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::WebhookTest),
        )

        Cron::WebhookReconcile.call

        reconcile_delivery_payloads_for(db, periodic).should be_empty
        reconcile_delivery_payloads_for(db, tested).should be_empty
        reconcile_delivery_count(db).should eq(0)
      end
    end

    # ── Event-name map ────────────────────────────────────────────────

    it "maps each mutation shape to the event name the stream published" do
      with_db do |db|
        seed_bound_pipeline(db)

        created = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "map-1", content: %({"total": 1}))
        plain_update = Facet::Mutation::Client.update(
          db, "sales", "Invoice", "map-1",
          %({"set": [{"path": ["total"], "value": 2}]}),
        )
        action_mut = Facet::Mutation::Client.update(
          db, "sales", "Invoice", "map-1",
          %({"set": [{"path": ["total"], "value": 3}]}),
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Action,
            name: "promote", event: "hired", source: "sales.Invoice:map-1",
          ),
        )
        # A nested write under the action inherits the cause (kind action,
        # event set, parent bound) but `Document::Update` publishes the
        # standard `updated` for it.
        nested_action_update = Facet::Mutation::Client.update(
          db, "sales", "Invoice", "map-1",
          %({"set": [{"path": ["total"], "value": 4}]}),
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Action,
            name: "promote", event: "hired", source: "sales.Invoice:map-1",
            parent: action_mut, trace: action_mut,
          ),
        )
        deleted = Facet::Mutation::Client.delete(db, "sales", "Invoice", "map-1")
        migrated = Facet::Mutation::Client.snapshot_mutation(
          db, "sales", "Invoice", "map-1",
          content: %({"total": 5}),
          cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Migration, event: "migrated"),
        )
        rolled_back = Facet::Mutation::Client.snapshot_mutation(
          db, "sales", "Invoice", "map-1",
          content: %({"total": 6}),
          cause: Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Rollback,
            event: "rolled_back", trace: Facet::Util::ScriptHelpers.ulid,
          ),
        )
        # A compaction snapshot is outside the map — skipped, never
        # invented.
        compacted = Facet::Mutation::Client.snapshot_mutation(
          db, "sales", "Invoice", "map-1",
          content: %({"total": 7}),
          cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Compaction),
        )

        Cron::WebhookReconcile.call

        event_of = ->(mid : String) do
          rows = reconcile_delivery_payloads_for(db, mid)
          rows.size.should eq(1), "expected exactly one delivery for #{mid}"
          rows.first["event"].as_s
        end

        event_of.call(created).should eq("created")
        event_of.call(plain_update).should eq("updated")
        event_of.call(action_mut).should eq("hired")
        event_of.call(nested_action_update).should eq("updated")
        event_of.call(deleted).should eq("deleted")
        event_of.call(migrated).should eq("migrated")
        event_of.call(rolled_back).should eq("rolled_back")
        reconcile_delivery_payloads_for(db, compacted).should be_empty
      end
    end

    # ── Bounds ────────────────────────────────────────────────────────

    it "respects the reconcile window" do
      with_db do |db|
        seed_bound_pipeline(db)

        mut_id = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-old",
          content: %({"total": 1}),
        )

        # Backdate both sides of the comparison so only the window can
        # exclude the mutation: the webhook was created 3 days ago, the
        # mutation was emitted 2 days ago (inside the binding bound, but
        # outside the 24-hour default window). The seeded rows predate the
        # backdated binding, so they may repair — the assertion targets
        # the out-of-window row only.
        db.exec("UPDATE projections SET created_at = now() - interval '3 days' WHERE domain = 'core' AND doc_type = 'Webhook' AND id = 'wh-1'")
        db.exec("UPDATE mutations SET emitted_at = now() - interval '2 days' WHERE id = $1", mut_id)

        Cron::WebhookReconcile.call

        reconcile_delivery_payloads_for(db, mut_id).should be_empty
      end
    end

    it "respects the binding created_at bound" do
      with_db do |db|
        # Seed everything except the webhook, emit a mutation, THEN create
        # the webhook — the new binding must not receive the window's
        # history.
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)

        before_mut = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-before",
          content: %({"total": 1}),
        )

        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        # Emitted AFTER the binding exists — repaired.
        after_mut = Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-after",
          content: %({"total": 2}),
        )

        Cron::WebhookReconcile.call

        reconcile_delivery_payloads_for(db, before_mut).should be_empty
        reconcile_delivery_payloads_for(db, after_mut).size.should eq(1)
      end
    end

    it "does nothing when no webhook manager is installed" do
      with_db do |db|
        seed_bound_pipeline(db)
        Facet::Mutation::Client.create(
          db, "sales", "Invoice", doc_id: "inv-2",
          content: %({"total": 200}),
        )

        Webhook::Manager.reset!
        # No raise, no delivery — the pass logs and returns.
        Cron::WebhookReconcile.call

        reconcile_delivery_count(db).should eq(0)
      end
    end
  end
end
