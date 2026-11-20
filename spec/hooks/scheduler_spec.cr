# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"
require "../../src/event/message"
require "../../src/doctype/seed"
require "../../src/mutation/client"
require "../../src/rbac"

# Re-seeds core doctype schema definitions after the per-spec TRUNCATE.
def seed_core_schemas_for_scheduler(db)
  restore_seeded_baseline(db)
end

# A minimal valid `schedule` hook script — exports `on_schedule` and writes
# a marker Note whose body records `ctx.scheduled_at` so the spec can assert
# both that the hook fired and that the cron-computed bucket (not `now`)
# was passed as `ctx.scheduled_at`. The JSON is built by closing the
# single-quoted Lua string before `..` so the concatenation actually runs
# (Lua single-quoted strings are literal — `..` inside the quotes is text).
SCHEDULE_SCRIPT_THAT_WRITES_MARKER = <<-LUA
  local export = {}
  function export.on_schedule(ctx)
    local json = '{"body": "fired at ' .. ctx.scheduled_at .. '"}'
    pcall(document.create, "Note", json)
  end
  return export
LUA

# A `schedule` hook script that raises a Lua runtime error — the lease
# stays held and a second instance must not refire the same bucket.
SCHEDULE_SCRIPT_THAT_RAISES = <<-LUA
  local export = {}
  function export.on_schedule(ctx)
    local boom = nil
    boom()
  end
  return export
LUA

# Persists a `core.Domain` with the given `hooks` array (authoring-time
# validation runs). Idempotent on the doc id. Draft when `draft: true`.
def ensure_domain_with_schedule_hook(db, domain_id, hooks_json, draft = false)
  body = %({"hooks": #{hooks_json}#{" , \"draft\": true" if draft}})
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain_id,
    content: body,
    actioner_id: "system:test",
  )
end

# A schedule-hook JSON entry with a 5-field cron expression. Returns the
# JSON object for ONE hook; callers wrap it in an array when building the
# `hooks` array on the domain content.
def schedule_hook_entry(id, script, cron)
  %({"id": "#{id}", "kind": "schedule", "schedule": "#{cron}", "script": #{script.to_json}})
end

# Creates a `core.DocType` for a `Note` doctype in the owning domain, so
# `document.create("Note", ...)` inside the hook has a target schema.
private def seed_note_doctype(db, owning_domain)
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{owning_domain}.Note",
    content: %({"doctype": "Note", "domain": "#{owning_domain}", "fields": {"body": {"type": "string"}}}),
    actioner_id: "system:test",
  )
end

# Returns the `body` field of every live Note in the owning domain.
def note_bodies_in(db, owning_domain) : Array(String)
  db.query_all(
    <<-SQL,
      SELECT content->>'body' FROM projections
      WHERE domain=$1 AND doc_type='Note' AND deleted_at IS NULL
        AND content ? 'body'
    SQL
    owning_domain,
    as: String
  )
end

# Redis integration URL — mirrors `spec/event/manager_spec.cr`. Uses a
# dedicated DB (9) to avoid colliding with development data.
SCHEDULER_REDIS_URL = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

private def with_scheduler_redis(& : ::Redis::Client ->)
  client = ::Redis::Client.new(URI.parse(SCHEDULER_REDIS_URL))
  begin
    yield client
  ensure
    client.close
  end
end

# An in-memory lease acquirer for pure-logic tests. Wins the first call for
# a key, refuses every subsequent call for the same key. No TTL — used only
# by tests that don't exercise lease expiry (those use real Redis instead).
class InMemoryLease
  @held = Set(String).new
  @mutex = Mutex.new

  def acquire : Proc(String, Int32, String, Bool)
    ->(key : String, _ttl : Int32, _owner : String) : Bool do
      @mutex.synchronize { @held.add?(key).nil? ? false : true }
    end
  end
end

module Facet::Hooks
  describe Scheduler do
    # ── Pure-logic (no Redis): bucket computation + draft gating ────────

    describe "tick (pure logic)" do
      it "computes the fire bucket as the most recent cron instant at or before now" do
        # Seed in its own transaction so the scheduler — which opens its own
        # `Database.with_db` connection to fire the hook — sees the committed
        # doctype + domain. The scheduler's hook writes commit independently.
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "sales",
            "[#{schedule_hook_entry("minutely", SCHEDULE_SCRIPT_THAT_WRITES_MARKER, "* * * * *")}]",
          )
          seed_note_doctype(db, "sales")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        # A clock pinned to 03:12:30 UTC — `*/5 * * * *` last fired at 03:10:00.
        # (`Cron::Parser#last` returns the fire strictly before `now`, so the
        # 03:10 bucket is the most recent completed fire.)
        pinned = Time.utc(2024, 1, 15, 3, 12, 30)
        leases = InMemoryLease.new
        scheduler = Scheduler.new(
          registry: registry,
          redis_url: SCHEDULER_REDIS_URL,
          service_id: "test-pure",
          clock: -> { pinned },
          acquire_lease: leases.acquire,
        )

        scheduler.tick(pinned)
        Facet::Event::Publisher.flush

        with_db do |db|
          bodies = note_bodies_in(db, "sales")
          bodies.size.should eq(1)
          # `ctx.scheduled_at` is the cron bucket — `last(03:12:30)` for
          # `* * * * *` returns 03:11:00 (fire strictly before `now`).
          bodies.first.should contain("03:11:00")
        end
      end

      it "does nothing when the registry has no schedule hooks" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          # A published domain with no hooks at all.
          Facet::Mutation::Client.create(
            db, "core", "Domain",
            doc_id: "empty",
            content: %({"hooks": []}),
            actioner_id: "system:test",
          )
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        leases = InMemoryLease.new
        scheduler = Scheduler.new(
          registry: registry,
          redis_url: SCHEDULER_REDIS_URL,
          service_id: "test-empty",
          acquire_lease: leases.acquire,
        )

        # No fire, no exception.
        scheduler.tick(Time.utc)
      end

      it "does not fire a schedule hook declared on a draft domain" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "draft",
            "[#{schedule_hook_entry("h", SCHEDULE_SCRIPT_THAT_WRITES_MARKER, "* * * * *")}]",
            draft: true,
          )
          seed_note_doctype(db, "draft")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        # The draft domain's schedule hooks never enter the registry.
        registry.schedule_hooks.should be_empty

        leases = InMemoryLease.new
        scheduler = Scheduler.new(
          registry: registry,
          redis_url: SCHEDULER_REDIS_URL,
          service_id: "test-draft",
          acquire_lease: leases.acquire,
        )

        scheduler.tick(Time.utc)

        with_db { |db| note_bodies_in(db, "draft").should be_empty }
      end
    end

    # ── Redis-backed: lease + double-fire prevention ──────────────────────

    describe "lease (real Redis)" do
      before_each do
        with_scheduler_redis(&.flushdb)
      end

      it "fires the hook exactly once when a single instance is ticking" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "sales",
            "[#{schedule_hook_entry("minutely", SCHEDULE_SCRIPT_THAT_WRITES_MARKER, "* * * * *")}]",
          )
          seed_note_doctype(db, "sales")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        pinned = Time.utc(2024, 1, 15, 3, 12, 30)
        scheduler = Scheduler.new(
          registry: registry,
          redis_url: SCHEDULER_REDIS_URL,
          service_id: "single",
          clock: -> { pinned },
        )

        scheduler.tick(pinned)

        with_db do |db|
          bodies = note_bodies_in(db, "sales")
          bodies.size.should eq(1)
          bodies.first.should contain("03:11:00")
        end

        # Reticking at the same clock must NOT refire — same bucket, lease held.
        scheduler.tick(pinned)
        with_db { |db| note_bodies_in(db, "sales").size.should eq(1) }
      end

      it "prevents two instances from firing the same bucket" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "sales",
            "[#{schedule_hook_entry("minutely", SCHEDULE_SCRIPT_THAT_WRITES_MARKER, "* * * * *")}]",
          )
          seed_note_doctype(db, "sales")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        pinned = Time.utc(2024, 1, 15, 3, 12, 30)

        # Two schedulers racing on the same Redis lease.
        a = Scheduler.new(
          registry: registry, redis_url: SCHEDULER_REDIS_URL,
          service_id: "instance-a", clock: -> { pinned },
        )
        b = Scheduler.new(
          registry: registry, redis_url: SCHEDULER_REDIS_URL,
          service_id: "instance-b", clock: -> { pinned },
        )

        a.tick(pinned)
        b.tick(pinned)

        # Exactly one marker — the lease blocked the loser.
        with_db { |db| note_bodies_in(db, "sales").size.should eq(1) }
      end

      it "advances to the next bucket on a fresh lease key" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "sales",
            "[#{schedule_hook_entry("minutely", SCHEDULE_SCRIPT_THAT_WRITES_MARKER, "* * * * *")}]",
          )
          seed_note_doctype(db, "sales")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        # Any short TTL works here: the same-bucket re-tick below still
        # proves lease blocking, and the next bucket uses a new lease key.
        scheduler = Scheduler.new(
          registry: registry,
          redis_url: SCHEDULER_REDIS_URL,
          service_id: "ttl",
          lease_ttl_s: 1,
        )

        first_bucket = Time.utc(2024, 1, 15, 3, 12, 30)
        scheduler.tick(first_bucket)
        with_db { |db| note_bodies_in(db, "sales").size.should eq(1) }

        # Same bucket, same instance — lease still held (within TTL).
        scheduler.tick(first_bucket)
        with_db { |db| note_bodies_in(db, "sales").size.should eq(1) }

        # Tick the next bucket. `last(3:13:30)` is 3:13:00 — a new bucket —
        # and the bucket unix second is part of the lease key. The third
        # tick therefore resolves a different key, and the first lease's
        # TTL is not a factor; no wall-clock wait is needed.
        next_bucket = Time.utc(2024, 1, 15, 3, 13, 30)
        scheduler.tick(next_bucket)
        with_db { |db| note_bodies_in(db, "sales").size.should eq(2) }
      end

      it "keeps the lease held when the hook raises a Lua error" do
        with_db do |db|
          seed_core_schemas_for_scheduler(db)
          ensure_domain_with_schedule_hook(
            db, "sales",
            "[#{schedule_hook_entry("bomb", SCHEDULE_SCRIPT_THAT_RAISES, "* * * * *")}]",
          )
          seed_note_doctype(db, "sales")
        end

        registry = Registry.new
        with_db { |db| registry.build(db) }

        pinned = Time.utc(2024, 1, 15, 3, 12, 30)
        a = Scheduler.new(
          registry: registry, redis_url: SCHEDULER_REDIS_URL,
          service_id: "bomb-a", clock: -> { pinned },
        )
        b = Scheduler.new(
          registry: registry, redis_url: SCHEDULER_REDIS_URL,
          service_id: "bomb-b", clock: -> { pinned },
        )

        # First instance acquires the lease, then raises.
        a.tick(pinned)
        # No marker written — the script raised.
        with_db { |db| note_bodies_in(db, "sales").should be_empty }

        # Second instance on the same bucket: lease still held (Lua error
        # did not release it), so no fire.
        b.tick(pinned)
        with_db { |db| note_bodies_in(db, "sales").should be_empty }
      end
    end
  end
end
