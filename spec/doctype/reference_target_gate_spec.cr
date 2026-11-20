# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the reference-target qualification gate (F02-01): a `reference`
# field must declare its target as the qualified `domain.Doctype` form.
# A bare target is refused at authoring time (422) on the create and update
# doors, on live and draft domains alike — `qualified_doctype` never expands
# a bare name, so normalize would prefix every submitted value with it and
# no value could pass the write-time check. Polymorphic references (no
# `doctype:` declared) stay legal.

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# ── Helpers (file-owned, private) ────────────────────────────────────────

# Builds a core.DocType create body with caller-chosen fields.
private def target_gate_body(domain : String, doctype : String, fields : String) : String
  %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": #{fields}})
end

# Asserts the authoring door refused the definition with the bare-target
# schema error: the error names the field, the bare target, and the
# qualified `{domain}.{Doctype}` remedy.
private def expect_bare_target_rejected(
  result : Facet::Doctype::Create::Result | Facet::Doctype::Update::Result | Facet::ServiceError,
  field : String,
  target : String,
) : Nil
  case result
  in Facet::ServiceError
    result.status.should eq(422)
    result.message.should contain("Doctype validation failed")
    details = result.details
    details.should_not be_nil
    entries = details.not_nil!.select { |e| e.field == field }
    entries.size.should eq(1)
    entries[0].code.should eq("schema")
    entries[0].message.should contain("bare reference target '#{target}'")
    entries[0].message.should contain("qualified '{domain}.{Doctype}'")
  in Facet::Doctype::Create::Result
    fail "Expected 422 (bare reference target '#{target}') but the create succeeded"
  in Facet::Doctype::Update::Result
    fail "Expected 422 (bare reference target '#{target}') but the update succeeded"
  end
end

# Asserts a doctype create succeeded.
private def expect_target_gate_create_ok(result : Facet::Doctype::Create::Result | Facet::ServiceError) : Nil
  case result
  in Facet::Doctype::Create::Result
    nil
  in Facet::ServiceError
    fail "Expected success, got #{result.status}: #{result.message} (#{result.details.try(&.to_json)})"
  end
end

# Asserts a doctype update succeeded.
private def expect_target_gate_update_ok(result : Facet::Doctype::Update::Result | Facet::ServiceError) : Nil
  case result
  in Facet::Doctype::Update::Result
    nil
  in Facet::ServiceError
    fail "Expected success, got #{result.status}: #{result.message} (#{result.details.try(&.to_json)})"
  end
end

module Facet::Doctype
  describe "reference-target qualification gate (F02-01)" do
    it "rejects a bare reference target on the create door (422)" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        fields = %({"brand": {"type": "reference", "doctype": "Brand"}})
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
        expect_bare_target_rejected(result, "brand", "Brand")

        # The authoring door refused it — nothing landed.
        db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = '#{domain}.#{dt}'",
          as: Int64
        ).should eq(0)
      end
    end

    it "rejects an implicit reference (doctype without type) with a bare target" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        fields = %({"brand": {"doctype": "Brand"}})
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
        expect_bare_target_rejected(result, "brand", "Brand")
      end
    end

    it "rejects a bare target nested in array items, object properties, and dictionary values" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        fields = %({
          "payrolls": {"type": "array", "items": {"type": "reference", "doctype": "Payroll"}},
          "meta":     {"type": "object", "properties": {"owner": {"type": "reference", "doctype": "Owner"}}},
          "ext":      {"type": "dictionary", "values": {"type": "reference", "doctype": "Extra"}}
        })
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)

        # All three violations land in one response — the walk collects
        # every error before the door answers.
        {"payrolls.items" => "Payroll", "meta.owner" => "Owner", "ext.values" => "Extra"}.each do |path, target|
          expect_bare_target_rejected(result, path, target)
        end
      end
    end

    it "accepts the qualified target form on the create door" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        fields = %({"brand": {"type": "reference", "doctype": "#{domain}.Brand"}})
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
        expect_target_gate_create_ok(result)
      end
    end

    it "accepts a polymorphic reference (no doctype declared)" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        fields = %({"target": {"type": "reference", "dangling": true}})
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
        expect_target_gate_create_ok(result)
      end
    end

    it "rejects a bare target on the update door (422) and accepts the qualified form" do
      with_temp_doctype do |db, domain, dt|
        ensure_domain(db, domain)
        qualified_id = "#{domain}.#{dt}"
        create = Facet::Doctype::Create.call(
          db, "core", "DocType",
          target_gate_body(domain, dt, %({"name": {"type": "string"}})),
          Facet::RBAC::AuthContext.system,
        )
        expect_target_gate_create_ok(create)

        # Same-version additive field addition — the version gates pass,
        # the bare target trips the schema gate.
        bare_body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}, "brand": {"type": "reference", "doctype": "Brand"}}})
        update = Facet::Doctype::Update.call(db, qualified_id, bare_body, Facet::RBAC::AuthContext.system)
        expect_bare_target_rejected(update, "brand", "Brand")

        # The qualified spelling of the same edit passes.
        qualified_body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}, "brand": {"type": "reference", "doctype": "#{domain}.Brand"}}})
        expect_target_gate_update_ok(Facet::Doctype::Update.call(db, qualified_id, qualified_body, Facet::RBAC::AuthContext.system))
      end
    end

    it "rejects a bare target inside a draft domain too (the schema gate runs in draft mode)" do
      with_db do |db|
        draft = "_#{unique_suffix(12)}"
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: draft,
          content: %({"draft": true}),
          actioner_id: "system:test",
        )
        dt = "T#{unique_suffix}"
        target = "Sibling#{unique_suffix}"
        fields = %({"sibling": {"type": "reference", "doctype": "#{target}"}})
        result = Facet::Doctype::Create.call(db, "core", "DocType", target_gate_body(draft, dt, fields), Facet::RBAC::AuthContext.system)
        expect_bare_target_rejected(result, "sibling", target)
      end
    end
  end
end
