# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "json"
require "../../src/rbac"

describe Facet::Document::Delete do
  it "soft-deletes a document" do
    with_temp_doctype("deletetest") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "ToDelete"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)

      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      proj.deleted_at.should_not be_nil
    end
  end

  it "returns error for non-existent document" do
    with_temp_doctype("deletenotfound") do |db, domain, doctype|
      ensure_domain(db, domain)
      result = Facet::Document::Delete.call(db, domain, doctype, "nonexistent", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "rejects deleting an already-deleted document" do
    with_temp_doctype("deletetwice") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "DoubleDelete"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(410)
      err.message.should contain("was already deleted")
    end
  end

  # ── Lua delete lifecycle hook ──────────────────────────────────────

  it "runs the Lua delete hook when the doctype has a script" do
    with_temp_doctype("luadel1") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.delete(ctx)
          ctx.root.deleted_note = "deleted by " .. ctx.actor_id
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "deleted_note": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "ToDelete"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)

      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      proj.deleted_at.should_not be_nil
    end
  end

  it "rejects delete when the Lua delete hook calls ctx.error()" do
    with_temp_doctype("luadel2") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.delete(ctx)
          if ctx.root.status == 'protected' then
            ctx.error('cannot delete protected documents')
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Protected", "status": "protected"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Script validation failed")
      err.details.not_nil!.map(&.message).should contain("cannot delete protected documents")
    end
  end

  it "skips the Lua delete hook when the doctype has no script" do
    with_temp_doctype("luadel3") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "ToDelete"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)

      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      proj.deleted_at.should_not be_nil
    end
  end

  # ── core.Domain is not deletable through the generic path ───────────
  # Tombstoning only the core.Domain document would orphan the domain's
  # doctype definitions, data, views, and index rows. Domain deletion goes
  # through `Domain::Drop` (POST /Api/core/Domain/:id/drop), which tears
  # down the whole owned surface and records the audit mutation. Covered
  # end to end by spec/http/domain_drop_http_spec.cr.
  describe "core.Domain refusal" do
    it "refuses to delete a core.Domain document with 422" do
      with_db do |db|
        restore_seeded_baseline(db)

        domain_name = "cascade#{unique_suffix(6)}"
        ensure_domain(db, domain_name)

        result = Facet::Document::Delete.call(db, "core", "Domain", domain_name, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("/Api/core/Domain/:id/drop")

        # The domain document is untouched.
        proj = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", domain_name)
        proj.deleted_at.should be_nil
      end
    end
  end

  # ── Cascade: owned child documents (member_of) ──────────────────
  # Deleting a parent document soft-deletes every owned child document —
  # children whose doctype declares member_of equal to the parent's
  # doctype, linked via meta.parent_id. This is the composition-tree
  # cascade path exercised by Document::Delete#cascade_delete_children.
  describe "owned child cascade" do
    it "deleting a parent document tombstones its owned child documents" do
      with_temp_doctype("delcasc") do |db, domain, doctype|
        ensure_domain(db, domain)

        child_dt = "#{doctype}Child"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        cwc = Facet::Document::Create.call(
          db, domain, doctype,
          %({"name": "Parent"}),
          Facet::RBAC::AuthContext.system,
        )
        cwc.should be_a(Facet::Document::Create::Result)
        parent_id = cwc.as(Facet::Document::Create::Result).projection.id

        # Owned children carry meta.parent_id — the composition link the
        # cascade walks (`owned_child_ids` filters on meta->>'parent_id').
        child_ids = ["Cog A", "Cog B"].map do |label|
          cres = Facet::Document::Create.call(
            db, domain, child_dt,
            %({"label": "#{label}"}),
            Facet::RBAC::AuthContext.system,
            meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
          )
          cres.should be_a(Facet::Document::Create::Result)
          cres.as(Facet::Document::Create::Result).projection.id
        end

        result = Facet::Document::Delete.call(db, domain, doctype, parent_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Delete::Result)

        # Cascade: every owned child document must be tombstoned.
        child_ids.each do |child_id|
          child = Facet::Mutation::Client.fetch_projection(db, domain, child_dt, child_id)
          child.deleted_at.should_not be_nil
        end
      end
    end
  end

  # ── Reentrant delete (hook → event → hook gate) ────────────────────
  # A hook that calls `document.delete` runs under the Hooks::Executor,
  # which registers the Lua helpers with `reentrant: true`. The resulting
  # `deleted` events must carry the `reentrant` header so the downstream
  # hook / replication / webhook handlers skip them (one-hop cycle gate).

  it "marks the deleted event reentrant when requested" do
    with_temp_doctype("delreent") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Hooked"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      manager = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
      manager.clear!

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system, reentrant: true)
      result.should be_a(Facet::Document::Delete::Result)
      Facet::Event::Publisher.flush

      events = manager.events_for("FACET:RESOURCE:#{domain}:#{doctype}")
      deleted = events.select { |m| m.headers["event"]?.try(&.as_s?) == "deleted" }
      deleted.empty?.should be_false
      deleted.all? { |m| m.headers["reentrant"]?.try(&.as_bool?) == true }.should be_true
    end
  end

  it "leaves the deleted event non-reentrant by default" do
    with_temp_doctype("delnoreent") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Plain"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      manager = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
      manager.clear!

      result = Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)
      Facet::Event::Publisher.flush

      events = manager.events_for("FACET:RESOURCE:#{domain}:#{doctype}")
      deleted = events.select { |m| m.headers["event"]?.try(&.as_s?) == "deleted" }
      deleted.empty?.should be_false
      deleted.all? { |m| m.headers["reentrant"]?.nil? }.should be_true
    end
  end
end
