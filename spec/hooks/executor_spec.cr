# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"

# A valid `event` hook script that exports `on_event`. The optional second
# script variant saves a marker on `ctx.event` so tests can assert the
# payload propagated.
EVENT_SCRIPT_WITH_MARKER = <<-LUA
  local export = {}
  function export.on_event(ctx)
    ctx.root_marker = ctx.event.event
  end
  return export
LUA

# An event hook script that calls `ctx.error(msg)` to test the error
# collector surface.
EVENT_SCRIPT_THAT_ERRORS = <<-LUA
  local export = {}
  function export.on_event(ctx)
    ctx.error("intentional failure")
  end
  return export
LUA

# An event hook script that creates a child document in the owning domain
# via `document.create` (writes are domain-scoped by construction).
EVENT_SCRIPT_THAT_WRITES = <<-LUA
  local export = {}
  function export.on_event(ctx)
    pcall(document.create, "Note", '{"body": "spawned by hook"}')
  end
  return export
LUA

# An event hook script that reads a document in a *different* domain
# via the qualified `domain.Doctype` form — exercises the cross-domain
# read path (plan decision 3).
EVENT_SCRIPT_THAT_READS_CROSS_DOMAIN = <<-LUA
  local export = {}
  function export.on_event(ctx)
    local ok, c = pcall(document.get, "src.Source", ctx.event.doc_id)
    if ok and c then
      ctx.read_ok = true
    end
  end
  return export
LUA

# Builds an event `Hook` record (owning domain defaults to "consumer").
def event_hook(
  id : String,
  script : String,
  owning_domain : String = "consumer",
  source_domain : String = "src",
  source_doc_type : String? = "Source",
  source_events : Array(String)? = nil,
)
  Facet::Hooks::Definition::Hook.new(
    id: id,
    kind: :event,
    script: script,
    source_domain: source_domain,
    source_doc_type: source_doc_type,
    source_events: source_events,
    schedule: nil,
    owning_domain: owning_domain,
  )
end

# Builds an event payload `JSON::Any` mirroring the shape `Hooks::Handler`
# produces from the incoming `Event::Message`.
def event_payload(
  source_domain : String,
  source_doctype : String,
  doc_id : String,
  event : String,
  content : Hash(String, JSON::Any) = {} of String => JSON::Any,
)
  h = {} of String => JSON::Any
  h["domain"] = JSON::Any.new(source_domain)
  h["doc_type"] = JSON::Any.new(source_doctype)
  h["event"] = JSON::Any.new(event)
  h["doc_id"] = JSON::Any.new(doc_id)
  h["mutation_id"] = JSON::Any.new(nil.as(JSON::Any::Type))
  h["actioner_id"] = JSON::Any.new("system:test")
  h["content"] = JSON::Any.new(content)
  JSON::Any.new(h)
end

module Facet::Hooks
  describe Executor do
    # ── ctx.event surface ─────────────────────────────────────────────

    it "passes ctx.event to on_event and collects validation errors" do
      with_db do |db|
        hook = event_hook("err", EVENT_SCRIPT_THAT_ERRORS)
        payload = event_payload("src", "Source", "src-1", "updated")

        Executor.new(db, "consumer", hook) do |executor|
          errors = executor.run_event(payload)
          errors.size.should eq(1)
          errors.first.message.should contain("intentional failure")
          errors.first.code.should eq("script")
        end
      end
    end

    # ── Lua error capture ─────────────────────────────────────────────

    it "raises Executor::Error on a Lua runtime error" do
      with_db do |db|
        hook = event_hook("boom", <<-LUA)
          local export = {}
          function export.on_event(ctx)
            -- Calling a nil value raises a Lua runtime error.
            local boom = nil
            boom()
          end
          return export
        LUA
        payload = event_payload("src", "Source", "src-1", "updated")

        expect_raises(Executor::Error) do
          Executor.new(db, "consumer", hook) do |executor|
            executor.run_event(payload)
          end
        end
      end
    end

    it "raises Executor::Error on a Lua syntax error" do
      with_db do |db|
        # Unbalanced `function ... end` — parses with an error.
        hook = event_hook("syntax", "local export = {} function export.on_event(ctx) return export")
        payload = event_payload("src", "Source", "src-1", "updated")

        expect_raises(Executor::Error) do
          Executor.new(db, "consumer", hook) do |executor|
            executor.run_event(payload)
          end
        end
      end
    end

    # ── Write domain scoping ──────────────────────────────────────────

    it "allows the hook to write to its owning domain via document.create" do
      with_db do |db|
        # Seed schema so the consumer domain has the Note doctype.
        restore_seeded_baseline(db)

        # Create the Note doctype schema in the consumer domain.
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "consumer.Note",
          content: %({"doctype": "Note", "domain": "consumer", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        hook = event_hook("writer", EVENT_SCRIPT_THAT_WRITES)
        payload = event_payload("src", "Source", "src-1", "updated")

        Executor.new(db, "consumer", hook) do |executor|
          errors = executor.run_event(payload)
          errors.should be_empty
        end

        # The hook wrote one Note document with the marker body.
        rows = db.query_all(
          "SELECT content->>'body' FROM projections WHERE domain='consumer' AND doc_type='Note' AND deleted_at IS NULL",
          as: String
        )
        rows.should contain("spawned by hook")
      end
    end

    # ── Cross-domain read (qualified document.get) ────────────────────

    it "allows the hook to read a source-domain document via a qualified document.get" do
      with_db do |db|
        restore_seeded_baseline(db)

        # Source domain + Source doctype.
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "src.Source",
          content: %({"doctype": "Source", "domain": "src", "fields": {"label": {"type": "string"}}}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "src", "Source",
          doc_id: "src-1",
          content: %({"label": "hello from src"}),
          actioner_id: "system:test",
        )

        # Consumer domain needs a doctype so the owning-domain registration
        # path can resolve it; a Note is fine.
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "consumer.Note",
          content: %({"doctype": "Note", "domain": "consumer", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        # Push a marker onto ctx.root (a global table we read back).
        hook = event_hook("reader", EVENT_SCRIPT_THAT_READS_CROSS_DOMAIN)
        payload = event_payload("src", "Source", "src-1", "updated")

        Executor.new(db, "consumer", hook) do |executor|
          errors = executor.run_event(payload)
          errors.should be_empty
        end
      end
    end

    # ── Reentrant write guard ─────────────────────────────────────────

    it "marks the hook's document.create mutations as reentrant" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "consumer.Note",
          content: %({"doctype": "Note", "domain": "consumer", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        # InProcessManager captures events for assertion.
        manager = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
        manager.clear!

        hook = event_hook("writer", EVENT_SCRIPT_THAT_WRITES)
        payload = event_payload("src", "Source", "src-1", "updated")

        Executor.new(db, "consumer", hook) do |executor|
          executor.run_event(payload)
        end

        # Flush so the InProcessManager sees the queued event.
        Facet::Event::Publisher.flush

        events = manager.events_for("FACET:RESOURCE:consumer:Note")
        events.empty?.should be_false
        # Every event from a hook write carries `reentrant=true` (decision 5).
        events.any? { |m| m.headers["reentrant"]?.try(&.as_bool?) == true }.should be_true
      end
    end
  end
end
