# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"
require "../../src/document"
require "../../src/doctype"

# ── Local helpers ─────────────────────────────────────────────────────────

# Creates a draft domain document by writing directly to the projections layer
# (bypassing `Domain::Draft.create` so the spec stays focused on the enforcer).
# Named distinct from `create_draft_domain` in draft_domains_spec.cr to avoid
# a Crystal overload merge widening the union of return types.
def seed_draft_domain_row(db : DB::Connection, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"draft": true}),
    actioner_id: "system",
  )
end

# Creates a `core.DocType` projection row for `(domain, doctype)` whose
# `content.domain` field matches `domain`. Used so the preview enforcer's
# parent-doctype lookup can resolve view-template children back to the draft.
def create_doctype_definition_row(db : DB::Connection, domain : String, doctype : String) : String
  doc_id = "#{domain}.#{doctype}"
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "fields": {}}),
    actioner_id: "system",
  )
  doc_id
end

# Creates a `core.DocumentView` row whose `meta.parent_id` is the given
# `core.DocType` id. Returns the new view's id.
def create_document_view_row(db : DB::Connection, parent_doctype_id : String, kind : String = "view") : String
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, "core", "DocumentView",
    doc_id: doc_id,
    content: %({"kind": "#{kind}", "template": ""}),
    meta: %({"parent_id": "#{parent_doctype_id}"}),
    actioner_id: "system",
  )
  doc_id
end

# Creates a draft-domain document of an arbitrary doctype (e.g. `_abc.Widget`).
# Named distinct from `create_doc` in draft_domains_spec.cr to avoid an
# overload collision.
def seed_draft_doc(db : DB::Connection, domain : String, doctype : String, content : String = "{}") : String
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, domain, doctype,
    doc_id: doc_id,
    content: content,
    actioner_id: "system",
  )
  doc_id
end

# Test fixture: two unrelated draft domains (`_abc`, `_xyz`) and one live
# domain (`live`), each with one doctype definition row + one document. Each
# draft's `core.DocType` row also has one DocumentView child. Yields a small
# snapshot object with the ids the spec needs.
record PreviewFixture,
  abc_widget_id : String,
  xyz_gadget_id : String,
  abc_view_id : String,
  xyz_view_id : String

def with_preview_fixture(& : PreviewFixture -> _)
  with_db do |db|
    seed_draft_domain_row(db, "_abc")
    seed_draft_domain_row(db, "_xyz")
    ensure_domain(db, "live")

    create_doctype_definition_row(db, "_abc", "Widget")
    create_doctype_definition_row(db, "_xyz", "Gadget")
    create_doctype_definition_row(db, "live", "Order")

    abc_view_id = create_document_view_row(db, "_abc.Widget")
    xyz_view_id = create_document_view_row(db, "_xyz.Widget")

    abc_widget_id = seed_draft_doc(db, "_abc", "Widget", %({"name": "w1"}))
    xyz_gadget_id = seed_draft_doc(db, "_xyz", "Gadget", %({"name": "g1"}))

    yield PreviewFixture.new(
      abc_widget_id: abc_widget_id,
      xyz_gadget_id: xyz_gadget_id,
      abc_view_id: abc_view_id,
      xyz_view_id: xyz_view_id,
    )
  end
end

# Shared preview context bound to `_abc`.
def preview_ctx : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.preview("account_1", "_abc")
end

module Facet::RBAC
  # Integration specs for the preview-mode capability path.
  #
  # The preview principal bypasses the role/permission system entirely:
  # authorization is reduced to one rule — the target (domain, doc_type)
  # must live inside the bound draft domain, with a read-only carve-out
  # for the draft's own `core.DocumentView` / `core.CollectionView`
  # children so the live app can render listing tabs and templates.
  describe PreviewEnforcer do
    # ── In-scope draft documents ─────────────────────────────────────────

    describe ".authorizes? — in-scope draft documents" do
      it "allows create on the draft's own doctype" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "create", "_abc", "Widget", nil, preview_ctx).should be_true
          end
        end
      end

      it "allows read on a draft document id" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "_abc", "Widget", f.abc_widget_id, preview_ctx).should be_true
          end
        end
      end

      it "allows update on a draft document id" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "update", "_abc", "Widget", f.abc_widget_id, preview_ctx).should be_true
          end
        end
      end

      it "allows delete on a draft document id" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "delete", "_abc", "Widget", f.abc_widget_id, preview_ctx).should be_true
          end
        end
      end

      it "allows a named action on a draft document id" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "promote", "_abc", "Widget", f.abc_widget_id, preview_ctx).should be_true
          end
        end
      end
    end

    # ── Out-of-scope domains ────────────────────────────────────────────

    describe ".authorizes? — cross-domain denials" do
      it "denies read on a different draft's document (no cross-draft leak)" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "_xyz", "Gadget", f.xyz_gadget_id, preview_ctx).should be_false
          end
        end
      end

      it "denies create on a different draft's doctype" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "create", "_xyz", "Gadget", nil, preview_ctx).should be_false
          end
        end
      end

      it "denies read on a live-domain document (no live-data leaking through preview)" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "live", "Order", "any_id", preview_ctx).should be_false
          end
        end
      end
    end

    # ── Schema authoring ───────────────────────────────────────────────

    describe ".authorizes? — schema authoring" do
      it "denies update on core.DocType (schema edits go through the Builder)" do
        with_preview_fixture do |_f|
          with_db do |db|
            # The draft's own doctype definition row — preview is data-only;
            # the row is under `core` and the action is a write.
            PreviewEnforcer.authorizes?(db, "update", "core", "DocType", "_abc.Widget", preview_ctx).should be_false
          end
        end
      end

      it "denies delete on core.DocType" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "delete", "core", "DocType", "_abc.Widget", preview_ctx).should be_false
          end
        end
      end

      it "denies update on core.Domain" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "update", "core", "Domain", "_abc", preview_ctx).should be_false
          end
        end
      end
    end

    # ── Schema-row reads (single-doc carve-out) ────────────────────────

    describe ".authorizes? — schema-row reads" do
      it "allows read on the bound draft's core.Domain row by id" do
        with_preview_fixture do |_f|
          with_db do |db|
            # The live dashboard's fall-back fetch when entering `/_abc`
            # during preview issues `GET /Api/core/Domain/_abc`. Without
            # the single-doc carve-out the default `domain == preview_domain`
            # rule denies (the draft id is the row's id, not its `domain`).
            PreviewEnforcer.authorizes?(db, "read", "core", "Domain", "_abc", preview_ctx).should be_true
          end
        end
      end

      it "denies read on another draft's core.Domain row (cross-draft leak guard)" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "Domain", "_xyz", preview_ctx).should be_false
          end
        end
      end

      it "allows read on the bound draft's core.DocType definition row by id" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "DocType", "_abc.Widget", preview_ctx).should be_true
          end
        end
      end

      it "denies read on another draft's core.DocType row (cross-draft leak guard)" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "DocType", "_xyz.Gadget", preview_ctx).should be_false
          end
        end
      end

      it "denies read on a core.DocType row whose content.domain does not match the draft" do
        with_preview_fixture do |_f|
          with_db do |db|
            # `live.Order` is a real `core.DocType` row, but its declared
            # domain is `live` — a preview principal bound to `_abc` cannot
            # read it; the live app must not surface live-domain schema rows.
            PreviewEnforcer.authorizes?(db, "read", "core", "DocType", "live.Order", preview_ctx).should be_false
          end
        end
      end

      it "denies read on an unknown core.DocType id (fail closed, non-disclosing)" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "DocType", "_abc.Nonexistent", preview_ctx).should be_false
          end
        end
      end
    end

    # ── View-template children of `core.DocType` ───────────────────────

    describe ".authorizes? — view-template children" do
      it "allows read on a DocumentView whose parent belongs to the draft" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "DocumentView", f.abc_view_id, preview_ctx).should be_true
          end
        end
      end

      it "allows read on a CollectionView whose parent belongs to the draft" do
        with_preview_fixture do |_f|
          with_db do |db|
            # `core.CollectionView` rows are children of `core.DocType` the
            # same way DocumentView rows are; the enforcer treats both via
            # `PRIVATE_SCHEMA_DOCTYPES`. Write a CollectionView row directly
            # so we exercise the CollectionView branch explicitly.
            cv_id = Facet::Util::ScriptHelpers.ulid
            Facet::Mutation::Client.create(
              db, "core", "CollectionView",
              doc_id: cv_id,
              content: %({"surface": "table"}),
              meta: %({"parent_id": "_abc.Widget"}),
              actioner_id: "system",
            )
            PreviewEnforcer.authorizes?(db, "read", "core", "CollectionView", cv_id, preview_ctx).should be_true
          end
        end
      end

      it "denies read on a DocumentView whose parent belongs to another draft" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "read", "core", "DocumentView", f.xyz_view_id, preview_ctx).should be_false
          end
        end
      end

      it "denies create on core.DocumentView (view authoring is a Builder action)" do
        with_preview_fixture do |_f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "create", "core", "DocumentView", nil, preview_ctx).should be_false
          end
        end
      end

      it "denies update on core.DocumentView (template edits go through the Builder)" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "update", "core", "DocumentView", f.abc_view_id, preview_ctx).should be_false
          end
        end
      end

      it "denies delete on core.DocumentView" do
        with_preview_fixture do |f|
          with_db do |db|
            PreviewEnforcer.authorizes?(db, "delete", "core", "DocumentView", f.abc_view_id, preview_ctx).should be_false
          end
        end
      end

      it "denies read on a DocumentView whose parent_id has no matching core.DocType row" do
        with_preview_fixture do |_f|
          with_db do |db|
            orphan_id = seed_draft_doc(db, "core", "DocumentView", %({"kind": "view"}))
            PreviewEnforcer.authorizes?(db, "read", "core", "DocumentView", orphan_id, preview_ctx).should be_false
          end
        end
      end
    end

    # ── Lists ───────────────────────────────────────────────────────────

    describe ".list_where_clauses" do
      it "returns no restriction for an in-scope draft doctype list" do
        with_preview_fixture do |_f|
          with_db do |db|
            clauses, params = PreviewEnforcer.list_where_clauses(db, "_abc", "Widget", preview_ctx)
            clauses.should be_empty
            params.should be_empty
          end
        end
      end

      it "returns 1=0 for an out-of-scope domain list" do
        with_preview_fixture do |_f|
          with_db do |db|
            clauses, _ = PreviewEnforcer.list_where_clauses(db, "live", "Order", preview_ctx)
            clauses.should eq(["1=0"])
          end
        end
      end

      it "returns a `content->>'domain' = $N` clause for a core.DocType list (so the live
         registry sees only the draft's doctypes)" do
        with_preview_fixture do |_f|
          with_db do |db|
            clauses, params = PreviewEnforcer.list_where_clauses(db, "core", "DocType", preview_ctx)
            clauses.should eq(["content->>'domain' = $1"])
            params.should eq(["_abc"])
          end
        end
      end

      it "returns an `id = $N` clause for a core.Domain list (so the live nav surfaces only the draft)" do
        with_preview_fixture do |_f|
          with_db do |db|
            clauses, params = PreviewEnforcer.list_where_clauses(db, "core", "Domain", preview_ctx)
            clauses.should eq(["id = $1"])
            params.should eq(["_abc"])
          end
        end
      end

      it "returns no restriction for a core.DocumentView list (the parent_id filter scopes the rows)" do
        with_preview_fixture do |_f|
          with_db do |db|
            clauses, params = PreviewEnforcer.list_where_clauses(db, "core", "DocumentView", preview_ctx)
            clauses.should be_empty
            params.should be_empty
          end
        end
      end
    end

    # ── ReadEnforcer.readable_doctypes (B-99) ──────────────────────────

    # `readable_doctypes` fans out the cross-doctype read surfaces
    # (`Document::Backrefs`, MCP `search_documents`). `AuthContext#can?`
    # raises on a preview principal by contract, so the enumeration must
    # branch on `preview?` — a backrefs call during preview 500'd here.
    describe ".readable_doctypes — preview principal" do
      it "returns only the bound draft's doctypes and raises nothing" do
        with_preview_fixture do |_f|
          with_db do |db|
            result = ReadEnforcer.readable_doctypes(db, preview_ctx)
            result.should eq([{"_abc", "Widget"}])
          end
        end
      end

      it "excludes other drafts' and live domains' doctypes" do
        with_preview_fixture do |_f|
          with_db do |db|
            pairs = ReadEnforcer.readable_doctypes(db, preview_ctx)
            pairs.map(&.[0]).should_not contain("_xyz")
            pairs.map(&.[0]).should_not contain("live")
          end
        end
      end
    end
  end
end
