# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/domain"
require "../../src/document"
require "../../src/rbac"
require "../../src/iam"
require "../support/iam_helper"

# The `core.DomainEditor` doctype: the Lua guard hook (system-domain and
# unknown-domain rejection), admin CRUD through the document pipeline, and
# the editor role's carved-out write denial.
private def seed_editor_infrastructure(db) : Nil
  restore_seeded_baseline(db)
  # `Domain::Editors.grant` writes a `core.DomainEditor` document through the
  # full create path; its definition (script included) must be loaded.
  Facet::Doctype::Seed.ensure_doctype(db, "core", "DomainEditor")
  Facet::Doctype::DefinitionStore.cache.clear
end

private def admin_ctx : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.system
end

# A real editor principal carrying the seeded editor role shape (blanket
# lines with the definition-surface carve-out + scoped domain lines).
private def editor_ctx(db, account_id : String) : Facet::RBAC::AuthContext
  seed_test_roles(db)
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.editor")
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def create_domain_row(db, domain_id : String, content = %({})) : Nil
  Facet::Mutation::Client.create(db, "core", "Domain", doc_id: domain_id, content: content, actioner_id: "system")
end

describe "core.DomainEditor doctype" do
  describe "guard hook" do
    it "rejects a system domain as the grant target" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")

        result = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "core"}),
          admin_ctx,
        )
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.details.should_not be_nil
        error.details.not_nil!.first.message.should contain("system domain")
      end
    end

    it "rejects a target with no live core.Domain row" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")

        result = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "no-such-domain"}),
          admin_ctx,
        )
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.details.should_not be_nil
        error.details.not_nil!.first.message.should contain("does not exist")
      end
    end

    it "rejects a target whose core.Domain row is tombstoned" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "dropped")
        Facet::Mutation::Client.delete(db, "core", "Domain", "dropped", actioner_id: "system")

        result = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "dropped"}),
          admin_ctx,
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).details.not_nil!.first.message.should contain("does not exist")
      end
    end

    it "re-checks the target on update" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        created = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "live1"}),
          admin_ctx,
        )
        created.should be_a(Facet::Document::Create::Result)
        doc_id = created.as(Facet::Document::Create::Result).projection.id

        updated = Facet::Document::Update.call(
          db, "core", "DomainEditor", doc_id,
          %({"domain": "no-such-domain"}),
          admin_ctx,
        )
        updated.should be_a(Facet::ServiceError)
        updated.as(Facet::ServiceError).details.not_nil!.first.message.should contain("does not exist")
      end
    end
  end

  describe "admin CRUD" do
    it "creates, reads, updates, and deletes a grant" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        created = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "live1"}),
          admin_ctx,
        )
        created.should be_a(Facet::Document::Create::Result)
        doc_id = created.as(Facet::Document::Create::Result).projection.id

        content = Facet::Mutation::Client.fetch_content(db, "core", "DomainEditor", doc_id)
        content["domain"].as_s.should eq("live1")
        content["account"].as_s.should eq("iam.Account.acc_1")

        updated = Facet::Document::Update.call(
          db, "core", "DomainEditor", doc_id,
          %({"domain": "live1", "account": "iam.Account.acc_1"}),
          admin_ctx,
        )
        updated.should be_a(Facet::Document::Update::Result)

        deleted = Facet::Document::Delete.call(db, "core", "DomainEditor", doc_id, admin_ctx)
        deleted.should be_a(Facet::Document::Delete::Result)
      end
    end
  end

  describe "editor-role denial" do
    it "denies an editor creating a grant" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        result = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "live1"}),
          editor_ctx(db, "acc_1"),
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "denies an editor updating a grant" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        created = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "live1"}),
          admin_ctx,
        )
        created.should be_a(Facet::Document::Create::Result)
        doc_id = created.as(Facet::Document::Create::Result).projection.id

        result = Facet::Document::Update.call(
          db, "core", "DomainEditor", doc_id,
          %({"domain": "live1"}),
          editor_ctx(db, "acc_1"),
        )
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "denies an editor deleting a grant" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        created = Facet::Document::Create.call(
          db, "core", "DomainEditor",
          %({"account": "iam.Account.acc_1", "domain": "live1"}),
          admin_ctx,
        )
        created.should be_a(Facet::Document::Create::Result)
        doc_id = created.as(Facet::Document::Create::Result).projection.id

        result = Facet::Document::Delete.call(db, "core", "DomainEditor", doc_id, editor_ctx(db, "acc_1"))
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end
  end

  describe "Domain::Editors helpers" do
    it "member? reports membership from the stored rows" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        create_domain_row(db, "live1")

        Facet::Domain::Editors.member?(db, "live1", "acc_1").should be_false
        Facet::Domain::Editors.grant(db, "live1", "acc_1", "acc_1")
        Facet::Domain::Editors.member?(db, "live1", "acc_1").should be_true
        Facet::Domain::Editors.member?(db, "other", "acc_1").should be_false
      end
    end

    it "grant skips non-account actioners" do
      with_db do |db|
        seed_editor_infrastructure(db)

        Facet::Domain::Editors.grant(db, "live1", "system", "system")
        Facet::Domain::Editors.grant(db, "live1", "system:test", "system:test")
        Facet::Domain::Editors.member?(db, "live1", "system").should be_false
      end
    end

    it "transfer copies rows and skips existing pairs" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        ensure_iam_account(db, "acc_2")
        create_domain_row(db, "target")
        create_domain_row(db, "_draft", %({"draft": true}))

        Facet::Domain::Editors.grant(db, "_draft", "acc_1", "acc_1")
        Facet::Domain::Editors.grant(db, "_draft", "acc_2", "acc_2")
        Facet::Domain::Editors.grant(db, "target", "acc_2", "acc_2")

        Facet::Domain::Editors.transfer(db, "_draft", "target", "acc_1")

        Facet::Domain::Editors.member?(db, "target", "acc_1").should be_true
        Facet::Domain::Editors.member?(db, "target", "acc_2").should be_true
        # Exactly one row per (account, target) pair — the existing acc_2
        # row was skipped, not duplicated.
        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DomainEditor' " \
          "AND content->>'domain' = 'target' AND deleted_at IS NULL",
          as: Int64,
        )
        count.should eq(2)
      end
    end

    it "authorize_doctype_create? allows All, gates Scoped on membership" do
      with_db do |db|
        seed_editor_infrastructure(db)
        ensure_iam_account(db, "acc_1")
        ensure_iam_account(db, "acc_2")
        create_domain_row(db, "live1")

        Facet::Domain::Editors.grant(db, "live1", "acc_1", "acc_1")

        # Scoped + member → allowed.
        member_role = Facet::RBAC::ActiveRole.new(
          role_id: "scoped_editor",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [rbac_perm("create", "core.DocType", ["$domain_editor"])],
        )
        Facet::Domain::Editors.authorize_doctype_create?(
          db, "live1", Facet::RBAC::AuthContext.authenticated("acc_1", member_role)
        ).should be_true
        # Scoped + non-member → denied.
        Facet::Domain::Editors.authorize_doctype_create?(
          db, "live1", Facet::RBAC::AuthContext.authenticated("acc_2", member_role)
        ).should be_false
        # Wildcard → allowed.
        admin_role = Facet::RBAC::ActiveRole.new(
          role_id: "wildcard",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [rbac_perm("*", "*.*")],
        )
        Facet::Domain::Editors.authorize_doctype_create?(
          db, "live1", Facet::RBAC::AuthContext.authenticated("acc_2", admin_role)
        ).should be_true
        # System bypass → allowed.
        Facet::Domain::Editors.authorize_doctype_create?(db, "live1", admin_ctx).should be_true
        # Denied → fail closed.
        denied_role = Facet::RBAC::ActiveRole.new(
          role_id: "nobody",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [] of Facet::RBAC::Permission,
        )
        Facet::Domain::Editors.authorize_doctype_create?(
          db, "live1", Facet::RBAC::AuthContext.authenticated("acc_2", denied_role)
        ).should be_false
      end
    end
  end
end
