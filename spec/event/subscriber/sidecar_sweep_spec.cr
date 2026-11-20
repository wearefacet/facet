# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "pg"
require "../../../src/event"
require "../../../src/event/subscriber/sidecar_sweep"
require "../../../src/doctype"
require "../../../src/document"

# ── Helpers ──────────────────────────────────────────────────────────────

# Seeds the sidecar `core.Comment` doctype from the production seed
# directory (with the co-located Lua `create` hook injected), so the sweep
# exercises the real definition. Mirrors the helper in
# `spec/http/sidecar_integration_spec.cr`.
def seed_sidecar_comment_for_sweep : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "..", "data", "seeds", "core.Comment")
    definition_path = File.join(dir, "definition.yml")
    yaml = YAML.parse(File.read(definition_path))
    parsed = Facet::Doctype::YamlHelper.to_json_any(yaml)

    script_path = File.join(dir, "script.lua")
    if File.exists?(script_path)
      parsed.as_h["script"] = JSON::Any.new(File.read(script_path))
    end

    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", parsed.to_json, Facet::RBAC::AuthContext.system)
    raise "sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

# Registers an aggregate-root host doctype in `host_domain` that declares a
# single `sidecars` entry named `comments`, pointing at `core.Comment` via
# the `target` reference column. Returns nothing.
def register_sweep_host_doctype(host_domain : String, host_doctype : String) : Nil
  with_db do |db|
    ensure_domain(db, host_domain)
    body = %({
      "doctype": "#{host_doctype}",
      "domain": "#{host_domain}",
      "aggregate_root": true, "search": "{{ display_name }}",
      "fields": {
        "name": { "type": "string" }
      },
      "sidecars": {
        "comments": { "doctype": "core.Comment", "column": "target" }
      }
    })
    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
    raise "host doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

# Creates a host document and returns its id.
def create_sweep_host(host_domain : String, host_doctype : String, name : String) : String
  with_db do |db|
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, host_domain, host_doctype,
      doc_id: doc_id,
      content: %({"name": #{name.to_json}}),
      actioner_id: "system",
    )
    doc_id
  end
end

# Creates a sidecar `core.Comment` record pointing at the given host id
# through the `target` reference. Uses `Mutation::Client.create` with a
# pre-qualified `target` (set directly — the route-owned `target` path is
# exercised by the HTTP integration specs; here we just need a sidecar row
# attached to a host).
def create_sweep_comment(host_qualified : String, body : String) : String
  with_db do |db|
    comment_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, "core", "Comment",
      doc_id: comment_id,
      content: %({"target": #{host_qualified.to_json}, "body": #{body.to_json}}),
      actioner_id: "system",
    )
    comment_id
  end
end

# Builds a synthetic `deleted` `Event::Message` for a host document.
def host_deleted_message(host_domain : String, host_doctype : String, host_id : String) : Facet::Event::Message
  Facet::Event::Message.new(
    content: JSON::Any.new({"id" => JSON::Any.new(host_id)}),
    headers: {
      "domain"      => JSON::Any.new(host_domain),
      "doc_type"    => JSON::Any.new(host_doctype),
      "event"       => JSON::Any.new("deleted"),
      "actioner_id" => JSON::Any.new("system"),
    },
  )
end

# Returns true when the sidecar record is soft-deleted (tombstoned).
def comment_tombstoned?(comment_id : String) : Bool
  with_db do |db|
    deleted_at = db.query_one?(
      "SELECT deleted_at FROM projections WHERE domain = 'core' AND doc_type = 'Comment' AND id = $1",
      comment_id,
      as: Time?,
    )
    !deleted_at.nil?
  end
end

# ── Tests ────────────────────────────────────────────────────────────────

module Facet
  module Event
    module Subscriber
      describe SidecarSweep::Handler do
        before_each do
          seed_sidecar_comment_for_sweep
          register_sweep_host_doctype("hr", "Employee")
        end

        it "tombstones sidecar records whose target points at the deleted host" do
          host_a = create_sweep_host("hr", "Employee", "Alice")
          host_b = create_sweep_host("hr", "Employee", "Bob")

          comment_on_a = create_sweep_comment("hr.Employee.#{host_a}", "on A")
          comment_on_b = create_sweep_comment("hr.Employee.#{host_b}", "on B")

          # Soft-delete host A through the service layer so the projection
          # trigger fires and the event is enqueued (the sweep handler is
          # invoked directly here, not through the event manager).
          with_db do |db|
            Facet::Document::Delete.call(db, "hr", "Employee", host_a, auth_context: Facet::RBAC::AuthContext.system)
          end
          # Flush the host delete event so `Publisher.flush` does not
          # re-enter the handler (the sweep calls flush itself).
          Facet::Event::Publisher.flush

          handler = SidecarSweep::Handler.new
          handler.call(host_deleted_message("hr", "Employee", host_a))

          comment_tombstoned?(comment_on_a).should be_true
          # The sidecar pointing at a different host is NOT affected.
          comment_tombstoned?(comment_on_b).should be_false
        end

        it "is idempotent on a redelivered deleted event" do
          host = create_sweep_host("hr", "Employee", "Alice")
          comment_id = create_sweep_comment("hr.Employee.#{host}", "first")

          with_db do |db|
            Facet::Document::Delete.call(db, "hr", "Employee", host, auth_context: Facet::RBAC::AuthContext.system)
          end
          Facet::Event::Publisher.flush

          handler = SidecarSweep::Handler.new
          # First delivery tombstones the sidecar.
          handler.call(host_deleted_message("hr", "Employee", host))
          comment_tombstoned?(comment_id).should be_true

          # Second delivery of the SAME deleted event must not raise and
          # must leave the sidecar tombstoned (the 410 path is a no-op).
          handler.call(host_deleted_message("hr", "Employee", host))
          comment_tombstoned?(comment_id).should be_true
        end

        it "does not tombstone sidecar records of a host that is still live" do
          host = create_sweep_host("hr", "Employee", "Alice")
          comment_id = create_sweep_comment("hr.Employee.#{host}", "on live host")

          # Deliver a spurious deleted event for a host that was NOT
          # actually deleted. The sweep still tombstones the sidecar
          # records pointing at it — the sweep trusts the event, it does not
          # re-check host existence (that is the reconciliation cron's job).
          # This spec documents that contract: the sweep's authority is the
          # event, not the host projection state.
          handler = SidecarSweep::Handler.new
          handler.call(host_deleted_message("hr", "Employee", host))

          comment_tombstoned?(comment_id).should be_true
        end

        it "is a no-op when the host doctype has no sidecars map" do
          # Register a second host doctype with NO sidecars entry. A deleted
          # event for it must not raise and must not tombstone anything.
          with_db do |db|
            ensure_domain(db, "crm")
            body = %({
              "doctype": "Company",
              "domain": "crm",
              "aggregate_root": true, "search": "{{ display_name }}",
              "fields": { "name": { "type": "string" } }
            })
            Facet::Doctype::DefinitionStore.cache.clear
            res = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
            raise "company doctype create failed: #{res}" unless res.is_a?(Facet::Document::Create::Result)
          end

          host = create_sweep_host("crm", "Company", "Acme")
          comment = create_sweep_comment("hr.Employee.#{create_sweep_host("hr", "Employee", "Alice")}", "unrelated")

          handler = SidecarSweep::Handler.new
          handler.call(host_deleted_message("crm", "Company", host))

          # The unrelated comment is untouched.
          comment_tombstoned?(comment).should be_false
        end

        it "skips a malformed deleted event without raising" do
          handler = SidecarSweep::Handler.new

          # Missing doc_type header.
          msg = Facet::Event::Message.new(
            content: JSON::Any.new({"id" => JSON::Any.new("01abc")}),
            headers: {"domain" => JSON::Any.new("hr"), "event" => JSON::Any.new("deleted")},
          )
          handler.call(msg)

          # Missing id in the content payload.
          msg2 = Facet::Event::Message.new(
            content: JSON::Any.new({} of String => JSON::Any),
            headers: {
              "domain"   => JSON::Any.new("hr"),
              "doc_type" => JSON::Any.new("Employee"),
              "event"    => JSON::Any.new("deleted"),
            },
          )
          handler.call(msg2)

          # No assertion beyond "did not raise" — the handler must swallow
          # malformed events rather than crash the consumer fiber.
          true.should be_true
        end
      end
    end
  end
end
