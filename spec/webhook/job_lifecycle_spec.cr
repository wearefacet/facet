# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/webhook"
require "../../src/mutation/client"
require "../../src/jobs/manager"
require "../support/webhook_helper"

# Stage 8 wiring: the four import/export job lifecycle events are opt-in
# for webhooks (a match-all binding never fires), and the enqueue-time
# gate steps 6 swaps to the source doctype's own projection — the event
# subject is a job id, not a projection row.

def build_job_lifecycle_handler : Facet::Webhook::Handler
  registry = Facet::Webhook::Registry.new
  Facet::Database.with_db { |db| registry.build(db) }
  Facet::Webhook::Handler.new(registry)
end

def job_event_message(event_name : String, job_id : String) : Facet::Event::Message
  Facet::Event::Message.new(
    content: JSON::Any.new({
      "id"     => JSON::Any.new(job_id),
      "import" => JSON::Any.new({
        "row_count" => JSON::Any.new(3_i64),
        "created"   => JSON::Any.new(2_i64),
        "updated"   => JSON::Any.new(1_i64),
        "skipped"   => JSON::Any.new(0_i64),
      } of String => JSON::Any),
    } of String => JSON::Any),
    headers: {
      "domain"      => JSON::Any.new("sales"),
      "doc_type"    => JSON::Any.new("Invoice"),
      "event"       => JSON::Any.new(event_name),
      "actioner_id" => JSON::Any.new("requester-1"),
    },
  )
end

def job_lifecycle_job_count(db) : Int64
  db.query_one("SELECT count(*) FROM background_jobs WHERE kind = 'webhook_delivery'", as: Int64)
end

def job_lifecycle_delivery_payload(db) : JSON::Any
  db.query_one(
    "SELECT payload FROM background_jobs WHERE kind = 'webhook_delivery' ORDER BY id LIMIT 1",
    as: JSON::Any,
  )
end

module Facet
  describe "Webhook job lifecycle events (import/export)" do
    before_each do
      with_db(&.exec("DELETE FROM background_jobs"))
      Facet::Jobs::Manager.instance = Facet::Jobs::Manager.new
    end

    after_each do
      Facet::Jobs::Manager.reset!
    end

    it "delivers an explicit opt-in binding and carries the report + job id, no row data" do
      with_db do |db|
        # The doctype definition row exists (via Mutation::Client.create).
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Invoice",
          content: %({"doctype": "Invoice", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
          actioner_id: "system:test",
        )
        role_id = seed_role(db, "jimp_reader", [{"action" => "read", "on" => "core.DocType"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-jimp", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"import_completed\"]")

        job_id = Util::ScriptHelpers.ulid
        build_job_lifecycle_handler.call(job_event_message("import_completed", job_id))

        job_lifecycle_job_count(db).should eq(1)
        payload = job_lifecycle_delivery_payload(db)
        payload["event"].as_s.should eq("import_completed")
        payload["doc_id"].as_s.should eq(job_id)
        payload["content"]["import"]["created"].as_i.should eq(2)
      end
    end

    it "never fires a match-all binding, and unrelated event names never fire an opt-in binding" do
      with_db do |db|
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Invoice",
          content: %({"doctype": "Invoice", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
          actioner_id: "system:test",
        )
        role_id = seed_role(db, "jimp_reader2", [{"action" => "read", "on" => "core.DocType"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-all", "sales.Invoice", account_id, role_id)
        create_bound_webhook(db, "wh-created", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"created\"]")
        create_bound_webhook(db, "wh-imp", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"import_completed\"]")

        handler = build_job_lifecycle_handler
        job_id = Util::ScriptHelpers.ulid

        # A match-all binding and a created-only binding never receive it.
        handler.call(job_event_message("import_completed", job_id))
        job_lifecycle_job_count(db).should eq(1) # only wh-imp

        # Unrelated opt-in names don't match the import_completed binding.
        with_db(&.exec("DELETE FROM background_jobs"))
        handler.call(job_event_message("export_completed", job_id))
        job_lifecycle_job_count(db).should eq(0)
      end
    end

    it "skips when the bound role cannot read the source doctype's definition" do
      with_db do |db|
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Invoice",
          content: %({"doctype": "Invoice", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
          actioner_id: "system:test",
        )
        # The step-6 gate swaps to the source doctype's own core.DocType
        # row. A document-plane line on sales.Invoice still reads that row
        # (the metadata gate makes definition rows visible to roles that
        # read the doctype's documents), so the deny needs a role with no
        # read/create/update/delete line on sales.Invoice. This role has a
        # line on a different doctype only. (The source document row is
        # absent too, but the doctype gate fires first for job lifecycle
        # events.)
        role_id = seed_role(db, "jimp_no_doctype", [{"action" => "read", "on" => "sales.Customer"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-deny", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"import_completed\"]")

        handler = build_job_lifecycle_handler
        handler.call(job_event_message("import_completed", Util::ScriptHelpers.ulid))

        job_lifecycle_job_count(db).should eq(0)
      end
    end

    it "delivers to a role that only reads the source doctype's documents (metadata-gate definition visibility)" do
      with_db do |db|
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Invoice",
          content: %({"doctype": "Invoice", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
          actioner_id: "system:test",
        )
        # No read line on core.DocType. The metadata gate (B-86) makes the
        # definition row visible to a role that can read the doctype's
        # documents, so the gate passes and the event is delivered.
        role_id = seed_role(db, "jimp_docplane", [{"action" => "read", "on" => "sales.Invoice"}])
        account_id = create_test_account(db, roles: [role_id], default_role: role_id)
        create_bound_webhook(db, "wh-docplane", "sales.Invoice", account_id, role_id,
          ", \"events\": [\"import_completed\"]")

        handler = build_job_lifecycle_handler
        job_id = Util::ScriptHelpers.ulid
        handler.call(job_event_message("import_completed", job_id))

        job_lifecycle_job_count(db).should eq(1)
        payload = job_lifecycle_delivery_payload(db)
        payload["event"].as_s.should eq("import_completed")
        payload["doc_id"].as_s.should eq(job_id)
      end
    end
  end
end
