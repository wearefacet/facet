# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"
require "../../src/document"
require "../support/rbac_helper"

# ── Specs ────────────────────────────────────────────────────────────────

module Facet::RBAC
  describe WriteEnforcer do
    before_each do
      with_db do |db|
        ensure_domain(db, "crm")
        create_rbac_project_doctype(db)
      end
    end

    # ── authorize_create ──────────────────────────────────────────────────

    describe ".authorize_create" do
      it "allows system bypass" do
        with_db do |db|
          result = WriteEnforcer.authorize_create(db, "crm", "Project", AuthContext.system)
          result.should be_true
        end
      end

      it "denies when role has no create permission" do
        with_db do |db|
          create_role_projection(db, "read_only", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "reader", ["read_only"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "read_only")
          )
          ctx = AuthContext.authenticated("reader", role)
          result = WriteEnforcer.authorize_create(db, "crm", "Project", ctx)
          result.should be_false
        end
      end

      it "allows create with an unrestricted permission" do
        with_db do |db|
          create_role_projection(db, "creator", [
            permission_json("create", "crm.Project"),
          ])
          create_account_projection(db, "creator_1", ["creator"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "creator")
          )
          ctx = AuthContext.authenticated("creator_1", role)
          result = WriteEnforcer.authorize_create(db, "crm", "Project", ctx)
          result.should be_true
        end
      end

      it "allows create when the permission carries a named scope alias" do
        # Named scopes apply to existing rows; a row being created cannot
        # satisfy a content predicate. The create action is authorised as
        # long as the role has a matching `create` permission line — the
        # alias is irrelevant at create time.
        with_db do |db|
          create_role_projection(db, "scoped_creator", [
            permission_json("create", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "creator_2", ["scoped_creator"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "scoped_creator")
          )
          ctx = AuthContext.authenticated("creator_2", role)
          result = WriteEnforcer.authorize_create(db, "crm", "Project", ctx)
          result.should be_true
        end
      end
    end

    # ── authorize_update ──────────────────────────────────────────────────

    describe ".authorize_update" do
      it "allows system bypass" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, AuthContext.system)
          result.should be_true
        end
      end

      it "denies when no update permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "read_only", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "reader", ["read_only"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "read_only")
          )
          ctx = AuthContext.authenticated("reader", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_false
        end
      end

      it "allows update with an unrestricted permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "editor", [
            permission_json("update", "crm.Project"),
          ])
          create_account_projection(db, "editor_1", ["editor"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "editor")
          )
          ctx = AuthContext.authenticated("editor_1", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_true
        end
      end

      it "allows update when the named scope's $self predicate matches" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "iam.Account.owner_1"})
          create_role_projection(db, "self_editor", [
            permission_json("update", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "owner_1", ["self_editor"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "self_editor")
          )
          ctx = AuthContext.authenticated("owner_1", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_true
        end
      end

      it "allows update when the named scope's $self predicate matches the bare account id" do
        # Regression pair with the qualified form above: a plain string
        # owner field stores the bare id the create-hook recipe writes.
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "bare_owner"})
          create_role_projection(db, "self_editor_bare", [
            permission_json("update", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "bare_owner", ["self_editor_bare"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "self_editor_bare")
          )
          ctx = AuthContext.authenticated("bare_owner", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_true
        end
      end

      it "denies update when the named scope's $self predicate does not match" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "other_account"})
          create_role_projection(db, "self_editor", [
            permission_json("update", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "not_owner", ["self_editor"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "self_editor")
          )
          ctx = AuthContext.authenticated("not_owner", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_false
        end
      end

      it "fails closed when the named scope is undeclared on the doctype" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "owner_1"})
          create_role_projection(db, "ghost_editor", [
            permission_json("update", "crm.Project", "$ghost"),
          ])
          create_account_projection(db, "ghost_owner", ["ghost_editor"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "ghost_editor")
          )
          ctx = AuthContext.authenticated("ghost_owner", role)
          result = WriteEnforcer.authorize_update(db, "crm", "Project", doc_id, ctx)
          result.should be_false
        end
      end
    end

    # ── authorize_delete ──────────────────────────────────────────────────

    describe ".authorize_delete" do
      it "allows system bypass" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          result = WriteEnforcer.authorize_delete(db, "crm", "Project", doc_id, AuthContext.system)
          result.should be_true
        end
      end

      it "denies when no delete permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "read_only", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "reader", ["read_only"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "read_only")
          )
          ctx = AuthContext.authenticated("reader", role)
          result = WriteEnforcer.authorize_delete(db, "crm", "Project", doc_id, ctx)
          result.should be_false
        end
      end

      it "allows delete with an unrestricted delete permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "deleter", [
            permission_json("delete", "crm.Project"),
          ])
          create_account_projection(db, "editor_del", ["deleter"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "deleter")
          )
          ctx = AuthContext.authenticated("editor_del", role)
          result = WriteEnforcer.authorize_delete(db, "crm", "Project", doc_id, ctx)
          result.should be_true
        end
      end

      it "denies delete when the role only has update (not delete) permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "update_only", [
            permission_json("update", "crm.Project"),
          ])
          create_account_projection(db, "updater", ["update_only"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "update_only")
          )
          ctx = AuthContext.authenticated("updater", role)
          result = WriteEnforcer.authorize_delete(db, "crm", "Project", doc_id, ctx)
          result.should be_false
        end
      end
    end

    # ── authorize_action ──────────────────────────────────────────────────

    describe ".authorize_action" do
      it "allows system bypass" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          result = WriteEnforcer.authorize_action(db, "crm", "Project", doc_id, "promote", AuthContext.system)
          result.should be_true
        end
      end

      it "denies when no matching action permission" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "read_only", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "reader", ["read_only"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "read_only")
          )
          ctx = AuthContext.authenticated("reader", role)
          result = WriteEnforcer.authorize_action(db, "crm", "Project", doc_id, "promote", ctx)
          result.should be_false
        end
      end

      it "allows when the permission matches the named action" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          create_role_projection(db, "promoter", [
            permission_json("promote", "crm.Project"),
          ])
          create_account_projection(db, "promoter_1", ["promoter"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "promoter")
          )
          ctx = AuthContext.authenticated("promoter_1", role)
          result = WriteEnforcer.authorize_action(db, "crm", "Project", doc_id, "promote", ctx)
          result.should be_true
        end
      end

      it "allows action when the named scope's $self predicate matches" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "iam.Account.actioner_1"})
          create_role_projection(db, "self_action", [
            permission_json("archive", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "actioner_1", ["self_action"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "self_action")
          )
          ctx = AuthContext.authenticated("actioner_1", role)
          result = WriteEnforcer.authorize_action(db, "crm", "Project", doc_id, "archive", ctx)
          result.should be_true
        end
      end

      it "denies action when the named scope's $self predicate does not match" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "someone_else"})
          create_role_projection(db, "self_action", [
            permission_json("archive", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "not_actioner", ["self_action"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "self_action")
          )
          ctx = AuthContext.authenticated("not_actioner", role)
          result = WriteEnforcer.authorize_action(db, "crm", "Project", doc_id, "archive", ctx)
          result.should be_false
        end
      end
    end
  end
end
