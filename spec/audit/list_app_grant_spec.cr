# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# The global audit list under an app-scoped identity (F07-A).
#
# The global mode (`doc_id` absent) is a cross-domain forensics view. An
# app grant always names one concrete domain — `Grant.from_json` rejects
# the `*.*` target — so no grant can cover it. The Layer-1 ceiling denies
# every app-scoped identity before the role check, even when the elected
# role holds the wildcard read and the request narrows by a domain filter.
# Document history (`doc_id` present) keeps the per-doctype enforcement:
# inside the grant it answers rows. A full-access caller with no app
# grant still lists the global log.

# ── Spec helpers (file-scoped) ──────────────────────────────────────────────

# Builds the resolved grant ∩ role intersection the way token issuance
# does, from a JSON grants literal.
private def app_grant_scope(grants_json : String, r : Facet::RBAC::ActiveRole) : Facet::RBAC::EffectiveScope
  content = JSON.parse(%({"grants": #{grants_json}}))
  app = Facet::RBAC::AppScope.from_content("app_audit", content)
  Facet::RBAC::GrantResolver.resolve(app, r)
end

# Builds an app-scoped auth context: a real role plus the grant ceiling.
private def app_audit_ctx(r : Facet::RBAC::ActiveRole, grant : Facet::RBAC::EffectiveScope) : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.app_scoped("svc_app", r, grant, "app_audit")
end

# Registers the domain + doctype, then creates one document, so the
# global list has rows a leak would expose. Returns the document id.
private def seed_audit_target(db, domain : String, doctype : String, name : String) : String
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
  result = Facet::Document::Create.call(db, domain, doctype, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

# The bug shape: a wildcard-read role ceiling-limited by a narrow grant.
private def wildcard_read_ctx_with_narrow_grant : Facet::RBAC::AuthContext
  r = rbac_role([rbac_perm("read", "*.*")])
  grant = app_grant_scope(
    %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
    r,
  )
  app_audit_ctx(r, grant)
end

describe "Audit::List global mode under an app-scoped identity" do
  it "denies the global list before the role check (wildcard read, narrow grant)" do
    with_db do |db|
      seed_audit_target(db, "crm", "Contact", "alice")
      seed_audit_target(db, "hr", "Employee", "bob")

      ctx = wildcard_read_ctx_with_narrow_grant

      result = Facet::Audit::List.call(db, auth_context: ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies the global list even with a domain filter the grant covers" do
    with_db do |db|
      seed_audit_target(db, "crm", "Contact", "alice")

      ctx = wildcard_read_ctx_with_narrow_grant

      result = Facet::Audit::List.call(
        db, filters: {"domain__eq" => JSON::Any.new("crm")}, auth_context: ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "fail-closed: a present-but-empty grant denies the global list" do
    with_db do |db|
      seed_audit_target(db, "crm", "Contact", "alice")

      r = rbac_role([] of Facet::RBAC::Permission)
      grant = app_grant_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": false}]}]),
        r,
      )
      grant.empty?.should be_true
      ctx = app_audit_ctx(r, grant)

      result = Facet::Audit::List.call(db, auth_context: ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "keeps document history inside the grant open (per-doctype ceiling)" do
    with_db do |db|
      doc_id = seed_audit_target(db, "crm", "Contact", "alice")

      ctx = wildcard_read_ctx_with_narrow_grant

      result = Facet::Audit::List.call(db, domain: "crm", doc_type: "Contact", doc_id: doc_id, auth_context: ctx)
      result.should be_a(Facet::Audit::List::Result)
      result.as(Facet::Audit::List::Result).items.size.should be > 0
    end
  end

  it "no regression: a full-access authenticated caller lists the global log" do
    with_db do |db|
      seed_audit_target(db, "crm", "Contact", "alice")

      r = rbac_role([rbac_perm("read", "*.*")])
      ctx = Facet::RBAC::AuthContext.authenticated("alice_admin", r)

      result = Facet::Audit::List.call(db, auth_context: ctx)
      result.should be_a(Facet::Audit::List::Result)
      result.as(Facet::Audit::List::Result).items.size.should be > 0
    end
  end
end
