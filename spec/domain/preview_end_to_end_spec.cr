# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/domain"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "../domain/draft_domains_spec"

# End-to-end integration of the preview-mode capability path.
#
# The preview principal is constructed directly (bypassing the JWT round
# trip, which is covered by `auth_handler_preview_token_spec.cr`) and
# threaded through `Document::Create/Read/Update/Delete/List` against a
# draft doctype. This proves the enforcer branch + document services
# compose correctly end-to-end — the feature's central acceptance test.
#
# The draft helpers (`seed_core_domain_doctype`, `create_doctype_in_domain`)
# are imported from `draft_domains_spec.cr`.

# Fixture: create an empty draft domain, a doctype under it, and yield the
# draft id. Mirrors what `seed_live_and_draft` does but for an empty draft
# (no source live domain to fork from).
def with_previewable_draft(& : String -> _)
  Facet::Database.with_transaction do |txn|
    # Restore the core doctype definitions (core.DocType, core.Domain,
    # core.DocumentView, core.CollectionView, iam.* — all wiped by the
    # per-test TRUNCATE). Without `core.DocumentView`'s doctype row,
    # `Document::Read` on a DocumentView projection returns 404 because
    # the definition can't be loaded by `DefinitionStore.fetch`.
    restore_seeded_baseline(txn)

    # Create the draft domain.
    draft_result = Facet::Domain::Draft.create(txn, "{}", "account-1")
    draft_result.should be_a(Facet::Domain::Draft::Result)
    draft_id = draft_result.as(Facet::Domain::Draft::Result).projection.id

    # Register a Widget doctype on the draft. `create_doctype_in_domain`
    # writes directly via `Mutation::Client.create` so it bypasses
    # `Doctype::Create`'s domain-name regex (which rejects the `_`).
    create_doctype_in_domain(txn, draft_id, "Widget", %({"name": {"type": "string"}}))

    # And one DocumentView child of the draft's Widget doctype, so we
    # can verify the read carve-out in `core.DocumentView`.
    Facet::Mutation::Client.create(
      txn, "core", "DocumentView",
      doc_id: Facet::Util::ScriptHelpers.ulid,
      content: %({"kind": "view", "template": ""}),
      meta: %({"parent_id": "#{draft_id}.Widget"}),
      actioner_id: "system",
    )

    yield draft_id
  end
end

# The capability principal the user would obtain from
# `POST /Api/core/Domain/:id/preview-session`.
def preview_principal(draft_id : String) : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.preview("account_1", draft_id)
end

# Creates a second draft domain (distinct from the test's main draft) with
# the Gadget doctype but no documents. Returns the generated draft id.
# Used to verify that a preview principal bound to draft A is denied reads
# against draft B (no cross-draft leak).
def create_second_draft_with_doctype(db) : String
  Facet::Database.with_transaction do |txn|
    other_result = Facet::Domain::Draft.create(txn, "{}", "account-1")
    other_id = other_result.as(Facet::Domain::Draft::Result).projection.id
    create_doctype_in_domain(txn, other_id, "Gadget", %({"name": {"type": "string"}}))
    other_id
  end
end

# Like `create_second_draft_with_doctype`, but also creates a single Gadget
# document with the given doc_id in the new draft. Used so that read/update
# denial has an actual target document to deny access to.
def create_second_draft_with_doc(db, doc_id : String) : String
  Facet::Database.with_transaction do |txn|
    other_result = Facet::Domain::Draft.create(txn, "{}", "account-1")
    other_id = other_result.as(Facet::Domain::Draft::Result).projection.id
    create_doctype_in_domain(txn, other_id, "Gadget", %({"name": {"type": "string"}}))
    Facet::Mutation::Client.create(
      txn, other_id, "Gadget",
      doc_id: doc_id,
      content: %({"name": "leak"}),
      actioner_id: "system",
    )
    other_id
  end
end

describe "Preview mode end-to-end" do
  describe "Document::Create" do
    it "allows creating a document of the draft doctype" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          result = Facet::Document::Create.call(
            db, draft_id, "Widget",
            %({"name": "first widget"}),
            preview_principal(draft_id),
          )
          result.should be_a(Facet::Document::Create::Result)
          res = result.as(Facet::Document::Create::Result)
          res.projection.content["name"].as_s.should eq("first widget")

          # The preview principal's account_id is attributed in the
          # mutation audit log (mutations.actioner_id), not on the
          # projection meta.
          actioner = db.query_one(
            "SELECT actioner_id FROM mutations WHERE id = $1",
            res.mutation_id,
            as: String,
          )
          actioner.should eq("account_1")
        end
      end
    end

    it "denies creating a document on a live domain (no live-data modification through preview)" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          ensure_domain(db, "live")
          create_doctype_in_domain(db, "live", "Order", %({"name": {"type": "string"}}))

          result = Facet::Document::Create.call(
            db, "live", "Order",
            %({"name": "leak"}),
            preview_principal(draft_id),
          )
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(403)
        end
      end
    end
  end

  describe "Document::Read + List" do
    it "reads and lists draft documents under the bound draft" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          # Seed two documents on the draft.
          doc_id_1 = Facet::Util::ScriptHelpers.ulid
          Facet::Mutation::Client.create(
            db, draft_id, "Widget",
            doc_id: doc_id_1,
            content: %({"name": "w1"}),
            actioner_id: "system",
          )
          doc_id_2 = Facet::Util::ScriptHelpers.ulid
          Facet::Mutation::Client.create(
            db, draft_id, "Widget",
            doc_id: doc_id_2,
            content: %({"name": "w2"}),
            actioner_id: "system",
          )

          ctx = preview_principal(draft_id)

          # Single-document read.
          read = Facet::Document::Read.call(db, draft_id, "Widget", doc_id_1, ctx)
          read.should be_a(Facet::Document::Read::Result)
          read.as(Facet::Document::Read::Result).projection.content["name"].as_s.should eq("w1")

          # List query.
          list = Facet::Document::List.call(db, draft_id, "Widget", auth_context: ctx)
          list.should be_a(Facet::Document::List::Result)
          list.as(Facet::Document::List::Result).total.should eq(2)
        end
      end
    end

    it "denies reading a draft document under a different draft" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          other_doc_id = Facet::Util::ScriptHelpers.ulid
          other_id = create_second_draft_with_doc(db, other_doc_id)

          read = Facet::Document::Read.call(db, other_id, "Gadget", other_doc_id, preview_principal(draft_id))
          read.should be_a(Facet::ServiceError)
          err = read.as(Facet::ServiceError)
          err.status.should eq(404) # non-disclosing
        end
      end
    end

    it "denies listing a draft doctype under a different draft" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          other_id = create_second_draft_with_doctype(db)

          list = Facet::Document::List.call(db, other_id, "Gadget", auth_context: preview_principal(draft_id))
          list.should be_a(Facet::Document::List::Result)
          list.as(Facet::Document::List::Result).total.should eq(0) # 1=0 clause
        end
      end
    end
  end

  describe "Document::Update + Delete" do
    it "updates and deletes draft documents under the bound draft" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          doc_id = Facet::Util::ScriptHelpers.ulid
          Facet::Mutation::Client.create(
            db, draft_id, "Widget",
            doc_id: doc_id,
            content: %({"name": "w1"}),
            actioner_id: "system",
          )

          ctx = preview_principal(draft_id)

          # Update.
          update = Facet::Document::Update.call(
            db, draft_id, "Widget", doc_id,
            %({"name": "renamed"}),
            ctx,
          )
          update.should be_a(Facet::Document::Update::Result)
          updated = Facet::Mutation::Client.fetch_content(db, draft_id, "Widget", doc_id)
          updated["name"].as_s.should eq("renamed")

          # Delete.
          delete = Facet::Document::Delete.call(db, draft_id, "Widget", doc_id, ctx)
          delete.should be_a(Facet::Document::Delete::Result)
          proj = Facet::Mutation::Client.fetch_projection(db, draft_id, "Widget", doc_id)
          proj.deleted_at.should_not be_nil
        end
      end
    end

    it "denies updating a draft document under a different draft" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          other_doc_id = Facet::Util::ScriptHelpers.ulid
          other_id = create_second_draft_with_doc(db, other_doc_id)

          update = Facet::Document::Update.call(
            db, other_id, "Gadget", other_doc_id,
            %({"name": "hacked"}),
            preview_principal(draft_id),
          )
          update.should be_a(Facet::ServiceError)
          err = update.as(Facet::ServiceError)
          # The target sits outside the preview principal's bound draft — a
          # row-level denial. It maps to the non-disclosing 404, the same
          # answer a scoped caller gets when the row check fails: an
          # inaccessible document is indistinguishable from a missing one.
          err.status.should eq(404)
        end
      end
    end
  end

  describe "core.Domain read carve-out" do
    it "allows reading the bound draft's core.Domain projection by id" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          ctx = preview_principal(draft_id)

          # The live dashboard's fall-back fetch when entering `/_abc` during
          # preview hits `GET /Api/core/Domain/:id` for the bound draft's own
          # Domain projection. Without the single-doc carve-out in
          # `PreviewEnforcer.authorizes?`, the default `domain ==
          # preview_domain` rule denies with a non-disclosing 404 (because the
          # draft id is the row's id, not its `domain` column).
          read = Facet::Document::Read.call(db, "core", "Domain", draft_id, ctx)
          read.should be_a(Facet::Document::Read::Result)
          res = read.as(Facet::Document::Read::Result)
          res.projection.id.should eq(draft_id)
          res.projection.content["draft"].as_bool.should be_true
        end
      end
    end

    it "denies reading another draft's core.Domain row (cross-draft leak guard)" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          other_id = create_second_draft_with_doctype(db)

          ctx = preview_principal(draft_id)
          read = Facet::Document::Read.call(db, "core", "Domain", other_id, ctx)
          read.should be_a(Facet::ServiceError)
          err = read.as(Facet::ServiceError)
          err.status.should eq(404) # non-disclosing
        end
      end
    end
  end

  describe "core.DocType read carve-out" do
    it "allows reading the bound draft's core.DocType definition by id" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          ctx = preview_principal(draft_id)

          # Single-doc read of a `core.DocType` row whose `content->>'domain'`
          # equals the bound draft. The list path is already scoped by
          # `list_where_clauses`; the single-doc read needs the same row-level
          # check, otherwise the live app reading
          # `/Api/core/DocType/_abc.Widget` would be denied.
          read = Facet::Document::Read.call(db, "core", "DocType", "#{draft_id}.Widget", ctx)
          read.should be_a(Facet::Document::Read::Result)
          res = read.as(Facet::Document::Read::Result)
          res.projection.content["domain"].as_s.should eq(draft_id)
        end
      end
    end

    it "denies reading another draft's core.DocType row (cross-draft leak guard)" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          other_id = create_second_draft_with_doctype(db)

          ctx = preview_principal(draft_id)
          read = Facet::Document::Read.call(db, "core", "DocType", "#{other_id}.Gadget", ctx)
          read.should be_a(Facet::ServiceError)
          err = read.as(Facet::ServiceError)
          err.status.should eq(404) # non-disclosing
        end
      end
    end
  end

  describe "core.DocumentView read carve-out" do
    it "allows reading the draft's DocumentView children so the live app can render" do
      with_previewable_draft do |draft_id|
        with_db do |db|
          # Find the DocumentView we created in the fixture.
          view_id = db.query_one?(
            "SELECT id FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'DocumentView' " \
            "AND meta->>'parent_id' = $1 AND deleted_at IS NULL LIMIT 1",
            "#{draft_id}.Widget",
            as: String,
          )
          view_id.should_not be_nil

          ctx = preview_principal(draft_id)
          read = Facet::Document::Read.call(db, "core", "DocumentView", view_id.not_nil!, ctx)
          read.should be_a(Facet::Document::Read::Result)
        end
      end
    end
  end
end
