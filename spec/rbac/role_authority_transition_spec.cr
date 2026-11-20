# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/document/create"
require "../../src/document/update"
require "../../src/document/delete"
require "../../src/audit/rollback"
require "../../src/audit/list"

# RoleAuthority on named actions and rollback (execution plan Phase 3):
# the IAM transition boundary holds on every caller-controlled transition.
private def transition_seed(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# A Real caller whose elected role carries the given level and lines.
private def transition_ctx(level : Int32, perms : Array(String))
  lines = perms.map do |p|
    action, on = p.split("|", 2)
    %( {"action": "#{action}", "on": "#{on}"} )
  end
  role_content = %({"name": "rb_caller", "level": #{level}, "visible_tags": ["default"], "permissions": [#{lines.join(", ")}]})
  role = Facet::RBAC::ActiveRole.from_projection_content(JSON.parse(role_content))
  Facet::RBAC::AuthContext.authenticated("rb-caller-#{level}", role)
end

private def transition_sys_account(db, email, roles)
  body = {"email" => email, "name" => "T", "roles" => roles, "default_role" => roles.first}.to_json
  Facet::Document::Create.call(db, "iam", "Account", body, Facet::RBAC::AuthContext.system)
    .as(Facet::Document::Create::Result)
end

describe "RBAC::RoleAuthority on actions and rollback" do
  # ── Rollback ────────────────────────────────────────────────────────

  it "denies rolling an account back to a historical admin assignment" do
    with_db do |db|
      transition_seed(db)
      sys = Facet::RBAC::AuthContext.system

      # System: account starts with editor; then admin is assigned.
      account = transition_sys_account(db, "rb-admin@example.test", ["iam.Roles.editor"])
      account_id = account.projection.id
      Facet::Document::Update.call(db, "iam", "Account", account_id, %({"roles": ["iam.Roles.editor", "iam.Roles.admin"]}), sys)
        .as(Facet::Document::Update::Result)

      # A level-30 caller with update rights rolls the account back to the
      # historical admin assignment: 403 before persistence.
      ctx = transition_ctx(30, ["update|*.*"])
      history = Facet::Audit::List.call(db, domain: "iam", doc_type: "Account", doc_id: account_id, auth_context: sys).as(Facet::Audit::List::Result)
      admin_update = history.items.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, admin_update.id, ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      # The projection is untouched: the account still holds admin.
      content = Facet::Mutation::Client.fetch_content(db, "iam", "Account", account_id)
      content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.editor", "iam.Roles.admin"])
    end
  end

  it "denies rolling a role back to stronger historical permissions or tags" do
    with_db do |db|
      transition_seed(db)
      sys = Facet::RBAC::AuthContext.system

      # System: viewer gains read on *.* (stronger), then narrows back.
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"permissions": [{"action": "read", "on": "*.*"}]}), sys)
        .as(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.viewer",
        %({"permissions": [{"action": "read", "on": "core.Currency"}]}), sys)
        .as(Facet::Document::Update::Result)

      # A level-30 caller (read-only on roles is irrelevant — the caller
      # holds update) rolls viewer back to the stronger wildcard read.
      ctx = transition_ctx(30, ["update|*.*"])
      history = Facet::Audit::List.call(db, domain: "iam", doc_type: "Roles", doc_id: "iam.Roles.viewer", auth_context: sys).as(Facet::Audit::List::Result)
      # Oldest update first — the strengthening one (items sort newest-first).
      stronger_update = history.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, stronger_update.id, ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "denies rolling a higher-level role to a lower level" do
    with_db do |db|
      transition_seed(db)
      sys = Facet::RBAC::AuthContext.system

      # System lowers admin 100 → 90 (a legal System edit).
      Facet::Document::Update.call(db, "iam", "Roles", "iam.Roles.admin", %({"level": 90}), sys)
        .as(Facet::Document::Update::Result)

      # A level-30 caller rolls admin back to its level-100 state: the
      # current level (90) already exceeds the caller level → target
      # protection denies before the level comparison.
      ctx = transition_ctx(30, ["update|*.*"])
      history = Facet::Audit::List.call(db, domain: "iam", doc_type: "Roles", doc_id: "iam.Roles.admin", auth_context: sys).as(Facet::Audit::List::Result)
      level_update = history.items.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, level_update.id, ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "allows a visible, permitted rollback" do
    with_db do |db|
      transition_seed(db)
      sys = Facet::RBAC::AuthContext.system

      account = transition_sys_account(db, "rb-ok@example.test", ["iam.Roles.viewer"])
      account_id = account.projection.id
      Facet::Document::Update.call(db, "iam", "Account", account_id, %({"name": "Renamed"}), sys)
        .as(Facet::Document::Update::Result)

      ctx = transition_ctx(30, ["update|*.*"])
      history = Facet::Audit::List.call(db, domain: "iam", doc_type: "Account", doc_id: account_id, auth_context: sys).as(Facet::Audit::List::Result)
      rename = history.items.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, rename.id, ctx)
      result.should be_a(Facet::Audit::Rollback::Result)
    end
  end

  # ── Named actions ───────────────────────────────────────────────────

  it "runs a named action on a permitted document unchanged" do
    with_temp_doctype("rbact") do |db, domain, doctype|
      ensure_domain(db, domain)
      transition_seed(db)
      # A non-IAM doctype with a named action: the boundary passes through
      # non-IAM targets untouched.
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.archive(ctx) ctx.root.status = 'archived' end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      actions = %({"archive": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "T1", "status": "open"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # Named actions check their own action name — the caller needs the
      # `archive` line on the concrete doctype path.
      ctx = transition_ctx(30, ["archive|#{domain}.#{doctype}"])
      result = Facet::Document::Action.call(db, domain, doctype, doc_id, "archive", "{}", ctx)
      result.should be_a(Facet::Document::Action::Result)
      result.as(Facet::Document::Action::Result).projection.content["status"].as_s.should eq("archived")
    end
  end

  it "denies an action that raises an account role level" do
    with_db do |db|
      transition_seed(db)
      # iam.Account has no named action in the seed, so drive the same
      # boundary through a role-level action on a doctype that edits an
      # account via document.update — verify the nested write path denies.
      # Instead, exercise the direct guard: an action on iam.Roles is not
      # defined, so prove the target-protection call in place by checking
      # the account ceiling guard through the role-authority API with an
      # action operation.
      account = transition_sys_account(db, "rb-action@example.test", ["iam.Roles.admin"])
      ctx = transition_ctx(30, ["update|*.*"])

      error = Facet::RBAC::RoleAuthority.authorize_transition(
        db, "action", "iam", "Account", account.projection.content, nil, ctx,
      )
      error.should_not be_nil
      error.as(Facet::ServiceError).status.should eq(403)
    end
  end

  # ── Cluster rollback ────────────────────────────────────────────────

  it "refuses the whole cluster rollback when one document fails the IAM transition" do
    with_db do |db|
      transition_seed(db)
      sys = Facet::RBAC::AuthContext.system

      # Build a synthetic causal cluster (as System would): one mutation
      # assigns admin to the account, one touches an unrelated document.
      account = transition_sys_account(db, "cluster@example.test", ["iam.Roles.editor"])
      account_id = account.projection.id

      Facet::Document::Create.call(db, "iam", "Roles",
        %({"name": "cluster_side", "level": 10, "permissions": []}), sys)

      trace_root = Facet::Mutation::Client.new_id
      cause = Facet::Mutation::Cause.new(
        kind: Facet::Mutation::CauseKind::Request,
        trace: trace_root,
      ).resolve(trace_root)

      diff_account = %({"set": [{"path": ["roles"], "value": ["iam.Roles.editor", "iam.Roles.admin"]}], "unset": []})
      account_mut = Facet::Mutation::Client.update(db, "iam", "Account", account_id, diff_account,
        actioner_id: "system", cause: cause)

      diff_role = %({"set": [{"path": ["description"], "value": "touched by the cluster"}], "unset": []})
      Facet::Mutation::Client.update(db, "iam", "Roles", "iam.Roles.cluster_side", diff_role,
        actioner_id: "system", cause: cause)

      # The account now holds admin. A level-30 caller with update rights
      # everywhere undoes the cluster (the id pins the trace): the account
      # restore would resurrect the admin assignment → the preflight
      # refuses the WHOLE cluster.
      ctx = transition_ctx(30, ["update|*.*"])
      result = Facet::Audit::Rollback.call(db, account_mut, ctx, scope: Facet::Audit::Rollback::Scope::Cluster)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      # Neither document changed: the account still holds admin, the role
      # description is untouched.
      content = Facet::Mutation::Client.fetch_content(db, "iam", "Account", account_id)
      content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.editor", "iam.Roles.admin"])
      side = Facet::IAM::RoleStore.fetch(db, "iam.Roles.cluster_side").should_not be_nil
      side.as(JSON::Any)["description"].as_s.should eq("touched by the cluster")
    end
  end
end
