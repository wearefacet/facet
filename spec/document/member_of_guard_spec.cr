# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

describe Facet::Document::Create do
  describe "member_of flat-create guard" do
    it "refuses a member_of child created without parent linkage" do
      with_temp_doctype("mogbasic") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        result = Facet::Document::Create.call(db, domain, child_dt, %({"label": "stray"}), Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.message.should eq("Document '#{child_dt}' belongs to '#{doctype}'; create it through the parent's nested route")
      end
    end

    it "creates a member_of child when the create carries parent linkage and stamps parent_id on the mutation" do
      with_temp_doctype("moglink") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        parent = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "P"}), Facet::RBAC::AuthContext.system)).projection
        created = expect_create_success(Facet::Document::Create.call(
          db, domain, child_dt, %({"label": "anchored"}), Facet::RBAC::AuthContext.system,
          meta_overrides: {"parent_id" => JSON::Any.new(parent.id)},
        ))
        created.projection.meta["parent_id"].as_s.should eq(parent.id)

        row = db.query_one(
          "SELECT arguments->'meta'->>'parent_id' FROM mutations WHERE id = $1",
          created.mutation_id,
          as: String?,
        )
        row.should eq(parent.id)
      end
    end

    it "refuses a parentless member_of child created through the Lua document.create binding" do
      with_temp_doctype("moglua") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            local ok, err = pcall(document.create, "#{child_dt}", { label = "stray" })
            if not ok then
              ctx.root.stray_error = tostring(err)
            end
          end
          return export
        LUA
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}, "stray_error": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}, "script": #{script.to_json}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        result = Facet::Document::Create.call(db, domain, doctype, %({"name": "P"}), Facet::RBAC::AuthContext.system)
        proj = expect_create_success(result).projection
        proj.content["stray_error"].as_s.should contain("Document '#{child_dt}' belongs to '#{doctype}'")
        proj.content["stray_error"].as_s.should contain("create it through the parent's nested route")

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = $1 AND doc_type = $2",
          domain, child_dt, as: Int64)
        count.should eq(0)
      end
    end

    it "answers an uncaught nested create refusal in a create hook with the guard's native 422" do
      with_temp_doctype("moghook") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        script = <<-LUA
          local export = {}
          function export.create(ctx)
            document.create("#{child_dt}", { label = "stray" })
          end
          return export
        LUA
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}, "script": #{script.to_json}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        result = Facet::Document::Create.call(db, domain, doctype, %({"name": "P"}), Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.message.should contain("Document '#{child_dt}' belongs to '#{doctype}'")

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = $1 AND doc_type = $2",
          domain, child_dt, as: Int64)
        count.should eq(0)
      end
    end

    it "keeps the compound-create path working with parent linkage on children" do
      with_temp_doctype("mogcmp") do |db, domain, doctype|
        ensure_domain(db, domain)
        child_dt = "#{doctype}Kid"
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Child A"}]}})
        result = Facet::Document::CreateWithChildren.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::CreateWithChildren::Result)
        cwc = result.as(Facet::Document::CreateWithChildren::Result)
        child = cwc.children["items"].first

        row = db.query_one(
          "SELECT arguments->'meta'->>'parent_id' FROM mutations WHERE id = $1",
          child.mut_id,
          as: String?,
        )
        row.should eq(cwc.projection.id)
      end
    end

    it "keeps the sidecar flat-create path working (sidecars declare no member_of)" do
      with_temp_doctype("mogside") do |db, domain, doctype|
        ensure_domain(db, domain)
        parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        host = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Host"}), Facet::RBAC::AuthContext.system)).projection

        # A temp sidecar doctype: core domain, required read-only `target`
        # reference, no member_of (the composition of the seeded sidecars).
        # Authoring a doctype in the `core` domain needs the `core` domain
        # document — the per-example truncation wipes the seeded one.
        ensure_domain(db, "core")
        sidecar_dt = "Side#{unique_suffix(8)}"
        sidecar_defn = %({"doctype": "#{sidecar_dt}", "domain": "core", "sidecar": true, "surface": "note", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"target": {"type": "reference", "required": true, "read_only": true}, "body": {"type": "string"}}})
        expect_create_success(Facet::Document::Create.call(db, "core", "DocType", sidecar_defn, Facet::RBAC::AuthContext.system))

        # The SidecarHandler delegation shape: allow_system_writes (the route
        # owns the read-only `target`) and skip_authorization (the handler's
        # gates ran). The sidecar declares no member_of, so the owned-child
        # guard must not fire.
        result = Facet::Document::Create.call(
          db, "core", sidecar_dt,
          %({"target": "#{domain}.#{doctype}.#{host.id}", "body": "attached"}),
          Facet::RBAC::AuthContext.system,
          allow_system_writes: true, skip_authorization: true,
        )
        proj = expect_create_success(result).projection
        proj.content["target"].as_s.should eq("#{domain}.#{doctype}.#{host.id}")
      end
    end
  end
end
