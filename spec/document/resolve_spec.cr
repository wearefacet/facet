# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../support/doctype_helper"
require "../support/iam_helper"

# Document::Resolve — batch URN resolution to masked, authorized
# projections, keyed by the canonical URN string.
#
# Acceptance:
# - Happy path: N refs across one doctype resolve in one query, keyed by the
#   canonical URN string.
# - A denied scope omits the target (non-disclosing).
# - A tombstone omits the target.
# - A masked field is absent from the returned content.
describe Facet::Document::Resolve do
  it "resolves a batch of refs to masked projections keyed by URN" do
    with_db do |db|
      ensure_domain(db, "mcpresolve")
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Gadget", "domain": "mcpresolve", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {"title": {"type": "string", "required": true}}
      }), Facet::RBAC::AuthContext.system)

      a = Facet::Document::Create.call(db, "mcpresolve", "Gadget", %({"title": "A"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      b = Facet::Document::Create.call(db, "mcpresolve", "Gadget", %({"title": "B"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

      result = Facet::Document::Resolve.call(
        db,
        [
          Facet::Document::DocURI.from_projection_id("mcpresolve", "Gadget", a.id).to_s,
          Facet::Document::DocURI.from_projection_id("mcpresolve", "Gadget", b.id).to_s,
          "urn:facet:mcpresolve:Gadget:01UNKNOWN000000000000000000",
        ],
        Facet::RBAC::AuthContext.system,
      )
      result.size.should eq(2)
      result[Facet::Document::DocURI.from_projection_id("mcpresolve", "Gadget", a.id).to_s].content["title"].as_s.should eq("A")
      result[Facet::Document::DocURI.from_projection_id("mcpresolve", "Gadget", b.id).to_s].content["title"].as_s.should eq("B")
    end
  end

  it "omits a target outside the caller's scope (non-disclosing)" do
    with_db do |db|
      fields = %({"title": {"type": "string", "required": true}, "owner": {"type": "reference", "doctype": "iam.Account"}})
      scopes = %({"mine": {"where": {"owner": "$self"}}})
      _domain, doctype = build_agg_doctype(db, "mcpresolve", fields, scopes)

      mine = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      other = create_test_account(db, email: "resolve-other@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      visible = Facet::Document::Create.call(db, "mcpresolve", doctype, %({"title": "mine", "owner": "iam.Account.#{mine}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      hidden = Facet::Document::Create.call(db, "mcpresolve", doctype, %({"title": "hidden", "owner": "iam.Account.#{other}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

      role = Facet::RBAC::ActiveRole.new(
        role_id: "mcpresolve.viewer",
        visible_tags: Set.new(["default"]),
        permissions: [Facet::RBAC::Permission.new(action: "read", domain: "mcpresolve", path: [doctype], scope: "$mine")],
      )
      ctx = Facet::RBAC::AuthContext.authenticated(mine, role)

      result = Facet::Document::Resolve.call(db, [
        Facet::Document::DocURI.from_projection_id("mcpresolve", doctype, visible.id).to_s,
        Facet::Document::DocURI.from_projection_id("mcpresolve", doctype, hidden.id).to_s,
      ], ctx)
      result.size.should eq(1)
      result[Facet::Document::DocURI.from_projection_id("mcpresolve", doctype, visible.id).to_s].content["title"].as_s.should eq("mine")
      result.has_key?(Facet::Document::DocURI.from_projection_id("mcpresolve", doctype, hidden.id).to_s).should be_false
    end
  end

  it "omits a tombstoned target" do
    with_db do |db|
      ensure_domain(db, "mcpresolve")
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Thing", "domain": "mcpresolve", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {"title": {"type": "string", "required": true}}
      }), Facet::RBAC::AuthContext.system)

      keep = Facet::Document::Create.call(db, "mcpresolve", "Thing", %({"title": "keep"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      gone = Facet::Document::Create.call(db, "mcpresolve", "Thing", %({"title": "gone"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Delete.call(db, "mcpresolve", "Thing", gone.id, Facet::RBAC::AuthContext.system)

      result = Facet::Document::Resolve.call(db, [
        Facet::Document::DocURI.from_projection_id("mcpresolve", "Thing", keep.id).to_s,
        Facet::Document::DocURI.from_projection_id("mcpresolve", "Thing", gone.id).to_s,
      ], Facet::RBAC::AuthContext.system)
      result.size.should eq(1)
      result.has_key?(Facet::Document::DocURI.from_projection_id("mcpresolve", "Thing", gone.id).to_s).should be_false
    end
  end

  it "masks a view-tagged field out of the returned content" do
    with_db do |db|
      ensure_domain(db, "mcpresolve")
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Record", "domain": "mcpresolve", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "title": {"type": "string", "required": true},
          "salary": {"type": "integer", "tags": ["payroll"]}
        }
      }), Facet::RBAC::AuthContext.system)

      doc = Facet::Document::Create.call(db, "mcpresolve", "Record", %({"title": "R1", "salary": 100}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

      # A role whose visible_tags do not include `payroll` — the field is
      # masked on every read surface, resolve included.
      role = Facet::RBAC::ActiveRole.new(
        role_id: "mcpresolve.basic",
        visible_tags: Set.new(["default"]),
        permissions: [Facet::RBAC::Permission.new(action: "read", domain: "mcpresolve", path: ["Record"])],
      )
      ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

      result = Facet::Document::Resolve.call(db, [Facet::Document::DocURI.from_projection_id("mcpresolve", "Record", doc.id).to_s], ctx)
      proj = result[Facet::Document::DocURI.from_projection_id("mcpresolve", "Record", doc.id).to_s]
      proj.content["title"].as_s.should eq("R1")
      proj.content.as_h.has_key?("salary").should be_false
    end
  end

  it "returns an empty hash for unparseable refs" do
    with_db do |db|
      result = Facet::Document::Resolve.call(db, ["not a urn", ""], Facet::RBAC::AuthContext.system)
      result.should be_empty
    end
  end
end
