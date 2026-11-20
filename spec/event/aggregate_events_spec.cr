# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document"
require "../../src/event"
require "../../src/mutation/client"

# ── Setup helpers ──────────────────────────────────────────────────────────

AGG_DOMAIN = "aggevt"

# Registers a parent doctype (aggregate root with one owned child entry)
# plus the child doctype (`member_of`). Mirrors the pair the nested REST
# routes resolve against. Returns `{parent, child}` doctype names.
def register_agg_pair(db, child_defn_extra = "") : {String, String}
  ensure_domain(db, AGG_DOMAIN)
  parent = "P#{unique_suffix}"
  child = "C#{unique_suffix}"
  parent_defn = %({"doctype": "#{parent}", "domain": "#{AGG_DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
  child_defn = %({"doctype": "#{child}", "domain": "#{AGG_DOMAIN}", "aggregate_root": false, "member_of": "#{parent}", "fields": {"name": {"type": "string"}}#{child_defn_extra}})
  Facet::Doctype::DefinitionStore.invalidate("#{AGG_DOMAIN}.#{parent}")
  Facet::Doctype::DefinitionStore.invalidate("#{AGG_DOMAIN}.#{child}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))
  {parent, child}
end

# Creates a parent document and returns its projection id.
def create_agg_parent(db, parent_doctype : String) : String
  res = Facet::Document::Create.call(db, AGG_DOMAIN, parent_doctype, %({"name": "root"}), Facet::RBAC::AuthContext.system)
  expect_create_success(res).projection.id
end

# Creates a child document the way the nested route does (meta.parent_id
# override) and returns `{doc_id, mutation_id}`.
def create_agg_child(db, child_doctype : String, parent_doc_id : String) : {String, String}
  res = Facet::Document::Create.call(
    db, AGG_DOMAIN, child_doctype, %({"name": "kid"}), Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_doc_id)},
  )
  case res
  in Facet::Document::Create::Result
    {res.projection.id, res.mutation_id}
  in Facet::ServiceError
    raise "setup child create failed: #{res.message}"
  end
end

def create_agg_root_doctype(db) : String
  ensure_domain(db, AGG_DOMAIN)
  doctype = "R#{unique_suffix}"
  defn = %({"doctype": "#{doctype}", "domain": "#{AGG_DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}})
  Facet::Doctype::DefinitionStore.invalidate("#{AGG_DOMAIN}.#{doctype}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
  doctype
end

# ── Assertion helpers ──────────────────────────────────────────────────────

def child_changed_frames(channel : String) : Array(Facet::Event::Message)
  event_manager.events_for(channel).select do |m|
    m.headers["event"]?.try(&.as_s?) == Facet::Event::CHILD_CHANGED
  end
end

def frame_events(channel : String) : Array(String)
  event_manager.events_for(channel).compact_map { |m| m.headers["event"]?.try(&.as_s?) }
end

# Drains the fiber-local queue into the in-process manager, then wipes the
# stored events so assertions see only what follows.
def drain_and_clear_events : Nil
  Facet::Event::Publisher.flush
  event_manager.clear!
end

describe "aggregate child_changed events" do
  before_each do
    event_manager.clear!
  end

  it "emits exactly one child_changed keyed to the parent when a child is created" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      drain_and_clear_events

      child_id, child_mut_id = create_agg_child(db, child, parent_id)
      Facet::Event::Publisher.flush

      doc_channel = "fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}"
      frames = child_changed_frames(doc_channel)
      frames.size.should eq(1)

      frame = frames.first
      # Keyed to the parent: stream headers and payload id.
      frame.headers["doc_type"].as_s.should eq(parent)
      frame.headers["mutation_id"].as_s.should eq(child_mut_id)
      frame.content["id"].as_s.should eq(parent_id)
      frame.content["action"].as_s.should eq("created")
      frame.content["child"]["doc_type"].as_s.should eq(child)
      frame.content["child"]["doc_id"].as_s.should eq(child_id)
      frame.content["parent"]["doc_type"].as_s.should eq(parent)
      frame.content["parent"]["doc_id"].as_s.should eq(parent_id)

      # The child's own cause rides the frame (root request cause here).
      frame.headers["cause"].as_h["kind"].as_s.should eq("request")
      frame.headers["cause"].as_h["trace"].as_s.should eq(child_mut_id)

      # Collection channel is skipped — the payload is not a document-id frame.
      event_manager.events_for("fanout:#{AGG_DOMAIN}.#{parent}").should be_empty

      # The frame lands on the parent's stream, and the child's own stream
      # carries only the child's own created event.
      child_changed_frames("FACET:RESOURCE:#{AGG_DOMAIN}:#{parent}").size.should eq(1)
      frame_events("FACET:RESOURCE:#{AGG_DOMAIN}:#{child}").should eq(["created"])
    end
  end

  it "emits child_changed with action updated when a child is updated" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      child_id, _ = create_agg_child(db, child, parent_id)
      drain_and_clear_events

      res = Facet::Document::Update.call(db, AGG_DOMAIN, child, child_id, %({"name": "grown"}), Facet::RBAC::AuthContext.system)
      res.should be_a(Facet::Document::Update::Result)
      mut_id = res.as(Facet::Document::Update::Result).mutation_id
      Facet::Event::Publisher.flush

      frames = child_changed_frames("fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}")
      frames.size.should eq(1)
      frames.first.content["action"].as_s.should eq("updated")
      frames.first.content["child"]["doc_id"].as_s.should eq(child_id)
      frames.first.headers["mutation_id"].as_s.should eq(mut_id)
    end
  end

  it "emits child_changed with action deleted when a child is deleted directly" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      child_id, _ = create_agg_child(db, child, parent_id)
      drain_and_clear_events

      res = Facet::Document::Delete.call(db, AGG_DOMAIN, child, child_id, Facet::RBAC::AuthContext.system)
      res.should be_a(Facet::Document::Delete::Result)
      Facet::Event::Publisher.flush

      frames = child_changed_frames("fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}")
      frames.size.should eq(1)
      frames.first.content["action"].as_s.should eq("deleted")
      frames.first.content["child"]["doc_id"].as_s.should eq(child_id)
    end
  end

  it "emits child_changed when an action updates a child" do
    with_db do |db|
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.touch(ctx, args)
          ctx.root.name = ctx.root.name .. "!"
        end
        return export
      LUA
      extra = ", \"actions\": {\"touch\": {\"args\": {}}}, \"script\": #{script.to_json}"
      parent, child = register_agg_pair(db, extra)
      parent_id = create_agg_parent(db, parent)
      child_id, _ = create_agg_child(db, child, parent_id)
      drain_and_clear_events

      res = Facet::Document::Action.call(db, AGG_DOMAIN, child, child_id, "touch", "{}", Facet::RBAC::AuthContext.system)
      result = expect_action_success(res)
      Facet::Event::Publisher.flush

      frames = child_changed_frames("fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}")
      frames.size.should eq(1)
      frames.first.content["action"].as_s.should eq("updated")
      frames.first.headers["mutation_id"].as_s.should eq(result.mutation_id)
      # The action's cause rides the frame.
      frames.first.headers["cause"].as_h["kind"].as_s.should eq("action")
      frames.first.headers["cause"].as_h["name"].as_s.should eq("touch")
    end
  end

  it "emits nothing for a root create" do
    with_db do |db|
      doctype = create_agg_root_doctype(db)
      drain_and_clear_events

      create_agg_parent(db, doctype)
      Facet::Event::Publisher.flush

      # The root's own created frame rides its channels; no child_changed.
      child_changed_frames("FACET:RESOURCE:#{AGG_DOMAIN}:#{doctype}").should be_empty
    end
  end

  it "emits nothing when the child definition declares no member_of" do
    with_db do |db|
      orphan = create_agg_root_doctype(db)
      drain_and_clear_events

      res = Facet::Document::Create.call(
        db, AGG_DOMAIN, orphan, %({"name": "stray"}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new("some-parent")},
      )
      expect_create_success(res)
      Facet::Event::Publisher.flush

      # Without member_of there is no parent doctype to key the frame.
      child_changed_frames("fanout:#{AGG_DOMAIN}.#{orphan}:some-parent").should be_empty
    end
  end

  it "suppresses the whole cascade when a parent is deleted" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      child_id, _ = create_agg_child(db, child, parent_id)
      drain_and_clear_events

      res = Facet::Document::Delete.call(db, AGG_DOMAIN, parent, parent_id, Facet::RBAC::AuthContext.system)
      res.should be_a(Facet::Document::Delete::Result)
      Facet::Event::Publisher.flush

      # No child_changed anywhere: the parent's own deleted frame covers
      # the teardown, and the cascade child carries only its own frame.
      child_changed_frames("fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}").should be_empty
      frame_events("fanout:#{AGG_DOMAIN}.#{child}:#{child_id}").should eq(["deleted"])
    end
  end

  it "mirrors reentrant onto the frame" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      child_id, _ = create_agg_child(db, child, parent_id)
      drain_and_clear_events

      # The delete path exposes the reentrant flag (as replication-driven
      # deletes do); the frame must mirror it.
      res = Facet::Document::Delete.call(db, AGG_DOMAIN, child, child_id, Facet::RBAC::AuthContext.system, reentrant: true)
      res.should be_a(Facet::Document::Delete::Result)
      Facet::Event::Publisher.flush

      frames = child_changed_frames("fanout:#{AGG_DOMAIN}.#{parent}:#{parent_id}")
      frames.size.should eq(1)
      frames.first.headers["reentrant"]?.try(&.as_bool?).should be_true
    end
  end

  it "emits nothing for a core parent" do
    with_db do |db|
      drain_and_clear_events

      # The guard fires before any lookup — no core rows are needed. A
      # frame on a core channel would evict doctype caches spuriously.
      Facet::Event::Publisher.enqueue_child_changed(
        db, "core", "DocType", "some.domain",
        parent_doc_id: "some.domain", action: "created",
        mutation_id: Facet::Util::ScriptHelpers.ulid, actioner_id: "system",
      )

      Facet::Event::Publisher.pending_count.should eq(0)
      child_changed_frames("fanout:core.Domain:some.domain").should be_empty
      child_changed_frames("FACET:RESOURCE:core:Domain").should be_empty
    end
  end

  it "suppresses a cascade-kind cause at the helper" do
    with_db do |db|
      parent, child = register_agg_pair(db)
      parent_id = create_agg_parent(db, parent)
      drain_and_clear_events

      cause = Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Cascade).resolve("mut-1")
      Facet::Event::Publisher.enqueue_child_changed(
        db, AGG_DOMAIN, child, "child-1",
        parent_doc_id: parent_id, action: "deleted",
        mutation_id: "mut-1", actioner_id: "system", cause: cause,
      )

      Facet::Event::Publisher.pending_count.should eq(0)
    end
  end
end
