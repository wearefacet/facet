# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/websocket/subscription_resolver"
require "../support/rbac_helper"

# AuthContext and Layer-1 enforcement.
#
# Verifies that an app-scoped `AuthContext` (a real role with an attached
# `EffectiveScope`) is correctly constrained at every document service and
# at the WebSocket subscription resolver — with no transport (OAuth, token
# issuance) involved. The `EffectiveScope` is the resolved intersection
# produced by `RBAC::GrantResolver.resolve`; this spec builds it the same
# way token issuance does.
#
# Coverage:
#   - Inside-the-grant operations succeed; outside-the-grant operations
#     produce denial (403 on read/create/update/delete/action, or an empty
#     result set on list — non-disclosing).
#   - Nested-child doctype path: a grant on `crm.Contact` permits reads on
#     `crm.Contact.Comment` (prefix match, mirroring `Grant#covers?`).
#   - Named action: `Document::Action.call` honours the grant on the
#     action's name.
#   - WebSocket subscription: `SubscriptionResolver.resolve_and_authorize`
#     inherits the read pre-check by virtue of going through
#     `ReadEnforcer.authorized?`.
#   - Fail-closed: a present-but-empty `EffectiveScope` denies every
#     operation.
#   - No regression: an `Authenticated` context with no app_grant is
#     permitted exactly as before.
#   - Structural negative test: a `System` principal cannot carry an app
#     grant (constructor invariant) — the only path that reaches a
#     document service bypassed is the system bypass, which has no grant.

# ── Spec helpers ────────────────────────────────────────────────────────────

# Builds an `AppScope` from a JSON grants literal, then resolves it against
# the supplied role. The returned `EffectiveScope` is the policy an
# app-scoped `AuthContext` will carry.
def effective_scope(grants_json : String, r : Facet::RBAC::ActiveRole, app_id : String = "app_01")
  content = JSON.parse(%({"grants": #{grants_json}}))
  app = Facet::RBAC::AppScope.from_content(app_id, content)
  Facet::RBAC::GrantResolver.resolve(app, r)
end

# Builds an app-scoped AuthContext.
def app_ctx(
  account_id : String,
  r : Facet::RBAC::ActiveRole,
  grant : Facet::RBAC::EffectiveScope,
  app_id : String = "app_01",
)
  Facet::RBAC::AuthContext.app_scoped(account_id, r, grant, app_id)
end

# Creates a fresh doctype + a document so the read/update/delete/action
# paths have something to operate on.
# Creates a doctype + one row so tests have a target document.
def make_doc(
  db,
  domain : String,
  doctype : String,
  content = %({"name": "test"}),
)
  # Register the domain if absent.
  Facet::Document::Create.call(
    db, "core", "Domain", %({"domain": "#{domain}"}), Facet::RBAC::AuthContext.system
  )
  # Register the doctype if absent.
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)

  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection
end

# Parent + member-of child pair (B-29 specs): `fieldops.WorkOrder` declares
# `work_logs → WorkLog`; `WorkLog` declares `member_of` back.
def make_parent_child_doctypes(db)
  Facet::Document::Create.call(
    db, "core", "Domain", %({"domain": "fieldops"}), Facet::RBAC::AuthContext.system,
  )
  parent_schema = %({
    "doctype": "WorkOrder", "domain": "fieldops",
    "fields": {"name": {"type": "string"}},
    "children": {"work_logs": {"doctype": "WorkLog", "collection": true}}
  })
  Facet::Document::Create.call(db, "core", "DocType", parent_schema, Facet::RBAC::AuthContext.system)
  child_schema = %({
    "doctype": "WorkLog", "domain": "fieldops",
    "fields": {"note": {"type": "string"}},
    "member_of": "WorkOrder"
  })
  Facet::Document::Create.call(db, "core", "DocType", child_schema, Facet::RBAC::AuthContext.system)
  order = Facet::Document::Create.call(db, "fieldops", "WorkOrder", %({"name": "WO-1"}), Facet::RBAC::AuthContext.system)
  order.as(Facet::Document::Create::Result).projection
end

describe "AuthContext app-grant enforcement" do
  # Apps are usually created via the document API; but the grant *policy*
  # tests construct it from JSON literals directly.
  # Re-seed meta doctypes so doctype creation in helper works.
  before_each do
    with_db { |db| seed_app_doctypes(db) }
  end

  describe "AuthContext constructor invariants" do
    it "permits a domain-wildcard grant resolved against a wildcard role" do
      # A `crm.*` grant collapsed with a `*.*` admin permission emits an
      # entry whose path is the wildcard — `app_grant_permits?` must treat
      # it as covering every doctype in the domain (mirrors
      # `Grant#covers?`).
      r = rbac_role([rbac_perm("*", "*.*")])
      grant = effective_scope(
        %([{"target": "crm.*", "actions": [{"name": "read", "required": true}]}]),
        r,
      )
      ctx = app_ctx("svc_01", r, grant)
      ctx.app_grant_permits?("read", "crm", ["Contact"]).should be_true
      ctx.app_grant_permits?("read", "iam", ["Account"]).should be_false
    end

    it "permits a Real principal without an app_grant (normal request)" do
      r = rbac_role([rbac_perm("read", "crm.Contact")])
      ctx = Facet::RBAC::AuthContext.authenticated("alice", r)
      ctx.app_grant.should be_nil
      # app_grant_permits? short-circuits to true on nil grant.
      ctx.app_grant_permits?("read", "crm", ["Contact"]).should be_true
    end

    it "rejects a System principal with an app_grant (constructor guard)" do
      r = rbac_role([] of Facet::RBAC::Permission)
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
        r,
      )
      # The guard is on the private constructor. `app_scoped` rejects
      # `system`/`anonymous` at the reserved-name check first, and its
      # app_id/app_grant pairing is guaranteed by construction, so the only
      # way to hit the System guard is a direct `new` with a System principal
      # and an app_grant + matching app_id.
      expect_raises(ArgumentError, /system principal cannot carry an app grant/) do
        Facet::RBAC::AuthContext.new(Facet::RBAC::Principal::System.new("system"), grant, "app_01")
      end
    end

    it "rejects reserved account_id in app_scoped factory" do
      r = rbac_role([] of Facet::RBAC::Permission)
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
        r,
      )
      expect_raises(ArgumentError, /reserved/) do
        Facet::RBAC::AuthContext.app_scoped("anonymous", r, grant, "app_01")
      end
    end
  end

  describe "app_grant_permits? pure logic" do
    it "denies everything when the EffectiveScope is present but empty" do
      r = rbac_role([] of Facet::RBAC::Permission)
      # A grant on a domain the role has no permission on results in an
      # empty EffectiveScope — the fail-closed shape.
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": false}]}]),
        r,
      )
      grant.empty?.should be_true

      ctx = app_ctx("alice", r, grant)
      ctx.app_grant_permits?("read", "crm", ["Contact"]).should be_false
      ctx.app_grant_permits?("create", "crm", ["Contact"]).should be_false
    end

    it "matches an exact (domain, doctype, action)" do
      r = rbac_role([rbac_perm("read", "crm.Contact")])
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
        r,
      )
      ctx = app_ctx("alice", r, grant)
      ctx.app_grant_permits?("read", "crm", ["Contact"]).should be_true
      ctx.app_grant_permits?("read", "crm", ["Other"]).should be_false
      ctx.app_grant_permits?("create", "crm", ["Contact"]).should be_false
    end

    it "permits descendant doctype paths (prefix match, mirrors Grant#covers?)" do
      # A grant on `crm.Contact` covers a role permission on
      # `crm.Contact.Comment` (grant collapse), so the EffectiveScope
      # entry's domain/path are `crm`/`Comment`. But the prefix match in
      # app_grant_permits? is on the *query* path against the entry's
      # concrete path. Here we test the inverse — a grant that resolved
      # to `[Contact]` must permit a query for `[Contact, Comment]`.
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
        rbac_role([rbac_perm("read", "crm.Contact")]), # role on Contact → entry path=[Contact]
      )
      ctx = app_ctx("alice", rbac_role([rbac_perm("read", "crm.Contact")]), grant)
      # Descendant query is permitted.
      ctx.app_grant_permits?("read", "crm", ["Contact", "Comment"]).should be_true
      # Sibling doctype is not.
      ctx.app_grant_permits?("read", "crm", ["Other"]).should be_false
      # Different domain is not.
      ctx.app_grant_permits?("read", "hr", ["Contact"]).should be_false
    end

    it "expands write to create+update in the EffectiveScope (Phase 2 carry-through)" do
      r = rbac_role([rbac_perm("create", "crm.Contact"), rbac_perm("update", "crm.Contact")])
      grant = effective_scope(
        %([{"target": "crm.Contact", "actions": [{"name": "write", "required": true}]}]),
        r,
      )
      ctx = app_ctx("alice", r, grant)
      ctx.app_grant_permits?("create", "crm", ["Contact"]).should be_true
      ctx.app_grant_permits?("update", "crm", ["Contact"]).should be_true
      # `delete` is NOT covered by the `write` alias.
      ctx.app_grant_permits?("delete", "crm", ["Contact"]).should be_false
    end
  end

  describe "service-layer integration" do
    it "denies reads outside the grant and permits inside it" do
      with_db do |db|
        # Role can read anywhere; grant narrows to crm.Contact only.
        r = rbac_role([rbac_perm("read", "*.*")])
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        # Create test docs as system (the docs themselves).
        crm_contact = make_doc(db, "crm", "Contact", %({"name": "alice@x.com"}))
        hr_employee = make_doc(db, "hr", "Employee", %({"name": "Bob"}))

        # Inside the grant: read succeeds.
        in_result = Facet::Document::Read.call(db, "crm", "Contact", crm_contact.id, ctx)
        in_result.should be_a(Facet::Document::Read::Result)

        # Outside the grant: the ceiling denies the read class — 403, the
        # same answer the write side gives for the same gate state.
        out_result = Facet::Document::Read.call(db, "hr", "Employee", hr_employee.id, ctx)
        out_result.should be_a(Facet::ServiceError)
        out_result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "denies writes outside the grant, permits writes inside it (create path)" do
      with_db do |db|
        # Role is wildcard-admin; grant narrows to crm.Contact create only.
        r = rbac_role([rbac_perm("create", "*.*")])
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "create", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        # Need the doctype to exist for create to reach the enforcer (the
        # enforcer runs after doctype lookup but before the INSERT).
        make_doc(db, "crm", "Contact", %({"name": "seed1"}))
        make_doc(db, "hr", "Employee", %({"name": "seed2"}))

        # Inside: create succeeds.
        in_result = Facet::Document::Create.call(
          db, "crm", "Contact", %({"name": "new1"}), ctx,
        )
        in_result.should be_a(Facet::Document::Create::Result)

        # Outside: create denied with a 403.
        out_result = Facet::Document::Create.call(
          db, "hr", "Employee", %({"name": "new2"}), ctx,
        )
        out_result.should be_a(Facet::ServiceError)
        out_result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "denies update/delete outside the grant" do
      with_db do |db|
        r = rbac_role([rbac_perm("update", "*.*"), rbac_perm("delete", "*.*")])
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "update", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        crm_doc = make_doc(db, "crm", "Contact", %({"name": "a"}))
        hr_doc = make_doc(db, "hr", "Employee", %({"name": "b"}))

        # Inside: update succeeds.
        upd_in = Facet::Document::Update.call(
          db, "crm", "Contact", crm_doc.id, %({"name": "a2"}), ctx,
        )
        upd_in.should be_a(Facet::Document::Update::Result)

        # Outside: update denied (403).
        upd_out = Facet::Document::Update.call(
          db, "hr", "Employee", hr_doc.id, %({"name": "b2"}), ctx,
        )
        upd_out.should be_a(Facet::ServiceError)
        upd_out.as(Facet::ServiceError).status.should eq(403)

        # Outside: delete denied (403) — and `delete` is NOT in the grant,
        # so even the inside-the-grant mutation is denied.
        del_out = Facet::Document::Delete.call(db, "hr", "Employee", hr_doc.id, ctx)
        del_out.should be_a(Facet::ServiceError)
        del_out.as(Facet::ServiceError).status.should eq(403)

        del_in = Facet::Document::Delete.call(db, "crm", "Contact", crm_doc.id, ctx)
        del_in.should be_a(Facet::ServiceError)
        del_in.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "denies list outside the grant with a 403" do
      with_db do |db|
        r = rbac_role([rbac_perm("read", "*.*")])
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        # Seed rows in both doctypes.
        make_doc(db, "crm", "Contact", %({"name": "c1"}))
        make_doc(db, "hr", "Employee", %({"name": "e1"}))

        # Inside: list returns items.
        in_list = Facet::Document::List.call(db, "crm", "Contact", auth_context: ctx)
        in_list.should be_a(Facet::Document::List::Result)
        in_list.as(Facet::Document::List::Result).items.size.should eq(1)

        # Outside: the ceiling denies the read class — 403, matching the
        # write side, so the integrator learns the grant is misconfigured
        # instead of mistaking the denial for an empty database.
        out_list = Facet::Document::List.call(db, "hr", "Employee", auth_context: ctx)
        out_list.should be_a(Facet::ServiceError)
        out_list.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "permits reads on a descendant doctype when the grant covers the parent" do
      with_db do |db|
        # Role can read crm.Contact.Comment; grant covers crm.Contact (parent).
        r = rbac_role([rbac_perm("read", "crm.Contact.Comment")])
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
          # Use a role that covers crm.Contact so the EffectiveScope entry
          # resolves with domain=crm, path=[Contact].
          rbac_role([rbac_perm("read", "crm.Contact")]),
        )
        ctx = app_ctx("alice", r, grant)

        # A query for `crm.Contact.Comment` — the descendant — must be
        # permitted because the grant entry path `[Contact]` is a prefix
        # of the query path `[Contact, Comment]`.
        ctx.app_grant_permits?("read", "crm", ["Contact", "Comment"]).should be_true

        # Service layer: parent_authorized? is the gate used by nested
        # child routes. A standalone read on the descendant doctype
        # goes through with_scoped which runs the pre-check first.
        # Construct the child doctype + a row, then verify the read
        # enforcer permits it (it will deny because the role has no
        # permission on the Comment doctype — but the *pre-check* passes,
        # which is what this spec asserts). The right shape is:
        # `app_grant_permits? == true` AND `can? == Denied` ⇒ 404.
        make_doc(db, "crm", "Contact", %({"name": "parent"}))
        # Just verify the pure pre-check passed for the descendant path:
        ctx.app_grant_permits?("read", "crm", ["Contact", "Comment"]).should be_true
      end
    end

    it "denies a named action outside the grant, permits inside" do
      with_db do |db|
        # Doctype with a named action `promote` and a Lua script that
        # defines `export.promote`. Without the script, the action
        # returns a 500 "No script defined" failure — the script is
        # required for the action to execute past the enforcer.
        Facet::Document::Create.call(
          db, "core", "Domain", %({"domain": "hr"}), Facet::RBAC::AuthContext.system,
        )
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.promote(ctx, args) end
          return export
        LUA
        schema = %({
          "doctype": "Employee", "domain": "hr",
          "fields": {"name": {"type": "string"}},
          "actions": {"promote": {"args": {}}},
          "script": #{script.to_json}
        })
        Facet::Document::Create.call(
          db, "core", "DocType", schema, Facet::RBAC::AuthContext.system,
        )
        emp = Facet::Document::Create.call(
          db, "hr", "Employee", %({"name": "Carol"}), Facet::RBAC::AuthContext.system,
        )
        emp.should be_a(Facet::Document::Create::Result)
        emp_id = emp.as(Facet::Document::Create::Result).projection.id

        # Role: wildcard action on hr.Employee covers `promote`.
        r = rbac_role([rbac_perm("promote", "hr.Employee")])
        # Grant narrow — `promote` is an optional action, no required
        # action present, so the role is usable.
        grant = effective_scope(
          %([{"target": "hr.Employee", "actions": [{"name": "promote", "required": false}]}]),
          r,
        )

        # Inside: action succeeds.
        ctx_in = app_ctx("alice", r, grant)
        act_in = Facet::Document::Action.call(db, "hr", "Employee", emp_id, "promote", "{}", ctx_in)
        act_in.should be_a(Facet::Document::Action::Result)

        # Outside: action on a doctype not in the grant.
        grant_out = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
          rbac_role([rbac_perm("read", "crm.Contact")]),
        )
        ctx_out = app_ctx("alice", rbac_role([rbac_perm("promote", "hr.Employee")]), grant_out)
        act_out = Facet::Document::Action.call(db, "hr", "Employee", emp_id, "promote", "{}", ctx_out)
        act_out.should be_a(Facet::ServiceError)
        act_out.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "fail-closed: a present-but-empty EffectiveScope denies everything" do
      with_db do |db|
        r = rbac_role([] of Facet::RBAC::Permission)
        grant = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": false}]}]),
          r,
        )
        grant.empty?.should be_true

        ctx = app_ctx("alice", r, grant)
        crm_doc = make_doc(db, "crm", "Contact", %({"name": "x"}))

        # Read denied as 403 (class-level denial, matching the write side).
        read = Facet::Document::Read.call(db, "crm", "Contact", crm_doc.id, ctx)
        read.should be_a(Facet::ServiceError)
        read.as(Facet::ServiceError).status.should eq(403)

        # List denied with 403 for the same reason.
        list = Facet::Document::List.call(db, "crm", "Contact", auth_context: ctx)
        list.should be_a(Facet::ServiceError)
        list.as(Facet::ServiceError).status.should eq(403)

        # Create/update/delete denied with 403.
        crt = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "y"}), ctx)
        crt.should be_a(Facet::ServiceError)
        crt.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "no regression: AuthContext.authenticated (no app_grant) behaves as before" do
      with_db do |db|
        # A normal authenticated context, no app grant.
        r = rbac_role([rbac_perm("read", "crm.Contact")])
        ctx = Facet::RBAC::AuthContext.authenticated("alice", r)
        ctx.app_grant.should be_nil

        crm_doc = make_doc(db, "crm", "Contact", %({"name": "alice"}))
        # Read is granted by the role — succeeds.
        read = Facet::Document::Read.call(db, "crm", "Contact", crm_doc.id, ctx)
        read.should be_a(Facet::Document::Read::Result)

        # Read on hr.Employee — role has no permission (no grant either),
        # so it is a class-level denial: 403 like any doctype the role
        # cannot read at all.
        make_doc(db, "hr", "Employee", %({"name": "B"}))
        hr_doc = Facet::Document::Read.call(
          db, "hr", "Employee",
          Facet::Document::List.call(db, "hr", "Employee").as(Facet::Document::List::Result).items.first.id,
          ctx,
        )
        hr_doc.should be_a(Facet::ServiceError)
        hr_doc.as(Facet::ServiceError).status.should eq(403)
      end
    end
  end

  # ── Nested child routes authorize on the composition path (B-29) ────
  #
  # The nested REST routes create children through `Document::Create.call`
  # with `authorize_path: [parent, child]`. The gate checks that path for
  # BOTH the Layer-1 grant ceiling and the role permission — so a parent
  # grant covers the nested create (prefix match), and a bare-child grant
  # does NOT (it serves the flat route, which member-of children lack).
  # This is the same two-gate shape `authorize_sidecar_create` applies.
  describe "nested child create authorizes on the composition path" do
    it "accepts a grant and a permission on the parent doctype (the documented coverage rule)" do
      with_db do |db|
        order = make_parent_child_doctypes(db)
        r = rbac_role([rbac_perm("create", "fieldops.WorkOrder")])
        grant = effective_scope(
          %([{"target": "fieldops.WorkOrder", "actions": [{"name": "create", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        result = Facet::Document::Create.call(db, "fieldops", "WorkLog",
          %({"note": "started"}), ctx,
          meta_overrides: {"parent_id" => JSON::Any.new(order.id)},
          authorize_path: ["WorkOrder", "WorkLog"],
        )
        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "accepts a grant and a permission on the full composition path" do
      with_db do |db|
        order = make_parent_child_doctypes(db)
        r = rbac_role([rbac_perm("create", "fieldops.WorkOrder.WorkLog")])
        grant = effective_scope(
          %([{"target": "fieldops.WorkOrder.WorkLog", "actions": [{"name": "create", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        result = Facet::Document::Create.call(db, "fieldops", "WorkLog",
          %({"note": "started"}), ctx,
          meta_overrides: {"parent_id" => JSON::Any.new(order.id)},
          authorize_path: ["WorkOrder", "WorkLog"],
        )
        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "refuses a bare-child grant and permission — the flat rule does not reach the nested route" do
      with_db do |db|
        order = make_parent_child_doctypes(db)
        # The probe shape that used to be the ONLY working one: a grant and
        # a permission on the bare child doctype. Under the composition-path
        # rule the nested route refuses it (the flat route — absent for
        # member_of children — is where the bare path applies).
        r = rbac_role([rbac_perm("create", "fieldops.WorkLog")])
        grant = effective_scope(
          %([{"target": "fieldops.WorkLog", "actions": [{"name": "create", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        result = Facet::Document::Create.call(db, "fieldops", "WorkLog",
          %({"note": "started"}), ctx,
          meta_overrides: {"parent_id" => JSON::Any.new(order.id)},
          authorize_path: ["WorkOrder", "WorkLog"],
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "refuses a domain-wildcard grant whose action the role does not hold" do
      with_db do |db|
        order = make_parent_child_doctypes(db)
        r = rbac_role([rbac_perm("read", "fieldops.WorkOrder")])
        grant = effective_scope(
          %([{"target": "fieldops.*", "actions": [{"name": "read", "required": true}]}]),
          r,
        )
        ctx = app_ctx("alice", r, grant)

        result = Facet::Document::Create.call(db, "fieldops", "WorkLog",
          %({"note": "started"}), ctx,
          meta_overrides: {"parent_id" => JSON::Any.new(order.id)},
          authorize_path: ["WorkOrder", "WorkLog"],
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "the flat create of the same child keeps the bare-path gate (two rules, one resource)" do
      with_db do |db|
        make_parent_child_doctypes(db)
        # The member_of flat-create guard fires before RBAC — the flat route
        # exists for NON-member children; this asserts the 422 guard, i.e.
        # the flat route is genuinely a different surface.
        r = rbac_role([rbac_perm("create", "fieldops.WorkLog")])
        ctx = Facet::RBAC::AuthContext.authenticated("alice", r)

        result = Facet::Document::Create.call(db, "fieldops", "WorkLog", %({"note": "x"}), ctx)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
        result.as(Facet::ServiceError).message.should contain("nested route")
      end
    end
  end

  describe "WebSocket subscription resolver inherits enforcement" do
    it "permits a subscription inside the grant, denies outside (403)" do
      with_db do |db|
        # Re-register the hr domain + Employee doctype + seed row.
        Facet::Document::Create.call(
          db, "core", "Domain", %({"domain": "hr"}), Facet::RBAC::AuthContext.system,
        )
        schema = %({"doctype": "Employee", "domain": "hr", "fields": {"name": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
        emp = Facet::Document::Create.call(
          db, "hr", "Employee", %({"name": "Dan"}), Facet::RBAC::AuthContext.system,
        )
        emp_id = emp.as(Facet::Document::Create::Result).projection.id

        # Role: read on hr.Employee; grant narrows to hr.Employee.
        r = rbac_role([rbac_perm("read", "hr.Employee")])
        grant = effective_scope(
          %([{"target": "hr.Employee", "actions": [{"name": "read", "required": true}]}]),
          r,
        )
        ctx_in = app_ctx("alice", r, grant)

        # Inside the grant: subscription resolves.
        res_in = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/#{emp_id}", ctx_in,
        )
        res_in.should be_a(Facet::Websocket::SubscriptionResolver::Resolved)

        # Outside: grant on crm.Contact only.
        grant_out = effective_scope(
          %([{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}]),
          rbac_role([rbac_perm("read", "crm.Contact")]),
        )
        ctx_out = app_ctx("alice", rbac_role([rbac_perm("read", "hr.Employee")]), grant_out)
        res_out = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/#{emp_id}", ctx_out,
        )
        res_out.should be_a(Facet::ServiceError)
        res_out.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "fail-closed: app-scoped identity with empty EffectiveScope is denied" do
      with_db do |db|
        Facet::Document::Create.call(
          db, "core", "Domain", %({"domain": "hr"}), Facet::RBAC::AuthContext.system,
        )
        schema = %({"doctype": "Employee", "domain": "hr", "fields": {"name": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
        emp = Facet::Document::Create.call(
          db, "hr", "Employee", %({"name": "Eve"}), Facet::RBAC::AuthContext.system,
        )
        emp_id = emp.as(Facet::Document::Create::Result).projection.id

        r = rbac_role([] of Facet::RBAC::Permission)
        grant = effective_scope(
          %([{"target": "hr.Employee", "actions": [{"name": "read", "required": false}]}]),
          r,
        )
        grant.empty?.should be_true
        ctx = app_ctx("alice", r, grant)

        res = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/#{emp_id}", ctx,
        )
        res.should be_a(Facet::ServiceError)
        res.as(Facet::ServiceError).status.should eq(403)
      end
    end
  end
end
