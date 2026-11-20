# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"
require "../../src/event/message"

# Mirrors `spec/replication/handler_spec.cr`'s `source_message` helper —
# builds a message in the wire shape that the `Event::Manager` would
# hand the handler. The `reentrant:` flag is the one-hop gate (decision 5).
def hooks_source_message(domain, doc_type, event_name, source_id, *, reentrant = false) : Facet::Event::Message
  headers = {
    "domain"   => JSON::Any.new(domain),
    "doc_type" => JSON::Any.new(doc_type),
    "event"    => JSON::Any.new(event_name),
  }
  headers["reentrant"] = JSON::Any.new(true) if reentrant
  Facet::Event::Message.new(
    content: JSON::Any.new({"id" => JSON::Any.new(source_id)}),
    headers: headers,
  )
end

# Writes a hook onto a `core.Domain` document by bypassing the authoring
# gate (used in tests that focus on the runtime dispatch path, not the
# authoring gate, which is exercised by `authoring_gate_spec.cr`).
# Writes a hook onto a `core.Domain` document by bypassing the authoring
# gate (used in tests that focus on the runtime dispatch path, not the
# authoring gate, which is exercised by `authoring_gate_spec.cr`).
#
# `hooks_json` is a JSON string for the `hooks` array. The caller is
# responsible for ensuring embedded Lua script strings are JSON-escaped;
# the cleanest way is to build the array via `Array#to_json` so Crystal
# escapes `"` and `\n` automatically.
def upsert_domain_with_hook(db, owning_domain, hooks_array : Array)
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

# Builds an event-hook entry hash. `events` is an optional event-name
# whitelist used by the `source_events` filter.
def event_hook_entry(id, script, source_domain, source_doc_type = nil, events = nil)
  src = {} of String => (String | Array(String))
  src["domain"] = source_domain
  src["doc_type"] = source_doc_type if source_doc_type
  src["events"] = events if events
  entry = {"id" => id, "kind" => "event", "script" => script, "source" => src}
  entry
end

# Files an active grant from the hook's source domain to the owning
# domain — the G3 fire gate requires it for foreign sources. `doctypes`
# are the source doctypes the hook listens to; untagged fields resolve to
# `default`, so a `default` entry admits the fire.
def grant_hook_source(db, source_domain, owning_domain, doctypes : Array(String)) : Nil
  ensure_domain(db, source_domain)
  resources = doctypes.map { |dt| {doctype: dt, tags: ["default"]} }
  upsert_grant(db, source_domain, owning_domain, resources.to_json)
end

# An event hook that writes a marker document into the owning domain.
# The Lua-side JSON string is escaped carefully so the concatenated
# value is valid JSON: `='{"body": "from hook on ' .. ctx.event.domain .. '.' .. ctx.event.doc_type .. '"}'`.
HOOK_THAT_WRITES_MARKER = <<-LUA
  local export = {}
  function export.on_event(ctx)
    local body = 'from hook on ' .. ctx.event.domain .. '.' .. ctx.event.doc_type
    local json = '{"body": "' .. body .. '"}'
    pcall(document.create, 'Note', json)
  end
  return export
LUA

# An event hook whose `source_events` selector limits it to a single
# event name — used to test the event-name filter.
HOOK_FILTERED_TO_CREATED = <<-LUA
  local export = {}
  function export.on_event(ctx)
    pcall(document.create, "Note", '{"body": "only on created"}')
  end
  return export
LUA

# An event hook that reads a field off the delivered content and writes
# its value into a marker Note — proves the hook sees the source
# document's field values, not just the id.
HOOK_THAT_READS_STATUS = <<-LUA
  local export = {}
  function export.on_event(ctx)
    local value = tostring(ctx.event.content.status)
    pcall(document.create, 'Note', '{"body": "status=' .. value .. '"}')
  end
  return export
LUA

# An event hook that reports the delivered content's key names — proves
# the exact shape of `ctx.event.content` (the id-only frame vs the full
# body).
HOOK_THAT_REPORTS_KEYS = <<-LUA
  local export = {}
  function export.on_event(ctx)
    local keys = {}
    for k, _ in pairs(ctx.event.content) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    pcall(document.create, 'Note', '{"body": "keys=' .. table.concat(keys, ',') .. '"}')
  end
  return export
LUA

def note_bodies(db, owning_domain) : Array(String)
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

# Builds the wire shape of an aggregate child_changed frame keyed to the
# parent, with the child pointer in the payload.
def hooks_child_changed_message(domain, parent_doctype, parent_doc_id, child_doctype, child_doc_id) : Facet::Event::Message
  Facet::Event::Message.new(
    content: JSON::Any.new({
      "id"     => JSON::Any.new(parent_doc_id),
      "action" => JSON::Any.new("updated"),
      "child"  => JSON::Any.new({
        "doc_type" => JSON::Any.new(child_doctype),
        "doc_id"   => JSON::Any.new(child_doc_id),
      } of String => JSON::Any),
      "parent" => JSON::Any.new({
        "doc_type" => JSON::Any.new(parent_doctype),
        "doc_id"   => JSON::Any.new(parent_doc_id),
      } of String => JSON::Any),
    } of String => JSON::Any),
    headers: {
      "domain"   => JSON::Any.new(domain),
      "doc_type" => JSON::Any.new(parent_doctype),
      "event"    => JSON::Any.new(Facet::Event::CHILD_CHANGED),
    },
  )
end

# Seeds the source pair the child_changed hooks listen to: sales.Order
# (parent) ← sales.Line (child), plus the sales.Note marker target.
def seed_hook_target_pair(db) : Nil
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Order",
    content: %({"doctype": "Order", "domain": "sales", "fields": {"total": {"type": "integer"}}, "children": {"items": {"doctype": "Line", "collection": true}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Line",
    content: %({"doctype": "Line", "domain": "sales", "member_of": "Order", "fields": {"qty": {"type": "integer"}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Note",
    content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
    actioner_id: "system:test",
  )
end

# Seeds the `<domain>.Contract` source doctype (title + status, both
# untagged, so a `default` grant covers them) and one live document with
# field values.
def seed_contract_source(db, domain, doc_id) : Nil
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "#{domain}.Contract",
    content: %({"doctype": "Contract", "domain": "#{domain}", "fields": {"title": {"type": "string"}, "status": {"type": "string"}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, domain, "Contract",
    doc_id: doc_id,
    content: %({"title": "Frame", "status": "on_hold"}),
    actioner_id: "system:test",
  )
end

# Seeds the `sales.Note` marker doctype the hook scripts write into.
private def seed_note_doctype(db) : Nil
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Note",
    content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
    actioner_id: "system:test",
  )
end

module Facet::Hooks
  describe Handler do
    # ── Reentrant skip ───────────────────────────────────────────────

    it "skips a reentrant message without writing" do
      with_db do |db|
        restore_seeded_baseline(db)

        # Owning domain + its hook.
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_WRITES_MARKER, "accountancy", "Contract")])
        # Consumer Note doctype so document.create lands.
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1", reentrant: true))

        note_bodies(db, "sales").should be_empty
      end
    end

    # ── Happy-path dispatch ───────────────────────────────────────────

    it "runs the matching hook and writes a marker document via document.create" do
      with_db do |db|
        restore_seeded_baseline(db)

        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_WRITES_MARKER, "accountancy", "Contract")])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1"))

        bodies = note_bodies(db, "sales")
        bodies.size.should eq(1)
        bodies.first.should contain("accountancy.Contract")
      end
    end

    # ── Unknown source doctype → no-op ────────────────────────────────

    it "does nothing when no hook matches the source doctype" do
      with_db do |db|
        restore_seeded_baseline(db)
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_WRITES_MARKER, "accountancy", "Contract")])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Invoice", "updated", "src-1"))

        note_bodies(db, "sales").should be_empty
      end
    end

    # ── Event-name filter ─────────────────────────────────────────────

    it "runs a filtered hook only when the event name matches source_events" do
      with_db do |db|
        restore_seeded_baseline(db)
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_FILTERED_TO_CREATED, "accountancy", "Contract", ["created"])])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        # An `updated` event does not match the `created` filter — skip.
        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1"))
        note_bodies(db, "sales").should be_empty

        # A `created` event matches — the hook writes.
        handler.call(hooks_source_message("accountancy", "Contract", "created", "src-2"))
        note_bodies(db, "sales").size.should eq(1)
      end
    end

    # ── Multi-hook fan-out runs in declaration order ─────────────────

    it "runs each matching hook in declaration order" do
      with_db do |db|
        restore_seeded_baseline(db)
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [
          event_hook_entry("first", "local export = {} function export.on_event(ctx) pcall(document.create, \"Note\", '{\"body\": \"first\"}') end return export", "accountancy", "Contract"),
          event_hook_entry("second", "local export = {} function export.on_event(ctx) pcall(document.create, \"Note\", '{\"body\": \"second\"}') end return export", "accountancy", "Contract"),
        ])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1"))

        # Both hooks wrote a Note — order preserved in declaration order
        # (first → second).
        note_bodies(db, "sales").should eq(["first", "second"])
      end
    end

    # ── Lua failure does not abort the rest of the fan-out ───────────

    it "logs and skips a hook that raises a Lua runtime error, then continues" do
      with_db do |db|
        restore_seeded_baseline(db)
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        # First hook raises; second hook is healthy.
        upsert_domain_with_hook(db, "sales", [
          event_hook_entry("bomb", "local export = {} function export.on_event(ctx) local b = nil; b() end return export", "accountancy", "Contract"),
          event_hook_entry("healthy", HOOK_THAT_WRITES_MARKER, "accountancy", "Contract"),
        ])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1"))

        # The healthy hook still ran despite the bomb hook raising.
        bodies = note_bodies(db, "sales")
        bodies.size.should eq(1)
        bodies.first.should contain("accountancy.Contract")
      end
    end

    # ── Domain-wide hook expansion dispatches for any doctype ────────

    it "dispatches a domain-wide hook for any doctype in the source domain" do
      with_db do |db|
        restore_seeded_baseline(db)

        # Two doctypes in the source domain, both must trigger the
        # domain-wide hook.
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "accountancy.Contract",
          content: %({"doctype": "Contract", "domain": "accountancy", "fields": {"title": {"type": "string"}}}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "accountancy.Invoice",
          content: %({"doctype": "Invoice", "domain": "accountancy", "fields": {"amount": {"type": "integer"}}}),
          actioner_id: "system:test",
        )

        # Domain-wide hook on sales — no `doc_type` in `source`. The fire
        # gate checks the concrete source doctype per event, so the grant
        # names both.
        grant_hook_source(db, "accountancy", "sales", ["Contract", "Invoice"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("wide", HOOK_THAT_WRITES_MARKER, "accountancy")])
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "sales.Note",
          content: %({"doctype": "Note", "domain": "sales", "fields": {"body": {"type": "string"}}}),
          actioner_id: "system:test",
        )

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        # Trigger on Contract — hook fires.
        handler.call(hooks_source_message("accountancy", "Contract", "updated", "src-1"))
        # Trigger on Invoice — the same domain-wide hook fires.
        handler.call(hooks_source_message("accountancy", "Invoice", "updated", "src-2"))

        bodies = note_bodies(db, "sales")
        bodies.size.should eq(2)
        bodies[0].should contain("accountancy.Contract")
        bodies[1].should contain("accountancy.Invoice")
      end
    end

    # ── Aggregate child_changed source events ────────────────────

    it "fires a hook whose source_events names child_changed" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_hook_target_pair(db)

        # Owning domain sales, hook scoped to the parent doctype and the
        # aggregate event name.
        upsert_domain_with_hook(db, "sales", [
          event_hook_entry("h-child", HOOK_THAT_WRITES_MARKER, "sales", "Order", ["child_changed"]),
        ])

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_child_changed_message("sales", "Order", "ord-1", "Line", "line-1"))

        bodies = note_bodies(db, "sales")
        bodies.size.should eq(1)
        bodies.first.should contain("sales.Order")
      end
    end

    it "keeps match-all hooks receiving child_changed (no opt-in machinery)" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_hook_target_pair(db)

        # No `events` in the source selector — match all.
        upsert_domain_with_hook(db, "sales", [
          event_hook_entry("h-wide", HOOK_THAT_WRITES_MARKER, "sales", "Order"),
        ])

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_child_changed_message("sales", "Order", "ord-1", "Line", "line-1"))

        note_bodies(db, "sales").size.should eq(1)
      end
    end

    it "does not fire a hook whose source_events excludes child_changed" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_hook_target_pair(db)

        upsert_domain_with_hook(db, "sales", [
          event_hook_entry("h-created", HOOK_FILTERED_TO_CREATED, "sales", "Order", ["created"]),
        ])

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_child_changed_message("sales", "Order", "ord-1", "Line", "line-1"))

        note_bodies(db, "sales").should be_empty
      end
    end

    # ── Source document body delivery ─────────────────────────────

    it "delivers the source document body to a same-domain hook" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_contract_source(db, "sales", "c-1")
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_READS_STATUS, "sales", "Contract")])
        seed_note_doctype(db)

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("sales", "Contract", "updated", "c-1"))

        note_bodies(db, "sales").should eq(["status=on_hold"])
      end
    end

    it "delivers the granted field values of the body to a foreign-source hook" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_contract_source(db, "accountancy", "c-1")
        grant_hook_source(db, "accountancy", "sales", ["Contract"])
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_READS_STATUS, "accountancy", "Contract")])
        seed_note_doctype(db)

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("accountancy", "Contract", "updated", "c-1"))

        note_bodies(db, "sales").should eq(["status=on_hold"])
      end
    end

    it "keeps the id-only frame when the source document is missing" do
      with_db do |db|
        restore_seeded_baseline(db)
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_REPORTS_KEYS, "sales", "Contract")])
        seed_note_doctype(db)

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("sales", "Contract", "updated", "missing-1"))

        note_bodies(db, "sales").should eq(["keys=id"])
      end
    end

    it "keeps the id-only frame when the source document is a tombstone" do
      with_db do |db|
        restore_seeded_baseline(db)
        seed_contract_source(db, "sales", "c-1")
        upsert_domain_with_hook(db, "sales", [event_hook_entry("h", HOOK_THAT_REPORTS_KEYS, "sales", "Contract")])
        seed_note_doctype(db)

        Facet::Document::Delete.call(db, "sales", "Contract", "c-1", Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Delete::Result)

        registry = Registry.new
        registry.build(db)
        handler = Handler.new(registry)

        handler.call(hooks_source_message("sales", "Contract", "deleted", "c-1"))

        note_bodies(db, "sales").should eq(["keys=id"])
      end
    end
  end
end
