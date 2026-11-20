# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the draft-target gate on the doctype authoring path (B-287):
# a cross-domain reference whose target domain is still a draft is
# rejected with 422 by both `Doctype::Create` and `Doctype::Update`.
# Same-domain references stay legal everywhere; cross-domain references
# to a live domain stay legal.

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# ── Helpers (file-owned, private) ────────────────────────────────────────

# Seeds a draft domain row directly (`draft: true`, `_<12-char ulid>` id) —
# the same shape `Domain::Draft.create` produces. Written via the mutation
# client so this file does not need the `src/domain` require tree.
private def seed_draft_gate_domain(db) : String
  draft = "_#{unique_suffix(12)}"
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: draft,
    content: %({"draft": true}),
    actioner_id: "system:test",
  )
  draft
end

# Builds a core.DocType create body with caller-chosen fields.
private def draft_gate_body(domain : String, doctype : String, fields : String) : String
  %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": #{fields}})
end

# Asserts the call failed with the draft-target 422: the error names the
# offending field, the draft target doctype, and carries the stable tags.
private def expect_draft_gate_rejected(
  result : Facet::Doctype::Create::Result | Facet::Doctype::Update::Result | Facet::ServiceError,
  field : String,
  target : String,
) : Nil
  case result
  in Facet::ServiceError
    result.status.should eq(422)
    result.message.should contain("draft domain")
    details = result.details
    details.should_not be_nil
    entries = details.not_nil!.select { |e| e.field == field }
    entries.size.should eq(1)
    entries[0].message.should contain(target)
    entries[0].code.should eq("schema")
    entries[0].params.try(&.["value"]).should eq(target)
  in Facet::Doctype::Create::Result
    fail "Expected 422 (draft target '#{target}') but the create succeeded"
  in Facet::Doctype::Update::Result
    fail "Expected 422 (draft target '#{target}') but the update succeeded"
  end
end

# Asserts a doctype create succeeded.
private def expect_draft_gate_create_ok(result : Facet::Doctype::Create::Result | Facet::ServiceError) : Nil
  case result
  in Facet::Doctype::Create::Result
    nil
  in Facet::ServiceError
    fail "Expected success, got #{result.status}: #{result.message} (#{result.details.try(&.to_json)})"
  end
end

# Asserts a doctype update succeeded.
private def expect_draft_gate_update_ok(result : Facet::Doctype::Update::Result | Facet::ServiceError) : Nil
  case result
  in Facet::Doctype::Update::Result
    nil
  in Facet::ServiceError
    fail "Expected success, got #{result.status}: #{result.message} (#{result.details.try(&.to_json)})"
  end
end

describe "Doctype::Create draft-target gate (B-287)" do
  it "rejects a live-domain doctype whose cross-domain reference targets a draft domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      draft = seed_draft_gate_domain(db)
      fields = %({"company": {"type": "reference", "doctype": "#{draft}.Payroll"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "company", "#{draft}.Payroll")
    end
  end

  it "allows a cross-domain reference to a live domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      target_domain = "live#{unique_suffix}"
      ensure_domain(db, target_domain)
      fields = %({"company": {"type": "reference", "doctype": "#{target_domain}.Company"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(result)
    end
  end

  it "allows a collection reference to a live domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      target_domain = "live#{unique_suffix}"
      ensure_domain(db, target_domain)
      fields = %({"companies": {"type": "reference", "collection": true, "doctype": "#{target_domain}.Company"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(result)
    end
  end

  it "rejects a bare reference target inside a draft domain too (the schema gate runs first)" do
    with_db do |db|
      draft = seed_draft_gate_domain(db)
      dt = "T#{unique_suffix}"
      fields = %({"sibling": {"type": "reference", "doctype": "Sibling#{unique_suffix}"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(draft, dt, fields), Facet::RBAC::AuthContext.system)

      # The schema gate (ReferenceType#validate_definition, F02-01)
      # refuses the bare target before the draft-target gate runs; a
      # draft-qualified target is the legal same-domain spelling (the
      # next example).
      case result
      in Facet::ServiceError
        result.status.should eq(422)
        result.message.should contain("Doctype validation failed")
        result.details.not_nil!.any?(&.message.includes?("bare reference target")).should be_true
      in Facet::Doctype::Create::Result
        fail "Expected 422 (bare reference target) but the create succeeded"
      end
    end
  end

  it "allows a same-domain reference inside a draft domain (draft-qualified target)" do
    with_db do |db|
      draft = seed_draft_gate_domain(db)
      dt = "T#{unique_suffix}"
      fields = %({"sibling": {"type": "reference", "doctype": "#{draft}.Sibling"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(draft, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(result)
    end
  end

  it "allows a draft-domain doctype to reference a live domain" do
    with_db do |db|
      draft = seed_draft_gate_domain(db)
      target_domain = "live#{unique_suffix}"
      ensure_domain(db, target_domain)
      dt = "T#{unique_suffix}"
      fields = %({"company": {"type": "reference", "doctype": "#{target_domain}.Company"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(draft, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(result)
    end
  end

  it "rejects a draft-domain doctype whose cross-domain reference targets another draft domain" do
    with_db do |db|
      draft_a = seed_draft_gate_domain(db)
      draft_b = seed_draft_gate_domain(db)
      dt = "T#{unique_suffix}"
      fields = %({"payroll": {"type": "reference", "doctype": "#{draft_b}.Payroll"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(draft_a, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "payroll", "#{draft_b}.Payroll")
    end
  end

  it "rejects a collection reference whose target domain is a draft" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      draft = seed_draft_gate_domain(db)
      fields = %({"payrolls": {"type": "reference", "collection": true, "doctype": "#{draft}.Payroll"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "payrolls", "#{draft}.Payroll")
    end
  end

  it "rejects an array-of-reference whose items target a draft domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      draft = seed_draft_gate_domain(db)
      fields = %({"payrolls": {"type": "array", "items": {"type": "reference", "doctype": "#{draft}.Payroll"}}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "payrolls.items", "#{draft}.Payroll")
    end
  end

  it "rejects reference fields nested in object properties and dictionary values" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      draft = seed_draft_gate_domain(db)
      fields = %({
        "meta": {"type": "object", "properties": {"owner": {"type": "reference", "doctype": "#{draft}.Payroll"}}},
        "ext": {"type": "dictionary", "values": {"type": "reference", "doctype": "#{draft}.Audit"}}
      })
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "meta.owner", "#{draft}.Payroll")
      expect_draft_gate_rejected(result, "ext.values", "#{draft}.Audit")
    end
  end

  it "rejects a _-prefixed target when no domain row exists (name-prefix fallback)" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      missing_draft = "_#{unique_suffix(12)}"
      fields = %({"company": {"type": "reference", "doctype": "#{missing_draft}.Payroll"}})
      result = Facet::Doctype::Create.call(db, "core", "DocType", draft_gate_body(domain, dt, fields), Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "company", "#{missing_draft}.Payroll")
    end
  end
end

describe "Doctype::Update draft-target gate (B-287)" do
  it "rejects an update that adds a cross-domain reference to a draft domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      v1 = draft_gate_body(domain, dt, %({"title": {"type": "string", "required": true}}))
      created = Facet::Doctype::Create.call(db, "core", "DocType", v1, Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(created)

      draft = seed_draft_gate_domain(db)
      v1_edit = draft_gate_body(domain, dt, %({"title": {"type": "string", "required": true}, "company": {"type": "reference", "doctype": "#{draft}.Payroll"}}))
      result = Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v1_edit, Facet::RBAC::AuthContext.system)
      expect_draft_gate_rejected(result, "company", "#{draft}.Payroll")
    end
  end

  it "allows an update that adds a cross-domain reference to a live domain" do
    with_temp_doctype do |db, domain, dt|
      ensure_domain(db, domain)
      v1 = draft_gate_body(domain, dt, %({"title": {"type": "string", "required": true}}))
      created = Facet::Doctype::Create.call(db, "core", "DocType", v1, Facet::RBAC::AuthContext.system)
      expect_draft_gate_create_ok(created)

      target_domain = "live#{unique_suffix}"
      ensure_domain(db, target_domain)
      v1_edit = draft_gate_body(domain, dt, %({"title": {"type": "string", "required": true}, "company": {"type": "reference", "doctype": "#{target_domain}.Company"}}))
      result = Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v1_edit, Facet::RBAC::AuthContext.system)
      expect_draft_gate_update_ok(result)
    end
  end
end
