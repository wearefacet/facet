# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/webhook"
require "../../src/mutation/client"
require "../../src/jobs/manager"
require "../support/webhook_helper"

# ── Helpers ────────────────────────────────────────────────────────────────

# Builds a source-mutation message in the wire shape the `Event::Manager`
# hands the handler (mirrors the `spec/hooks/handler_spec.cr` helper).
def webhook_source_message(domain, doc_type, event_name, source_id, *, reentrant = false, mutation_id = nil, actioner_id = nil, cause : JSON::Any? = nil) : Facet::Event::Message
  headers = {
    "domain"   => JSON::Any.new(domain),
    "doc_type" => JSON::Any.new(doc_type),
    "event"    => JSON::Any.new(event_name),
  }
  headers["reentrant"] = JSON::Any.new(true) if reentrant
  headers["mutation_id"] = JSON::Any.new(mutation_id) if mutation_id
  headers["actioner_id"] = JSON::Any.new(actioner_id) if actioner_id
  headers["cause"] = cause if cause
  Facet::Event::Message.new(
    content: JSON::Any.new({"id" => JSON::Any.new(source_id), "total" => JSON::Any.new(100_i64)}),
    headers: headers,
  )
end

# Builds the wire shape of a `notified` event: the content carries the
# source document id plus the notification body, exactly as
# `Notification::Send` publishes it.
def notification_message(domain, doc_type, source_id, account_id) : Facet::Event::Message
  Facet::Event::Message.new(
    content: JSON::Any.new({
      "id"           => JSON::Any.new(source_id),
      "notification" => JSON::Any.new({
        "notification_id" => JSON::Any.new(Facet::Util::ScriptHelpers.ulid),
        "account_id"      => JSON::Any.new(account_id),
        "kind"            => JSON::Any.new("leave_approved"),
        "title"           => JSON::Any.new("Leave approved"),
      } of String => JSON::Any),
    } of String => JSON::Any),
    headers: {
      "domain"      => JSON::Any.new(domain),
      "doc_type"    => JSON::Any.new(doc_type),
      "event"       => JSON::Any.new(Facet::Event::NOTIFIED),
      "actioner_id" => JSON::Any.new("system"),
    },
  )
end

# seed_webhook_source / seed_role / create_bound_webhook live in
# `spec/support/webhook_helper.cr` (shared with the manager and routes
# specs).

def build_webhook_handler : Facet::Webhook::Handler
  registry = Facet::Webhook::Registry.new
  Facet::Database.with_db { |db| registry.build(db) }
  Facet::Webhook::Handler.new(registry)
end

def delivery_count(db) : Int64
  db.query_one("SELECT count(*) FROM background_jobs WHERE kind = 'webhook_delivery'", as: Int64)
end

def delivery_payloads(db) : Array(JSON::Any)
  db.query_all(
    "SELECT payload FROM background_jobs WHERE kind = 'webhook_delivery' ORDER BY id",
    as: JSON::Any,
  )
end

# Seeds an owned pair (sales.Order ← sales.Line) plus both rows, so
# AuthCheck's parent step and child step have real projections.
def seed_aggregate_webhook_source(db) : Nil
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Order",
    content: %({"doctype": "Order", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}, "children": {"items": {"doctype": "Line", "collection": true}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Line",
    content: %({"doctype": "Line", "domain": "sales", "schema_version": 1, "member_of": "Order", "fields": {"qty": {"type": "integer"}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "sales", "Order", doc_id: "ord-1",
    content: %({"total": 1}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "sales", "Line", doc_id: "line-1",
    content: %({"qty": 2}),
    meta: %({"schema_version": 1, "parent_id": "ord-1"}),
    actioner_id: "system:test",
  )
end

# Builds the wire shape of an aggregate child_changed frame: keyed to the
# parent, with the child pointer in the payload.
def aggregate_child_message(parent_doc_id, child_doctype, child_doc_id, *, mutation_id = nil, actioner_id = nil) : Facet::Event::Message
  headers = {
    "domain"   => JSON::Any.new("sales"),
    "doc_type" => JSON::Any.new("Order"),
    "event"    => JSON::Any.new(Facet::Event::CHILD_CHANGED),
  }
  headers["mutation_id"] = JSON::Any.new(mutation_id) if mutation_id
  headers["actioner_id"] = JSON::Any.new(actioner_id) if actioner_id
  Facet::Event::Message.new(
    content: JSON::Any.new({
      "id"     => JSON::Any.new(parent_doc_id),
      "action" => JSON::Any.new("updated"),
      "child"  => JSON::Any.new({
        "doc_type" => JSON::Any.new(child_doctype),
        "doc_id"   => JSON::Any.new(child_doc_id),
      } of String => JSON::Any),
      "parent" => JSON::Any.new({
        "doc_type" => JSON::Any.new("Order"),
        "doc_id"   => JSON::Any.new(parent_doc_id),
      } of String => JSON::Any),
    } of String => JSON::Any),
    headers: headers,
  )
end

module Facet
  describe Facet::Webhook::Handler do
    # `background_jobs` is not in the global truncation list — clean it per
    # example (mirrors `spec/jobs/manager_spec.cr`). The manager is
    # installed in enqueue-only mode (no worker), so enqueues insert rows
    # synchronously and deterministically.
    before_each do
      with_db(&.exec("DELETE FROM background_jobs"))
      Facet::Jobs::Manager.instance = Facet::Jobs::Manager.new
    end

    after_each do
      Facet::Jobs::Manager.reset!
    end

    # ── Happy path ─────────────────────────────────────────────────────

    it "enqueues exactly one webhook_delivery row with the right payload shape" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1",
          mutation_id: "mut-1", actioner_id: "act-1"))

        delivery_count(db).should eq(1)
        payload = delivery_payloads(db).first
        payload["webhook_id"].as_s.should eq("wh-1")
        payload["delivery_id"].as_s.size.should be >= 26
        payload["event"].as_s.should eq("updated")
        payload["domain"].as_s.should eq("sales")
        payload["doc_type"].as_s.should eq("Invoice")
        payload["doc_id"].as_s.should eq("inv-1")
        payload["mutation_id"].as_s.should eq("mut-1")
        payload["actioner_id"].as_s.should eq("act-1")
        payload["cause"]?.should be_nil
        payload["content"]["id"].as_s.should eq("inv-1")
        payload["content"]["total"].as_i.should eq(100)
        payload["emitted_at"].as_s.should_not be_empty
        # Transport-only fields ride along for the dispatcher, which strips
        # them before signing (decision 4).
        payload["url"].as_s.should eq("https://receiver.test/hook")
        payload["secret"].as_s.should eq("secret-key-123456")
      end
    end

    it "does nothing when no webhook matches the source doctype" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Quote", "updated", "q-1"))

        delivery_count(db).should eq(0)
      end
    end

    # ── Reentrancy ─────────────────────────────────────────────────────

    it "skips a reentrant message without enqueuing" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1", reentrant: true))

        delivery_count(db).should eq(0)
      end
    end

    # ── Event filter ───────────────────────────────────────────────────

    it "filters bindings by event name" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-created", "sales.Invoice", account_id, role_id, ", \"events\": [\"created\"]")
        create_bound_webhook(db, "wh-all", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        payloads = delivery_payloads(db)
        payloads.size.should eq(1)
        payloads.first["webhook_id"].as_s.should eq("wh-all")

        handler.call(webhook_source_message("sales", "Invoice", "created", "inv-1"))

        payloads = delivery_payloads(db)
        payloads.size.should eq(3)
        payloads.map(&.["webhook_id"].as_s).sort!.should eq(["wh-all", "wh-all", "wh-created"])
      end
    end

    it "never fires a webhook whose events list is empty" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-none", "sales.Invoice", account_id, role_id, ", \"events\": []")

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "created", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "does not fire a match-all webhook on a notified event" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-all", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(notification_message("sales", "Invoice", "inv-1", account_id))

        delivery_count(db).should eq(0)
      end
    end

    it "fires only webhooks whose events list explicitly includes notified" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-notified", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"notified\"]")
        create_bound_webhook(db, "wh-all", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(notification_message("sales", "Invoice", "inv-1", account_id))

        payloads = delivery_payloads(db)
        payloads.size.should eq(1)
        payloads.first["webhook_id"].as_s.should eq("wh-notified")
        payloads.first["event"].as_s.should eq("notified")
        # A notification is not a mutation — no mutation_id in the envelope.
        payloads.first["mutation_id"]?.should be_nil
        payloads.first["content"]["id"].as_s.should eq("inv-1")
        payloads.first["content"]["notification"]["title"].as_s.should eq("Leave approved")
      end
    end

    # ── Multiple bindings ──────────────────────────────────────────────

    it "enqueues one row per matching webhook on the same source" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-a", "sales.Invoice", account_id, role_id)
        create_bound_webhook(db, "wh-b", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(2)
        ids = delivery_payloads(db).map(&.["webhook_id"].as_s)
        ids.should contain("wh-a")
        ids.should contain("wh-b")
      end
    end

    # ── Per-binding decision (one failing binding does not block the rest)

    it "decides each binding independently: a disabled-account binding produces no row while the other enqueues" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        healthy = create_test_account(db, roles: [role_id], default_role: role_id)
        disabled = create_test_account(db, email: "disabled@example.com", roles: [role_id], default_role: role_id)
        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{status}', '\"disabled\"') WHERE id = $1",
          disabled,
        )
        create_bound_webhook(db, "wh-ok", "sales.Invoice", healthy, role_id)
        create_bound_webhook(db, "wh-blocked", "sales.Invoice", disabled, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(1)
        delivery_payloads(db).first["webhook_id"].as_s.should eq("wh-ok")
      end
    end

    # ── Enqueue-time RBAC (decision 8) ─────────────────────────────────

    it "enqueues when the binding is valid and the bound role can read the source (default state)" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "created", "inv-1"))

        delivery_count(db).should eq(1)
      end
    end

    it "skips when the role was revoked from the account" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)
        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{roles}', '[]') WHERE id = $1",
          account_id,
        )

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips when the bound account is not active" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{status}', '\"suspended\"') WHERE id = $1",
          account_id,
        )
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips when the bound role projection is deleted" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)
        Facet::Mutation::Client.delete(db, "iam", "Roles", role_id, actioner_id: "system")

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips when the webhook is disabled" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id, ", \"enabled\": false")

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips when the source document is not readable by the bound role" do
      with_db do |db|
        seed_webhook_source(db)
        # The role can read a different doctype only — `sales.Invoice` is
        # outside its reach, so the source-readability check fails.
        role_id = seed_role(db, "narrow_reader", [{"action" => "read", "on" => "other.Thing"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips a webhook with no bound account/role" do
      with_db do |db|
        seed_webhook_source(db)
        # A system-bypass create leaves account_id / role_id unset — the
        # webhook must not fire until it carries a real binding.
        create_bound_webhook(db, "wh-unbound", "sales.Invoice", nil, nil)

        handler = build_webhook_handler
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips when the webhook projection was deleted after the registry build" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        # Build the registry first, then tombstone the webhook — the stale
        # binding must not enqueue (the fresh projection read catches it).
        registry = Facet::Webhook::Registry.new
        registry.build(db)
        Facet::Mutation::Client.delete(db, "core", "Webhook", "wh-1", actioner_id: "system:test")

        handler = Facet::Webhook::Handler.new(registry)
        handler.call(webhook_source_message("sales", "Invoice", "updated", "inv-1"))

        delivery_count(db).should eq(0)
      end
    end

    # ── Aggregate child_changed events (opt-in, child-visibility gate) ──

    it "fires only webhooks whose events list explicitly includes child_changed" do
      with_db do |db|
        seed_aggregate_webhook_source(db)
        role_id = seed_role(db, "order_reader", [
          {"action" => "read", "on" => "sales.Order"},
          {"action" => "read", "on" => "sales.Line"},
        ])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-child", "sales.Order", account_id, role_id,
          ", \"events\": [\"child_changed\"]")
        create_bound_webhook(db, "wh-all", "sales.Order", account_id, role_id)

        handler = build_webhook_handler
        handler.call(aggregate_child_message("ord-1", "Line", "line-1",
          mutation_id: "mut-1", actioner_id: "act-1"))

        payloads = delivery_payloads(db)
        payloads.size.should eq(1)
        payloads.first["webhook_id"].as_s.should eq("wh-child")
        payloads.first["event"].as_s.should eq("child_changed")
        payloads.first["doc_id"].as_s.should eq("ord-1")
        payloads.first["mutation_id"].as_s.should eq("mut-1")
        # The envelope rides verbatim — the child pointer survives.
        payloads.first["content"]["id"].as_s.should eq("ord-1")
        payloads.first["content"]["child"]["doc_id"].as_s.should eq("line-1")
      end
    end

    it "does not fire a match-all webhook on a child_changed event" do
      with_db do |db|
        seed_aggregate_webhook_source(db)
        role_id = seed_role(db, "order_reader", [
          {"action" => "read", "on" => "sales.Order"},
          {"action" => "read", "on" => "sales.Line"},
        ])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-all", "sales.Order", account_id, role_id)

        handler = build_webhook_handler
        handler.call(aggregate_child_message("ord-1", "Line", "line-1"))

        delivery_count(db).should eq(0)
      end
    end

    it "skips with ChildUnreadable when the bound role cannot read the child" do
      with_db do |db|
        seed_aggregate_webhook_source(db)
        # The role reads the parent only — step 6 passes, step 7 fails.
        role_id = seed_role(db, "order_only", [{"action" => "read", "on" => "sales.Order"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-child", "sales.Order", account_id, role_id,
          ", \"events\": [\"child_changed\"]")

        handler = build_webhook_handler
        handler.call(aggregate_child_message("ord-1", "Line", "line-1"))

        delivery_count(db).should eq(0)

        # The gate itself reports the new skip reason (the replay route
        # surfaces the same label via skip_label).
        Facet::Database.with_db do |gdb|
          gate = Facet::Webhook::AuthCheck.call(gdb, "wh-child", "sales", "Order", "ord-1",
            Facet::Event::CHILD_CHANGED, aggregate_child_message("ord-1", "Line", "line-1").content)
          gate.should eq(Facet::Webhook::AuthCheck::SkipReason::ChildUnreadable)
          Facet::Webhook::AuthCheck.skip_label(gate.as(Facet::Webhook::AuthCheck::SkipReason)).should contain("child")
        end
      end
    end

    it "passes the child-visibility step when the bound role reads both documents" do
      with_db do |db|
        seed_aggregate_webhook_source(db)
        role_id = seed_role(db, "order_reader", [
          {"action" => "read", "on" => "sales.Order"},
          {"action" => "read", "on" => "sales.Line"},
        ])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-child", "sales.Order", account_id, role_id,
          ", \"events\": [\"child_changed\"]")

        Facet::Database.with_db do |gdb|
          gate = Facet::Webhook::AuthCheck.call(gdb, "wh-child", "sales", "Order", "ord-1",
            Facet::Event::CHILD_CHANGED, aggregate_child_message("ord-1", "Line", "line-1").content)
          gate.should be_a(Facet::Webhook::AuthCheck::Pass)
        end
      end
    end

    it "skips with ChannelClosed when the bound role's connectivity drops the webhook channel" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "wh_gated", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-closed", "sales.Invoice", account_id, role_id)

        # Flip the role's connectivity down to browser-only. The update
        # pipeline needs the iam.Roles definition row (the per-example
        # truncation wiped it; seed_role writes through the definition-less
        # mutation client).
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
        Facet::Doctype::DefinitionStore.cache.clear
        upd = Facet::Document::Update.call(db, "iam", "Roles", role_id,
          %({"connectivity": []}), Facet::RBAC::AuthContext.system)
        upd.should be_a(Facet::Document::Update::Result)

        Facet::Database.with_db do |gdb|
          gate = Facet::Webhook::AuthCheck.call(gdb, "wh-closed", "sales", "Invoice", "inv-1")
          gate.should eq(Facet::Webhook::AuthCheck::SkipReason::ChannelClosed)
          Facet::Webhook::AuthCheck.skip_label(gate.as(Facet::Webhook::AuthCheck::SkipReason))
            .should contain("connectivity")
        end
      end
    end

    it "keeps delivering when the bound role carries the webhook channel" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "wh_open", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-open", "sales.Invoice", account_id, role_id)

        Facet::Database.with_db do |gdb|
          gate = Facet::Webhook::AuthCheck.call(gdb, "wh-open", "sales", "Invoice", "inv-1")
          gate.should be_a(Facet::Webhook::AuthCheck::Pass)
        end
      end
    end

    it "fails closed on a child_changed payload without a usable child pointer" do
      with_db do |db|
        seed_aggregate_webhook_source(db)
        role_id = seed_role(db, "order_reader", [
          {"action" => "read", "on" => "sales.Order"},
          {"action" => "read", "on" => "sales.Line"},
        ])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-child", "sales.Order", account_id, role_id,
          ", \"events\": [\"child_changed\"]")

        bare = Facet::Event::Message.new(
          content: JSON::Any.new({"id" => JSON::Any.new("ord-1")} of String => JSON::Any),
          headers: {
            "domain"   => JSON::Any.new("sales"),
            "doc_type" => JSON::Any.new("Order"),
            "event"    => JSON::Any.new(Facet::Event::CHILD_CHANGED),
          },
        )

        Facet::Database.with_db do |gdb|
          gate = Facet::Webhook::AuthCheck.call(gdb, "wh-child", "sales", "Order", "ord-1",
            Facet::Event::CHILD_CHANGED, bare.content)
          gate.should eq(Facet::Webhook::AuthCheck::SkipReason::ChildUnreadable)
        end
      end
    end

    # ── Reconciler path (skip set + original emitted_at) ───────────────

    it "skips bindings named in skip_webhook_ids before the RBAC gate" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-skip", "sales.Invoice", account_id, role_id)
        create_bound_webhook(db, "wh-fire", "sales.Invoice", account_id, role_id)

        handler = build_webhook_handler
        handler.call(
          webhook_source_message("sales", "Invoice", "updated", "inv-1"),
          Set{"wh-skip"},
        )

        payloads = delivery_payloads(db)
        payloads.size.should eq(1)
        payloads.first["webhook_id"].as_s.should eq("wh-fire")
      end
    end

    it "stamps the emitted_at header on the payload when the message carries one" do
      with_db do |db|
        seed_webhook_source(db)
        role_id = seed_role(db, "inv_reader", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-1", "sales.Invoice", account_id, role_id)

        msg = webhook_source_message("sales", "Invoice", "updated", "inv-1",
          mutation_id: "mut-9", actioner_id: "act-9")
        msg.headers["emitted_at"] = JSON::Any.new("2026-01-02T03:04:05Z")

        handler = build_webhook_handler
        handler.call(msg)

        payloads = delivery_payloads(db)
        payloads.size.should eq(1)
        payloads.first["emitted_at"].as_s.should eq("2026-01-02T03:04:05Z")
      end
    end
  end
end
