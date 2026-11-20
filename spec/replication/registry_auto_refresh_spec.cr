# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/replication"
require "../../src/doctype"
require "../../src/document"
require "../../src/domain"
require "../../src/rbac"
require "../../src/event/subscriber/doctype_cache"
require "../replication/validator_spec" # brings this spec's describe blocks

# Uses a dedicated Redis database (9) — same convention as
# spec/event/manager_spec.cr — to avoid colliding with development data.
# The spec mirrors that file's Redis-backed pattern because
# `Replication::Manager#refresh` early-returns unless `@started` is true,
# which requires a real `Event::Manager.start`.
TEST_REPL_REDIS_URL = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

# ── Spec scope ──────────────────────────────────────────────────────────────
#
# These specs verify the event-driven registry invalidation path:
#
# 1. A `core.DocType` mutation (create, update, publish) enqueues a fanout
#    event via `Event::Publisher.enqueue` + `flush`.
# 2. The `Subscriber::DoctypeCache` Pub/Sub subscriber receives each event
#    on `fanout:core.DocType:*` and calls `Replication::Manager#mark_registry_stale`.
# 3. The next registry read (`bindings_for` / `source_doctypes` /
#    `consumer_domains`) rebuilds lazily from the DB via `ensure_fresh`.
#
# Unlike direct `refresh(db)` calls, the path is
# async (Redis Pub/Sub latency) — so these specs poll for the registry to
# reach the expected state rather than asserting synchronously after the
# transaction commits.

# ── Helpers ─────────────────────────────────────────────────────────────────

# Best-effort ping of the test Redis. Returns true when reachable.
def replication_test_redis_available? : Bool
  client = ::Redis::Client.new(URI.parse(TEST_REPL_REDIS_URL))
  begin
    client.ping
    true
  rescue
    false
  ensure
    client.close rescue nil
  end
end

# Builds and starts a real `Replication::Manager` against the test Redis,
# registers it as the process-wide singleton, AND starts a real
# `Subscriber::DoctypeCache` Pub/Sub subscriber on the same Redis so the
# event-driven invalidation path is exercised end-to-end. The publisher
# manager is also swapped to a real Redis-backed `Event::Manager` so
# `Event::Publisher.flush` actually PUBLISHes to Redis (the in-process
# manager used by the rest of the suite does not reach Pub/Sub).
#
# Always stops + clears the singleton and restores the in-process publisher
# manager afterwards.
def with_replication_manager(& : Facet::Replication::Manager ->)
  client = ::Redis::Client.new(URI.parse(TEST_REPL_REDIS_URL))
  begin
    client.flushdb
  ensure
    client.close
  end

  # Swap the global publisher manager to a real Redis-backed one for the
  # duration of this spec so `Event::Publisher.flush` reaches Redis Pub/Sub
  # (and thus the DoctypeCache subscriber). Restore afterwards.
  #
  # All three Redis clients (publisher manager, DoctypeCache subscriber,
  # replication manager) MUST share the same Redis URL/DB — otherwise the
  # publisher writes to one DB and the subscriber listens on another and
  # nothing reaches the registry.
  saved_publisher = Facet::Event::Publisher.manager
  event_config = Facet::Event::Config.new(url: TEST_REPL_REDIS_URL, partitions: 2)
  publisher_manager = Facet::Event::Manager.new(
    config: event_config,
    service_id: "repl-pub-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
  )
  publisher_manager.start
  Facet::Event::Publisher.manager = publisher_manager

  # Start the DoctypeCache Pub/Sub subscriber — the load-bearing piece.
  doctype_cache = Facet::Event::Subscriber::DoctypeCache.new(
    redis_url: TEST_REPL_REDIS_URL,
    service_id: "repl-doctype-cache-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
  )
  doctype_cache.start

  manager = Facet::Replication::Manager.new(
    config: Facet::Config.instance,
    service_id: "repl-refresh-test-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
    domain_enabled: ->(_d : String) { true },
  )

  Facet::Database.with_db do |db|
    manager.start(db)
  end

  # Install as the process-wide singleton so the `DoctypeCache` subscriber
  # can reach it via `Replication::Manager.instance`.
  Facet::Replication::Manager.instance = manager

  begin
    yield manager
  ensure
    manager.stop
    Facet::Replication::Manager.instance = nil
    doctype_cache.stop
    publisher_manager.stop
    Facet::Event::Publisher.manager = saved_publisher
  end
end

# Polls `manager.registry` until `predicate` returns true or a deadline
# (default ~1500×5ms = 7.5s) elapses. The event-driven invalidation path is
# async across Redis Pub/Sub — assertions must wait for the subscriber to
# process the fanout event and the next read to rebuild. The check itself is
# in-memory, so the 5 ms interval keeps both the wait granularity and the
# poll cost small.
def wait_for_registry(manager, max_iters = 1500, sleep_ms = 5, & : -> Bool)
  max_iters.times do
    return if yield
    sleep sleep_ms.milliseconds
  end
  raise "Registry did not reach expected state within #{max_iters * sleep_ms}ms"
end

# Registers a complete identity.Person → hr.Employee replication pair,
# creating both doctypes via the public `Doctype::Create.call` path (so the
# wiring under test fires). `on_source_delete` defaults to "keep".
def register_replicate_pair_via_api(db, *, on_source_delete : String = "keep")
  ensure_domain(db, "identity")
  ensure_domain(db, "hr")
  upsert_domain_with_grants(db, "identity", %([
    {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
  ]))

  person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Person",
    "domain": "identity",
    "schema_version": 1,
    "aggregate_root": false,
    "fields": {
      "full_name": {"type": "string", "required": true},
      "email":     {"type": "string", "required": true}
    }
  }))
  res = Facet::Doctype::Create.call(db, "core", "DocType", person_defn.to_json, Facet::RBAC::AuthContext.system)
  res.should be_a(Facet::Doctype::Create::Result)

  ensure_domain(db, "hr")
  employee_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Employee",
    "domain": "hr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "job_title": {"type": "string", "required": true},
      "person":    {"type": "reference", "doctype": "identity.Person", "required": true},
      "person_full_name": {
        "type": "string",
        "replicate": {"via": "person", "field": "full_name"},
        "on_source_delete": "#{on_source_delete}"
      }
    }
  }))
  res2 = Facet::Doctype::Create.call(db, "core", "DocType", employee_defn.to_json, Facet::RBAC::AuthContext.system)
  res2.should be_a(Facet::Doctype::Create::Result)
end

# Removes the hr.Employee doctype's `person_full_name` replicate field by
# updating the definition. Used to test that *removal* of an edge is picked
# up by the registry refresh.
#
# Passes `$force: true` because removing a field on a same-version update
# is a destructive edit that the same-version guard rejects without it —
# the test is exercising registry refresh, not the guard.
def remove_replicate_field_via_api(db)
  employee_no_replica = %({
    "$force": true,
    "doctype": "Employee",
    "domain": "hr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "job_title": {"type": "string", "required": true},
      "person":    {"type": "reference", "doctype": "identity.Person", "required": true}
    }
  })
  res = Facet::Doctype::Update.call(db, "hr.Employee", employee_no_replica, Facet::RBAC::AuthContext.system)
  res.should be_a(Facet::Doctype::Update::Result)
end

# ── Specs ───────────────────────────────────────────────────────────────────

describe "Replication registry auto-refresh on doctype mutations" do
  # These specs require a real Redis because `Replication::Manager#refresh`
  # early-returns unless `@started` is true, and `Event::Manager.start`
  # needs Redis. When Redis is unreachable, mark the whole block pending
  # rather than failing.
  redis_available = replication_test_redis_available?
  skip_msg = "requires Redis at #{TEST_REPL_REDIS_URL} (set EVENT_REDIS_URL)"

  describe "create path", tags: %(redis) do
    it "picks up a new replication edge after Doctype::Create.call" do
      pending skip_msg unless redis_available

      with_replication_manager do |manager|
        # Before: registry is empty.
        manager.registry.source_doctypes.should be_empty
        manager.registry.consumer_domains.should be_empty

        Facet::Database.with_transaction do |db|
          register_replicate_pair_via_api(db)
        end
        Facet::Event::Publisher.flush

        # The `core.DocType` `registered` event flows Redis Pub/Sub →
        # DoctypeCache subscriber → mark_registry_stale → lazy rebuild on
        # the next read. Async across Pub/Sub latency — poll for the outcome.
        wait_for_registry(manager) do
          manager.registry.source_doctypes.includes?("identity.Person")
        end

        manager.registry.source_doctypes.should contain("identity.Person")
        manager.registry.consumer_domains.should contain("hr")
        bindings = manager.registry.bindings_for("identity.Person")
        bindings.size.should eq(1)
        bindings[0].consumer_domain.should eq("hr")
        bindings[0].consumer_doctype.should eq("Employee")
        bindings[0].replica_field.should eq("person_full_name")
        bindings[0].source_field.should eq("full_name")
      end
    end
  end

  describe "update path", tags: %(redis) do
    it "drops a removed replication edge after Doctype::Update.call removes the replicate field" do
      pending skip_msg unless redis_available

      with_replication_manager do |manager|
        Facet::Database.with_transaction do |db|
          register_replicate_pair_via_api(db)
        end
        Facet::Event::Publisher.flush
        wait_for_registry(manager) do
          manager.registry.source_doctypes.includes?("identity.Person")
        end

        # Update the consumer doctype to drop its replicate field.
        Facet::Database.with_transaction do |db|
          remove_replicate_field_via_api(db)
        end
        Facet::Event::Publisher.flush

        # The `updated` fanout event must mark the registry stale so the
        # next read rebuilds and sees the removed edge gone.
        wait_for_registry(manager) do
          manager.registry.bindings_for("identity.Person").empty?
        end

        manager.registry.source_doctypes.should_not contain("identity.Person")
        manager.registry.consumer_domains.should_not contain("hr")
      end
    end
  end

  describe "grant path", tags: %(redis) do
    it "picks up an edge when the producer domain's grants are patched (no doctype mutation)" do
      pending skip_msg unless redis_available

      with_replication_manager do |manager|
        # The consumer doctype already carries the replicate field; the
        # producer domain doc starts WITHOUT any grants. The first registry
        # build therefore fail-closes the edge.
        Facet::Database.with_transaction do |db|
          ensure_domain(db, "identity")
          person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "identity",
            "schema_version": 1,
            "aggregate_root": false,
            "fields": {
              "full_name": {"type": "string", "required": true}
            }
          }))
          Facet::Doctype::Create.call(db, "core", "DocType", person_defn.to_json, Facet::RBAC::AuthContext.system)

          employee_pair = %({
            "doctype": "Customer",
            "domain": "orders",
            "schema_version": 1,
            "aggregate_root": true, "search": "{{ display_name }}",
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person", "required": true},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          })
          ensure_domain(db, "orders")
          res = Facet::Doctype::Create.call(db, "core", "DocType", employee_pair, Facet::RBAC::AuthContext.system)
          res.should be_a(Facet::Doctype::Create::Result)
        end

        # Consume the create-path fanout, then wait for the fail-closed
        # rebuild: the edge must be cut while the grant is absent.
        wait_for_registry(manager) do
          manager.registry.bindings_for("identity.Person").empty?
        end

        # Patch the producer domain's grants — a `core.Domain` mutation that
        # emits NO `core.DocType` event. The DoctypeCache subscriber's
        # domain branch must still mark the replication registry stale, or
        # the grant-less build above would serve forever.
        Facet::Database.with_transaction do |db|
          ensure_domain(db, "identity")
          upsert_domain_with_grants(db, "identity", %([
            {"to": "orders", "doctype": "Person", "fields": ["full_name"]}
          ]))
        end
        Facet::Event::Publisher.flush

        wait_for_registry(manager) do
          manager.registry.bindings_for("identity.Person").any? do |b|
            b.consumer_domain == "orders" && b.replica_field == "person_full_name"
          end
        end
      end
    end
  end

  describe "publish path", tags: %(redis) do
    it "picks up edges from a published draft's target domain" do
      pending skip_msg unless redis_available

      with_replication_manager do |manager|
        # Build a draft domain whose Employee doctype references
        # identity.Person exactly as the live hr.Employee does. identity is
        # the live source; the draft is the consumer.
        Facet::Database.with_transaction do |db|
          ensure_domain(db, "identity")
          upsert_domain_with_grants(db, "identity", %([
            {"to": "orders", "doctype": "Person", "fields": ["full_name"]}
          ]))
          person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "identity",
            "schema_version": 1,
            "aggregate_root": false,
            "fields": {
              "full_name": {"type": "string", "required": true}
            }
          }))
          Facet::Doctype::Create.call(db, "core", "DocType", person_defn.to_json, Facet::RBAC::AuthContext.system)

          # Create the draft domain + consumer doctype directly (drafts
          # bypass the normal Doctype::Create domain-name regex).
          draft = Facet::Domain::Draft.create(db, "{}", "system:test")
            .as(Facet::Domain::Draft::Result).projection.id
          draft_employee = Facet::Doctype::DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "#{draft}",
            "schema_version": 1,
            "aggregate_root": true, "search": "{{ display_name }}",
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person", "required": true},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"},
                "on_source_delete": "keep"
              }
            }
          }))
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "#{draft}.Employee",
            content: draft_employee.to_json,
            actioner_id: "system:test",
          )

          # Pre-publish: the draft's bindings are filtered out, so the
          # registry must NOT see the draft as a consumer.
          manager.registry.consumer_domains.should be_empty

          # Publish the draft into a real-named domain. `Domain::Copy.structure`
          # enqueues a `core.DocType` `registered` event for each copied
          # doctype; `Event::Publisher.flush` (called below) delivers it to
          # Redis Pub/Sub → DoctypeCache subscriber → mark_registry_stale →
          # the next read rebuilds and picks up the new "orders" domain edge.
          result = Facet::Domain::Publish.call(db, draft, "orders", actioner_id: "system:test")
          result.should be_a(Facet::Domain::Publish::Result)
        end
        Facet::Event::Publisher.flush

        # Async: wait for the registry to mark stale + rebuild, picking up
        # the published "orders" domain as a consumer of identity.Person.
        wait_for_registry(manager) do
          manager.registry.consumer_domains.includes?("orders")
        end

        # After publish: "orders" (the target) should appear as a
        # consumer of identity.Person, not the dropped draft.
        manager.registry.source_doctypes.should contain("identity.Person")
        manager.registry.consumer_domains.should contain("orders")
        # No draft domain should leak into the consumer set.
        manager.registry.consumer_domains.none?(&.starts_with?("_")).should be_true

        bindings = manager.registry.bindings_for("identity.Person")
        bindings.any? { |b| b.consumer_domain == "orders" && b.replica_field == "person_full_name" }.should be_true
      end
    end
  end
end

# Ensure the singleton is cleared between examples even if
# `with_replication_manager`'s ensure doesn't run (e.g. on an unexpected raise
# during yield).
Spec.after_each do
  Facet::Replication::Manager.instance = nil rescue nil
end
