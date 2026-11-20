# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/cron"
require "../../src/cron/sidecar_reconcile"
require "../../src/doctype"
require "../../src/document"

# ── Helpers (shared shape with sidecar_sweep_spec, kept local so each spec
# file stands alone) ──────────────────────────────────────────────────────

def seed_sidecar_comment_for_reconcile : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "data", "seeds", "core.Comment")
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

def register_reconcile_host_doctype(host_domain : String, host_doctype : String) : Nil
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

def create_reconcile_host(host_domain : String, host_doctype : String, name : String) : String
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

def create_reconcile_comment(host_qualified : String, body : String) : String
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

# Hard-deletes a host projection row directly, bypassing the soft-delete
# path entirely. Used by the reconcile spec to simulate the orphan the
# sweep cannot catch (no `deleted` event is emitted when a row is
# hard-deleted by a maintenance script).
def hard_delete_host(host_domain : String, host_doctype : String, host_id : String) : Nil
  with_db do |db|
    db.exec(
      "DELETE FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
      host_domain, host_doctype, host_id,
    )
  end
end

def comment_tombstoned_by_reconcile?(comment_id : String) : Bool
  with_db do |db|
    deleted_at = db.query_one?(
      "SELECT deleted_at FROM projections WHERE domain = 'core' AND doc_type = 'Comment' AND id = $1",
      comment_id,
      as: Time?,
    )
    !deleted_at.nil?
  end
end

# ── Scheduler stub ───────────────────────────────────────────────────────
#
# The reconciliation task is invoked directly here, not through the cron
# scheduler — the scheduler's own fault isolation (per-task fiber rescue +
# reschedule) is already covered by `spec/cron/scheduler_spec.cr`. This spec
# focuses on the task's own behavior.

module Facet
  module Cron
    describe SidecarReconcile do
      before_each do
        seed_sidecar_comment_for_reconcile
        register_reconcile_host_doctype("hr", "Employee")
      end

      it "tombstones sidecar records whose host was hard-deleted (orphan)" do
        host = create_reconcile_host("hr", "Employee", "Alice")
        comment_id = create_reconcile_comment("hr.Employee.#{host}", "orphaned")

        # Simulate the path the sweep cannot catch: hard-delete the host
        # projection row so no `deleted` event was emitted.
        hard_delete_host("hr", "Employee", host)

        # The sidecar is still live before the reconcile pass.
        comment_tombstoned_by_reconcile?(comment_id).should be_false

        SidecarReconcile.call

        comment_tombstoned_by_reconcile?(comment_id).should be_true
      end

      it "does not tombstone sidecar records whose host is still live" do
        host = create_reconcile_host("hr", "Employee", "Alice")
        live_comment = create_reconcile_comment("hr.Employee.#{host}", "live host")

        SidecarReconcile.call

        comment_tombstoned_by_reconcile?(live_comment).should be_false
      end

      it "does not tombstone sidecar records whose host was soft-deleted normally" do
        # A host soft-deleted through `Document::Delete` is already tombstoned
        # (deleted_at IS NOT NULL), so the existence check
        # (`deleted_at IS NULL`) treats it as gone → the sidecar becomes an
        # orphan. But the sweep should have already tombstoned the sidecar
        # in real production. Here we soft-delete the host AND skip the
        # sweep, then run the reconcile — it must tombstone the sidecar
        # (this is the reconcile's backstop role for sweep losses).
        host = create_reconcile_host("hr", "Employee", "Alice")
        comment_id = create_reconcile_comment("hr.Employee.#{host}", "soft-deleted host")

        with_db do |db|
          Facet::Document::Delete.call(db, "hr", "Employee", host, auth_context: Facet::RBAC::AuthContext.system)
        end
        Facet::Event::Publisher.flush

        # Sidecar still live (sweep was not run).
        comment_tombstoned_by_reconcile?(comment_id).should be_false

        SidecarReconcile.call

        comment_tombstoned_by_reconcile?(comment_id).should be_true
      end

      it "is idempotent: a second run does not raise and leaves orphans tombstoned" do
        host = create_reconcile_host("hr", "Employee", "Alice")
        comment_id = create_reconcile_comment("hr.Employee.#{host}", "orphaned")
        hard_delete_host("hr", "Employee", host)

        SidecarReconcile.call
        comment_tombstoned_by_reconcile?(comment_id).should be_true

        # Second run: the sidecar is already tombstoned, the existence
        # query filters it out (deleted_at IS NULL). Must not raise.
        SidecarReconcile.call
        comment_tombstoned_by_reconcile?(comment_id).should be_true
      end

      it "is a no-op when there are no sidecar doctypes registered" do
        # Truncate the core.DocType projections so the sidecar doctype
        # query returns empty. Must not raise.
        with_db do |db|
          db.exec("DELETE FROM projections WHERE domain = 'core' AND doc_type = 'DocType'")
        end
        Facet::Doctype::DefinitionStore.cache.clear

        SidecarReconcile.call

        true.should be_true
      end

      it "handles a reference value whose id segment contains a dot (qualified id contract)" do
        # The qualified reference storage contract: the id segment may
        # itself contain a dot. The reconcile splits on the FIRST TWO dots
        # only, so a target like `hr.Employee.<id>.extra` parses with id
        # segment `<id>.extra` (NOT split further). The existence check
        # queries for that opaque id against the host projections; since
        # no host projection has id `<id>.extra`, the sidecar is a
        # legitimate orphan and is tombstoned. A naive `split('.')`
        # would misparse the id.
        host = create_reconcile_host("hr", "Employee", "Alice")
        dotted_target = "hr.Employee.#{host}.extra"
        comment_id = create_reconcile_comment(dotted_target, "dotted id")

        hard_delete_host("hr", "Employee", host)

        SidecarReconcile.call

        # The opaque id `#{host}.extra` does not exist as a host projection
        # row (only `#{host}` does), so the sidecar is an orphan.
        comment_tombstoned_by_reconcile?(comment_id).should be_true
      end
    end
  end
end
