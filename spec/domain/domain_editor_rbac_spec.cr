# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/domain"
require "../../src/document"
require "../../src/doctype"
require "../../src/rbac"
require "../../src/iam"
require "../support/iam_helper"

# The domain-editor enforcement matrix, end to end: a member editor and a
# non-member editor against the definition surfaces (domain PATCH, doctype
# create/update/delete, DocumentView writes, publish fresh/overwrite, draft
# discard vs live drop, preview-session), plus the auto-grant on creation,
# the publish carry-over, and the teardown cleanup.
#
# Matrix (from the plan):
#
# | Surface                         | Admin | Editor, member | Editor, non-member |
# |---------------------------------|-------|----------------|--------------------|
# | PATCH core.Domain               | yes   | yes            | 404 ($domain_editor scope fails) |
# | Draft create / draft-from       | yes   | yes            | yes                |
# | Publish (fresh) own draft       | yes   | yes            | n/a                |
# | Publish (overwrite) target      | yes   | must edit target | 403              |
# | Discard draft (/drop on draft)  | yes   | yes            | 403                |
# | Drop live domain                | yes   | no             | no                 |
# | /check domain or doctype        | yes   | yes            | 403                |
# | POST /Api/core/DocType          | yes   | in their domains | 403 (service)    |
# | PUT/DELETE core.DocType         | yes   | in their domains | 403              |
# | DocumentView writes             | yes   | in their domains | 403 / 422 (hook) |
# | Manage core.DomainEditor rows   | yes   | no             | no                 |
private def seed_rbac_infrastructure(db) : Nil
  restore_seeded_baseline(db)
end

private def role_ctx(db, account_id : String) : Facet::RBAC::AuthContext
  seed_test_roles(db)
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.editor")
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def create_account_row(db, account_id : String) : Nil
  ensure_iam_account(db, account_id)
end

# A live `crm` domain with one doctype and one business document.
private def seed_live_domain(db, name : String) : String
  create_domain(db, name)
  Facet::Document::Create.call(
    db, "core", "DocType",
    %({"doctype": "Widget", "domain": "#{name}", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
    Facet::RBAC::AuthContext.system,
  )
  doc = Facet::Document::Create.call(
    db, name, "Widget", %({"name": "w1"}), Facet::RBAC::AuthContext.system
  )
  doc.as(Facet::Document::Create::Result).projection.id
end

private def create_domain(db, name : String) : Nil
  Facet::Mutation::Client.create(db, "core", "Domain", doc_id: name, content: %({}), actioner_id: "system")
end

private def create_domain_editor_row(db, account_id : String, domain_id : String) : Nil
  Facet::Document::Create.call(
    db, "core", "DomainEditor",
    %({"account": "iam.Account.#{account_id}", "domain": "#{domain_id}"}),
    Facet::RBAC::AuthContext.system,
  )
end

private def create_view(db, qualified_doctype : String, kind = "view")
  Facet::Document::Create.call(
    db, "core", "DocumentView",
    %({"parent_doctype": "#{qualified_doctype}", "kind": "#{kind}"}),
    Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(qualified_doctype)},
  )
end

describe "domain-editor RBAC enforcement matrix" do
  before_each do
    with_db do |db|
      seed_rbac_infrastructure(db)
      create_account_row(db, "acc_member")
      create_account_row(db, "acc_outsider")
    end
  end

  describe "domain document writes" do
    it "allows a member editor to PATCH the domain and denies a non-member" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")

        member = role_ctx(db, "acc_member")
        patch = Facet::Document::Update.call(db, "core", "Domain", "crm", %({"description": "ok"}), member)
        patch.should be_a(Facet::Document::Update::Result)

        outsider = role_ctx(db, "acc_outsider")
        denied = Facet::Document::Update.call(db, "core", "Domain", "crm", %({"description": "no"}), outsider)
        denied.should be_a(Facet::ServiceError)
        # The editor role holds the scoped `update core.Domain $domain_editor`
        # line, so the non-member is a grant holder whose row scope fails —
        # the non-disclosing 404, not a class-level 403.
        denied.as(Facet::ServiceError).status.should eq(404)
      end
    end

    it "denies a member editor dropping a live domain but allows discarding an edited draft" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        member = role_ctx(db, "acc_member")

        # The service itself is caller-gated; the route runs authorize_delete.
        # Enforce the route's gate here: the member editor may not drop a
        # LIVE domain, only discard drafts they edit.
        Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Domain", "crm", member).should be_false

        # The member discards a draft they edit.
        draft = Facet::Domain::Draft.create(db, "{}", "acc_member")
        draft.should be_a(Facet::Domain::Draft::Result)
        draft_id = draft.as(Facet::Domain::Draft::Result).projection.id
        Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Domain", draft_id, member).should be_true

        # The non-member cannot discard the same draft.
        outsider = role_ctx(db, "acc_outsider")
        Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Domain", draft_id, outsider).should be_false

        # Cleanup for the next assertion: drop the draft through the service.
        Facet::Domain::Drop.call(db, draft_id, "acc_member")
      end
    end

    it "gates /check like PATCH" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", "crm", member).should be_true
        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", "crm", outsider).should be_false
      end
    end
  end

  describe "auto-grant on creation" do
    it "grants the creator of a draft editorship" do
      with_db do |db|
        draft = Facet::Domain::Draft.create(db, "{}", "acc_member")
        draft.should be_a(Facet::Domain::Draft::Result)
        draft_id = draft.as(Facet::Domain::Draft::Result).projection.id
        Facet::Domain::Editors.member?(db, draft_id, "acc_member").should be_true
      end
    end

    it "grants the creator of a draft-from editorship" do
      with_db do |db|
        seed_live_domain(db, "crm")
        draft = Facet::Domain::Draft.create_from(db, "crm", "acc_member")
        draft.should be_a(Facet::Domain::Draft::Result)
        draft_id = draft.as(Facet::Domain::Draft::Result).projection.id
        Facet::Domain::Editors.member?(db, draft_id, "acc_member").should be_true
      end
    end

    it "grants the creator of a generic live domain editorship" do
      with_db do |db|
        result = Facet::Document::Create.call(
          db, "core", "Domain", %({"id": "freshdom", "description": "x"}),
          role_ctx(db, "acc_member"),
        )
        result.should be_a(Facet::Document::Create::Result)
        Facet::Domain::Editors.member?(db, "freshdom", "acc_member").should be_true
      end
    end

    it "answers 403 for a caller without create core.Domain on the generic path" do
      with_db do |db|
        seed_test_roles(db)
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.viewer")
        )
        ctx = Facet::RBAC::AuthContext.authenticated("acc_outsider", role)
        result = Facet::Document::Create.call(db, "core", "Domain", %({"id": "sneaky"}), ctx)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end
  end

  describe "doctype writes" do
    it "gates POST /Api/core/DocType on membership through the service gate" do
      with_db do |db|
        seed_live_domain(db, "crm")
        seed_live_domain(db, "hr")

        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        # Member of crm → may register a doctype in crm…
        create_domain_editor_row(db, "acc_member", "crm")
        ok = Facet::Doctype::Create.call(
          db, "core", "DocType",
          %({"doctype": "Gadget", "domain": "crm", "schema_version": 1, "search": "{{ display_name }}", "fields": {}}),
          member,
        )
        ok.should be_a(Facet::Doctype::Create::Result)

        # …but not in hr.
        denied = Facet::Doctype::Create.call(
          db, "core", "DocType",
          %({"doctype": "Gadget", "domain": "hr", "schema_version": 1, "search": "{{ display_name }}", "fields": {}}),
          member,
        )
        denied.should be_a(Facet::ServiceError)
        denied.as(Facet::ServiceError).status.should eq(403)

        # The non-member is denied everywhere.
        denied2 = Facet::Doctype::Create.call(
          db, "core", "DocType",
          %({"doctype": "Gadget", "domain": "crm", "schema_version": 1, "search": "{{ display_name }}", "fields": {}}),
          outsider,
        )
        denied2.should be_a(Facet::ServiceError)
        denied2.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "gates PUT/DELETE core.DocType on membership through the scope" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", "crm.Widget", member).should be_true
        Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "DocType", "crm.Widget", member).should be_true
        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", "crm.Widget", outsider).should be_false
      end
    end
  end

  describe "DocumentView writes" do
    it "allows a member editor through the flat create (hook passes) and denies a non-member via the hook" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        member_view = Facet::Document::Create.call(
          db, "core", "DocumentView",
          %({"parent_doctype": "crm.Widget", "kind": "card"}),
          member,
          meta_overrides: {"parent_id" => JSON::Any.new("crm.Widget")},
        )
        member_view.should be_a(Facet::Document::Create::Result)

        outsider_view = Facet::Document::Create.call(
          db, "core", "DocumentView",
          %({"parent_doctype": "crm.Widget", "kind": "inline"}),
          outsider,
          meta_overrides: {"parent_id" => JSON::Any.new("crm.Widget")},
        )
        outsider_view.should be_a(Facet::ServiceError)
        error = outsider_view.as(Facet::ServiceError)
        error.status.should eq(422)
        error.details.not_nil!.first.message.should contain("does not belong to a domain you edit")
      end
    end

    it "denies a non-member's view update with 403 (scope) while create denies with 422 (hook)" do
      with_db do |db|
        seed_live_domain(db, "crm")
        outsider = role_ctx(db, "acc_outsider")
        view = create_view(db, "crm.Widget")
        view_id = view.as(Facet::Document::Create::Result).projection.id

        # Update/delete on an existing row evaluate the scope — no match
        # for a non-member → 403 at the enforcer.
        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocumentView", view_id, outsider).should be_false

        # The nested create action gate itself passes for any editor — the
        # scoped `create core.DocType` line prefix-matches the host-scoped
        # sidecar path — so the denial lands on the create hook (422),
        # which the flat-create test above covers.
        Facet::RBAC::WriteEnforcer.authorize_sidecar_create(
          db, "core", "DocType", "core", "DocumentView", outsider
        ).should be_true
      end
    end

    it "gates update/delete of views on membership through the scope" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        view = create_view(db, "crm.Widget")
        view_id = view.as(Facet::Document::Create::Result).projection.id
        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocumentView", view_id, member).should be_true
        Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocumentView", view_id, outsider).should be_false
      end
    end
  end

  describe "publish" do
    it "publishes a member's fresh draft, carries editors over, and cleans the draft's rows" do
      with_db do |db|
        seed_live_domain(db, "crm")
        member = role_ctx(db, "acc_member")
        outsider = role_ctx(db, "acc_outsider")

        draft = Facet::Domain::Draft.create(db, "{}", "acc_member")
        draft_id = draft.as(Facet::Domain::Draft::Result).projection.id

        # A co-editor of the draft (granted by admin) keeps rights on the
        # published target.
        create_account_row(db, "acc_coeditor")
        create_domain_editor_row(db, "acc_coeditor", draft_id)

        result = Facet::Domain::Publish.call(
          db, draft_id, "published-dom",
          actioner_id: "acc_member", auth_context: member,
        )
        result.should be_a(Facet::Domain::Publish::Result)

        Facet::Domain::Editors.member?(db, "published-dom", "acc_member").should be_true
        Facet::Domain::Editors.member?(db, "published-dom", "acc_coeditor").should be_true
        # The draft's editor rows are gone.
        Facet::Domain::Editors.member?(db, draft_id, "acc_member").should be_false

        # The non-member cannot overwrite the published domain from a new
        # draft: the draft itself is theirs, but they do not edit the target.
        draft2 = Facet::Domain::Draft.create(db, "{}", "acc_outsider")
        draft2_id = draft2.as(Facet::Domain::Draft::Result).projection.id
        denied = Facet::Domain::Publish.call(
          db, draft2_id, "published-dom",
          actioner_id: "acc_outsider", overwrite: true, auth_context: outsider,
        )
        denied.should be_a(Facet::ServiceError)
        denied.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "lets an editor who edits both draft and target overwrite-publish" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")
        member = role_ctx(db, "acc_member")

        draft = Facet::Domain::Draft.create_from(db, "crm", "acc_member")
        draft_id = draft.as(Facet::Domain::Draft::Result).projection.id

        result = Facet::Domain::Publish.call(
          db, draft_id, "crm",
          actioner_id: "acc_member", overwrite: true, auth_context: member,
        )
        result.should be_a(Facet::Domain::Publish::Result)
      end
    end
  end

  describe "cleanup on drop" do
    it "tombstones the domain's editor rows when the domain is dropped" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")

        Facet::Domain::Drop.call(db, "crm", "system")
        Facet::Domain::Editors.member?(db, "crm", "acc_member").should be_false
      end
    end
  end

  describe "context-set resolution from DomainEditor rows" do
    it "resolves editor_domains per account" do
      with_db do |db|
        seed_live_domain(db, "crm")
        create_domain_editor_row(db, "acc_member", "crm")

        member_scope = Facet::RBAC::ScopeContext.load(db, "acc_member")
        member_sets = Facet::RBAC::ContextResolver.resolve_for_domain(db, "core", member_scope)
        member_sets["editor_domains"].should eq(["crm"])

        outsider_scope = Facet::RBAC::ScopeContext.load(db, "acc_outsider")
        outsider_sets = Facet::RBAC::ContextResolver.resolve_for_domain(db, "core", outsider_scope)
        outsider_sets["editor_domains"].should be_empty
      end
    end
  end

  describe "business documents stay blanket" do
    it "lets a non-member editor CRUD business documents (blanket lines unchanged)" do
      with_db do |db|
        seed_live_domain(db, "crm")
        outsider = role_ctx(db, "acc_outsider")

        created = Facet::Document::Create.call(db, "crm", "Widget", %({"name": "w2"}), outsider)
        created.should be_a(Facet::Document::Create::Result)
        doc_id = created.as(Facet::Document::Create::Result).projection.id

        updated = Facet::Document::Update.call(db, "crm", "Widget", doc_id, %({"name": "w3"}), outsider)
        updated.should be_a(Facet::Document::Update::Result)
      end
    end
  end
end
