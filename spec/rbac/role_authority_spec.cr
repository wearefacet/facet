# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/document/create"
require "../../src/document/update"
require "../../src/document/delete"

# RoleAuthority on CRUD (execution plan Phase 2): the elected active role is
# the caller authority on `iam.Account` and `iam.Roles` writes.

# Builds a Real auth context whose elected role carries the given level
# and permission lines (`"action|on"` strings).
private def authority_caller_ctx(level : Int32, perms : Array(String) = ["*|*.*"])
  lines = perms.map do |p|
    action, on = p.split("|", 2)
    %( {"action": "#{action}", "on": "#{on}"} )
  end
  role_content = %({"name": "caller_role", "level": #{level}, "visible_tags": ["default", "hr"], "connectivity": [], "permissions": [#{lines.join(", ")}]})
  role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
  Facet::RBAC::AuthContext.authenticated("caller-#{level}", role)
end

private def authority_seed_roles(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

private def authority_create(db, domain, doctype, body, ctx)
  Facet::Document::Create.call(db, domain, doctype, body, ctx)
end

private def authority_update(db, domain, doctype, doc_id, body, ctx)
  Facet::Document::Update.call(db, domain, doctype, doc_id, body, ctx)
end

private def authority_delete(db, domain, doctype, doc_id, ctx)
  Facet::Document::Delete.call(db, domain, doctype, doc_id, ctx)
end

private def authority_create_account(db, email, roles, ctx, default_role = nil)
  body = {
    "email"        => email,
    "name"         => "Test",
    "roles"        => roles,
    "default_role" => default_role || roles.first?,
  }.to_json
  authority_create(db, "iam", "Account", body, ctx)
end

# Builds a Real caller whose elected role is `role_id` itself, so the
# previous role content and the caller role are the same baseline — the
# shape that turned the assistant budget into a one-way ratchet (B-372).
# `budget` overrides the stored value, mirroring a role that already sits
# at the locked budget.
private def authority_self_locked_ctx(db, account_id, role_id, budget : Int64)
  content = Facet::IAM::RoleStore.fetch(db, role_id).not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(content)
  role = Facet::RBAC::ActiveRole.new(
    role_id: role.role_id, visible_tags: role.visible_tags,
    permissions: role.permissions, level: role.level,
    connectivity: role.connectivity, assistant_token_budget: budget,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "RBAC::RoleAuthority on CRUD" do
  # ── iam.Account writes ──────────────────────────────────────────────

  it "denies self-assign admin to a lower-level caller" do
    with_db do |db|
      authority_seed_roles(db)
      # `read iam.Roles` is the B-356 reference-check requirement: assigning
      # a role references the role row, so the caller must be able to read
      # it. The authority rule under test is about the assigned role's
      # level, not the reference lookup.
      ctx = authority_caller_ctx(30, ["create|*.*", "update|*.*", "read|iam.Roles"])
      account = authority_create_account(db, "self-assign@example.test", ["iam.Roles.editor"], ctx)
      account.should be_a(Facet::Document::Create::Result)
      account_id = account.as(Facet::Document::Create::Result).projection.id

      result = authority_update(db, "iam", "Account", account_id, %({"roles": ["iam.Roles.admin"]}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies minting a god role (permission widening + level)" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*", "update|*.*"])

      result = authority_create(db, "iam", "Roles",
        %({"name": "god_role", "level": 100, "permissions": [{"action": "*", "on": "*.*"}]}), ctx)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
    end
  end

  it "denies creating a standing admin account" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*", "update|*.*"])
      result = authority_create_account(db, "standing-admin@example.test", ["iam.Roles.admin"], ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies patching iam.Roles.admin.level from 100 to 30 (target protection first)" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      result = authority_update(db, "iam", "Roles", "iam.Roles.admin", %({"level": 30}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies updating or deleting a higher-level role, including a narrowing-only patch" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*", "delete|*.*"])

      narrowing = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"description": "narrower description only"}), ctx)
      narrowing.should be_a(Facet::ServiceError)
      narrowing.as(Facet::ServiceError).status.should eq(403)

      deleted = authority_delete(db, "iam", "Roles", "iam.Roles.admin", ctx)
      deleted.should be_a(Facet::ServiceError)
      deleted.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies update, suspend, and delete of a higher-ceiling account" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*", "delete|*.*"])
      # The higher-ceiling account exists (created by System).
      admin_ctx = Facet::RBAC::AuthContext.system
      target = authority_create_account(db, "high@example.test", ["iam.Roles.admin"], admin_ctx)
      target_id = target.as(Facet::Document::Create::Result).projection.id

      suspend = authority_update(db, "iam", "Account", target_id, %({"status": "suspended"}), ctx)
      suspend.should be_a(Facet::ServiceError)
      suspend.as(Facet::ServiceError).status.should eq(403)

      deleted = authority_delete(db, "iam", "Account", target_id, ctx)
      deleted.should be_a(Facet::ServiceError)
      deleted.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies a cosmetic edit of a higher-ceiling account" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      admin_ctx = Facet::RBAC::AuthContext.system
      target = authority_create_account(db, "cosmetic@example.test", ["iam.Roles.admin"], admin_ctx)
      target_id = target.as(Facet::Document::Create::Result).projection.id

      result = authority_update(db, "iam", "Account", target_id, %({"name": "Just Renaming"}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "allows account and role edits at or below the caller level" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*", "update|*.*", "delete|*.*", "read|*.*"])

      # A lower-level account edit.
      target = authority_create_account(db, "below@example.test", ["iam.Roles.viewer"], ctx)
      target.should be_a(Facet::Document::Create::Result)
      target_id = target.as(Facet::Document::Create::Result).projection.id
      updated = authority_update(db, "iam", "Account", target_id, %({"name": "Renamed"}), ctx)
      updated.should be_a(Facet::Document::Update::Result)

      # A narrowing role edit on a role at the caller's own level.
      role = authority_create(db, "iam", "Roles",
        %({"name": "narrow_me", "level": 30, "permissions": [{"action": "read", "on": "crm.Project"}, {"action": "update", "on": "crm.Project"}]}), ctx)
      role.should be_a(Facet::Document::Create::Result)
      narrowed = authority_update(db, "iam", "Roles", "iam.Roles.narrow_me",
        %({"permissions": [{"action": "read", "on": "crm.Project"}]}), ctx)
      narrowed.should be_a(Facet::Document::Update::Result)
    end
  end

  it "allows same-level lateral assignment deliberately" do
    with_db do |db|
      authority_seed_roles(db)
      # The caller assigns a role at the same level even though the
      # caller's own permission set is a bare wildcard write line —
      # lateral assignment is content-blind by decision. `read iam.Roles`
      # satisfies the B-356 reference check on the assigned role.
      ctx = authority_caller_ctx(30, ["create|*.*", "update|*.*", "read|iam.Roles"])
      target = authority_create_account(db, "lateral@example.test", ["iam.Roles.editor"], ctx)
      target.should be_a(Facet::Document::Create::Result)
      target_id = target.as(Facet::Document::Create::Result).projection.id

      result = authority_update(db, "iam", "Account", target_id, %({"roles": ["iam.Roles.editor", "iam.Roles.viewer"]}), ctx)
      result.should be_a(Facet::Document::Update::Result)
    end
  end

  it "denies a final default_role outside the final roles array" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*"])
      result = authority_create_account(db, "dangling-default@example.test",
        ["iam.Roles.viewer"], ctx, default_role: "iam.Roles.editor")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.details.try(&.any?(&.message.includes?("default_role"))).should be_true
    end
  end

  it "denies dangling or deleted role references" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*"])
      result = authority_create_account(db, "dangling@example.test", ["iam.Roles.does_not_exist"], ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      # A deleted role reference denies too: delete the viewer role (as
      # System), then create an account pointing at it.
      authority_delete(db, "iam", "Roles", "iam.Roles.viewer", Facet::RBAC::AuthContext.system)
      result2 = authority_create_account(db, "deleted-ref@example.test", ["iam.Roles.viewer"], ctx)
      result2.should be_a(Facet::ServiceError)
      result2.as(Facet::ServiceError).status.should eq(403)
    end
  end

  # ── iam.Roles power rules ───────────────────────────────────────────

  it "allows a role update that only narrows existing power when the target is not above the caller" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      # viewer is level 20 — at or below the caller. Narrowing its read
      # line (implied by its previous line) passes.
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"permissions": [{"action": "read", "on": "core.Currency"}]}), ctx)
      result.should be_a(Facet::Document::Update::Result)
    end
  end

  it "denies visible-tag widening outside previous plus caller tags" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      # viewer carries [default]; the caller carries [default, hr]. The
      # "finance" tag is in neither union → denied.
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"visible_tags": ["default", "finance"]}), ctx)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      # The denial names the tag union rule, not a bare authority refusal —
      # the roles UI surfaces the field to the operator through it.
      err.details.try(&.any?(&.message.includes?("visible_tags"))).should be_true
    end
  end

  it "allows any tag when the caller holds the wildcard tag" do
    with_db do |db|
      authority_seed_roles(db)
      # Same shape as the denial above, but the caller's visible_tags
      # carry the wildcard: the union contains everything, so the write
      # lands (the admin escape hatch in tag_errors).
      role_content = %({"name": "wildcard_caller", "level": 30, "visible_tags": ["*"], "permissions": [{"action": "update", "on": "*.*"}]})
      role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
      ctx = Facet::RBAC::AuthContext.authenticated("wildcard-caller", role)
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"visible_tags": ["default", "finance"]}), ctx)
      result.should be_a(Facet::Document::Update::Result)
    end
  end

  it "allows tag narrowing within the previous plus caller union" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"visible_tags": ["default", "hr"]}), ctx)
      result.should be_a(Facet::Document::Update::Result)
    end
  end

  it "denies connectivity widening without an enabling baseline" do
    with_db do |db|
      authority_seed_roles(db)
      # The fixture viewer carries all four channels, so the containment
      # baseline already enables assistant. Narrow the target to
      # browser-only via a System write first, then the Real caller (whose
      # elected role carries no channels) cannot widen it into any
      # channel.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"connectivity": []}), Facet::RBAC::AuthContext.system)

      ctx = authority_caller_ctx(30, ["update|*.*"])
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"connectivity": ["mcp", "webhook", "api", "assistant"]}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies a budget above the enabling baseline even when access is enabled on both sides" do
    with_db do |db|
      authority_seed_roles(db)
      # Caller: assistant-enabled with a 100-token budget. The target starts
      # assistant-enabled with a 500 budget (a System write) — a numeric
      # baseline, not the unlimited one the fixture carries.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"connectivity": ["assistant"], "assistant_token_budget": 500}), Facet::RBAC::AuthContext.system)

      role_content = %({"name": "budget_caller", "level": 30, "connectivity": ["assistant"], "assistant_token_budget": 100, "visible_tags": ["default"], "permissions": [{"action": "update", "on": "*.*"}]})
      role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
      ctx = Facet::RBAC::AuthContext.authenticated("budget-caller", role)

      # Above every baseline (caller 100, previous 500): denied.
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 501}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      # Within both baselines: allowed.
      ok = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 100}), ctx)
      ok.should be_a(Facet::Document::Update::Result)
    end
  end

  it "does not merge access from one baseline with an inert unlimited budget from another" do
    with_db do |db|
      authority_seed_roles(db)
      # Caller: enabled, unlimited budget. Previous viewer: disabled.
      # A resulting enabled+unlimited write is implied by the caller alone
      # here — flip the shapes: caller disabled, previous enabled with 50.
      role_content = %({"name": "no_access_caller", "level": 30, "connectivity": [], "assistant_token_budget": null, "visible_tags": ["default"], "permissions": [{"action": "update", "on": "*.*"}]})
      role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
      ctx = Facet::RBAC::AuthContext.authenticated("no-access-caller", role)

      # First give viewer enabled+50 (System write), then the disabled-
      # access caller tries to raise the budget to unlimited: the previous
      # baseline (enabled, 50) covers access but not unlimited; the caller
      # baseline covers nothing. Denied.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"connectivity": ["assistant"], "assistant_token_budget": 50}), Facet::RBAC::AuthContext.system)

      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": null}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies an unrecognized role-power field change" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["update|*.*"])
      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"secret_power": "escalate"}), ctx)
      # Unknown fields fail at doctype validation (422) before the
      # authority boundary — either way the write is refused.
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "denies an unknown field on role create for a Real caller" do
    with_db do |db|
      authority_seed_roles(db)
      ctx = authority_caller_ctx(30, ["create|*.*"])
      result = authority_create(db, "iam", "Roles",
        %({"name": "mystery_role", "level": 10, "permissions": [], "hidden_power": true}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "gives a caller holding admin and editor only viewer authority while viewer is elected" do
    with_db do |db|
      authority_seed_roles(db)
      # The account holds both roles, but the elected active role is viewer
      # (level 20, read-only). Its authority for IAM writes is viewer's.
      account = authority_create_account(db, "dual@example.test", ["iam.Roles.admin"], Facet::RBAC::AuthContext.system)
      account_id = account.as(Facet::Document::Create::Result).projection.id

      viewer_content = %({"name": "viewer", "level": 20, "visible_tags": ["default"], "permissions": [{"action": "read", "on": "*.*", "except": ["core.SystemSettings", "iam.OIDCProvider"]}]})
      role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(viewer_content))
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, role)

      # No write permission at all → the row-level RBAC gate denies first.
      result = authority_update(db, "iam", "Account", account_id, %({"name": "X"}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      # Even with the write grant, viewer's level (20) cannot assign admin.
      writer_content = %({"name": "viewer_writer", "level": 20, "visible_tags": ["default"], "permissions": [{"action": "update", "on": "*.*"}]})
      writer = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(writer_content))
      writer_ctx = Facet::RBAC::AuthContext.authenticated(account_id, writer)
      result2 = authority_update(db, "iam", "Account", account_id, %({"roles": ["iam.Roles.admin"]}), writer_ctx)
      result2.should be_a(Facet::ServiceError)
      result2.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "keeps System writes unchanged (OIDC JIT, invite, provisioning)" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      # A level-100 role and an admin account: ordinary System flows.
      role = authority_create(db, "iam", "Roles",
        %({"name": "sys_role", "level": 100, "permissions": [{"action": "read", "on": "hr.Employee"}]}), sys)
      role.should be_a(Facet::Document::Create::Result)

      account = authority_create_account(db, "sys-account@example.test", ["iam.Roles.admin"], sys)
      account.should be_a(Facet::Document::Create::Result)

      # System can lower the level too.
      lowered = authority_update(db, "iam", "Roles", "iam.Roles.sys_role", %({"level": 10}), sys)
      lowered.should be_a(Facet::Document::Update::Result)
    end
  end

  it "denies a Real write when the elected role carries no level (fail closed)" do
    with_db do |db|
      authority_seed_roles(db)
      role_content = %({"name": "levelless", "visible_tags": ["default"], "permissions": [{"action": "update", "on": "*.*"}]})
      role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
      ctx = Facet::RBAC::AuthContext.authenticated("levelless-caller", role)

      result = authority_update(db, "iam", "Roles", "iam.Roles.viewer", %({"description": "x"}), ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  # ── Assistant budget lock (B-372) ───────────────────────────────────

  it "lets a self-locked admin restore the budget its other roles imply" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      # The admin lowers its own role to 100 — the QA repro shape.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 100}), sys)

      # The account also holds viewer, which carries no budget (unlimited).
      account = authority_create_account(db, "locked@example.test", ["iam.Roles.admin", "iam.Roles.viewer"], sys)
      account_id = account.as(Facet::Document::Create::Result).projection.id

      ctx = authority_self_locked_ctx(db, account_id, "iam.Roles.admin", 100)

      # Above the locked value and above nothing else: still refused.
      # (viewer's fixture content carries no budget, so the widest other
      # baseline is unlimited — 5000 restores rather than widens.)
      above = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 5000}), ctx)
      above.should be_a(Facet::Document::Update::Result)

      # Clearing the budget restores what the other baseline implies.
      cleared = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": null}), ctx)
      cleared.should be_a(Facet::Document::Update::Result)
    end
  end

  it "refuses a raise or clear when the caller holds no wider other role" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      # viewer carries a 200 budget, admin locks itself at 100.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 200}), sys)
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 100}), sys)

      account = authority_create_account(db, "capped@example.test", ["iam.Roles.admin", "iam.Roles.viewer"], sys)
      account_id = account.as(Facet::Document::Create::Result).projection.id
      ctx = authority_self_locked_ctx(db, account_id, "iam.Roles.admin", 100)

      # The widest other baseline is 200 — 201 and unlimited both widen.
      above = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 201}), ctx)
      above.should be_a(Facet::ServiceError)
      above.as(Facet::ServiceError).status.should eq(403)

      unlimited = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": null}), ctx)
      unlimited.should be_a(Facet::ServiceError)
      unlimited.as(Facet::ServiceError).status.should eq(403)

      # At the widest other baseline: restored.
      at_cap = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 200}), ctx)
      at_cap.should be_a(Facet::Document::Update::Result)
    end
  end

  it "lets a self-locked admin restore a budget another role already holds" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 5000}), sys)
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 100}), sys)

      account = authority_create_account(db, "restore@example.test", ["iam.Roles.admin", "iam.Roles.viewer"], sys)
      account_id = account.as(Facet::Document::Create::Result).projection.id
      ctx = authority_self_locked_ctx(db, account_id, "iam.Roles.admin", 100)

      restored = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 5000}), ctx)
      restored.should be_a(Facet::Document::Update::Result)
    end
  end

  it "refuses a self-locked admin that holds no other role" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 100}), sys)

      account = authority_create_account(db, "solo@example.test", ["iam.Roles.admin"], sys)
      account_id = account.as(Facet::Document::Create::Result).projection.id
      ctx = authority_self_locked_ctx(db, account_id, "iam.Roles.admin", 100)

      # No other baseline: the lock stays, System is the repair path.
      above = authority_update(db, "iam", "Roles", "iam.Roles.admin",
        %({"assistant_token_budget": 5000}), ctx)
      above.should be_a(Facet::ServiceError)
      above.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "does not extend the escape to a role outside the caller's own" do
    with_db do |db|
      authority_seed_roles(db)
      sys = Facet::RBAC::AuthContext.system

      # viewer starts enabled at 100; admin is the caller's elected role
      # with a 200 budget.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 100}), sys)

      account = authority_create_account(db, "other@example.test", ["iam.Roles.admin", "iam.Roles.viewer"], sys)
      account_id = account.as(Facet::Document::Create::Result).projection.id
      ctx = authority_self_locked_ctx(db, account_id, "iam.Roles.admin", 200)

      # The write targets viewer, so the caller's other roles never join in:
      # admin's 200 is the caller baseline and covers the raise.
      widened = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 200}), ctx)
      widened.should be_a(Facet::Document::Update::Result)

      # Above the caller baseline: refused — the escape is self-only, so the
      # caller's other role content adds nothing here.
      above = authority_update(db, "iam", "Roles", "iam.Roles.viewer",
        %({"assistant_token_budget": 201}), ctx)
      above.should be_a(Facet::ServiceError)
      above.as(Facet::ServiceError).status.should eq(403)
    end
  end
end
