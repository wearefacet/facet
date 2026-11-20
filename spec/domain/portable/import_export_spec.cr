# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "file_utils"

require "../../../src/domain"
require "../../../src/domain/portable"
require "../../../src/doctype"
require "../../../src/doctype/seed"
require "../../../src/document"
require "../../../src/mutation/client"
require "../../../src/rbac"

# Specs for `Domain::Portable::Export` and `Import`. The two services are
# exercised together because the natural round-trip is "export a domain,
# import it elsewhere" — the export's output is the import's input.
#
# Each example re-seeds the core doctypes (`core.DocType`, `core.Domain`,
# `core.DocumentView`, `core.CollectionView`) since the global per-spec
# truncation wipes them. The fixture used as the export source is a small
# `crm`-shaped domain created inline rather than the full `data/fixtures`
# tree — the goal is structural correctness, not data-volume coverage.

# Re-registers the core doctypes that the global truncation wiped.
def portable_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Creates a small live domain `name` with one doctype, one DocumentView
# (`kind: view`), one general (shared) CollectionView, and one personal
# CollectionView. The personal view must NOT appear in the export.
def portable_seed_crm_shaped_domain(db, name : String, widget_color : String = "blue")
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "test #{name}", "color": "#{widget_color}"}),
    actioner_id: "system:test",
  )

  widget_def = %({
    "doctype": "Widget",
    "domain": "#{name}",
    "schema_version": 1,
    "search": "{{ content.domain }}.{{ content.doctype }} {{ name }}",
    "fields": {
      "name": {"type": "string"},
      "color": {"type": "string"}
    }
  })
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: widget_def,
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "DocumentView",
    content: %({"parent_doctype": "#{name}.Widget", "kind": "view", "template": {"layout": "single"}}),
    meta: %({"parent_id": "#{name}.Widget"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "CollectionView",
    content: %({"name": "All", "surface": "table", "config": {"columns": [{"key": "name"}]}}),
    meta: %({"parent_id": "#{name}.Widget"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "CollectionView",
    content: %({"name": "My Personal", "surface": "table", "config": {}, "owner_id": "iam.Account.account_alice"}),
    meta: %({"parent_id": "#{name}.Widget"}),
    actioner_id: "system:test",
  )
end

# Creates a small `name` domain with two doctypes: `Widget` (aggregate
# root) and `WidgetNote` (composition child). `WidgetNote` references its
# parent via a `reference` field whose value is a qualified document id
# (`<name>.Widget.<id>`), so a `--into` rename must rewrite both the
# document ids and every embedded reference token.
def portable_seed_doc_shaped_domain(db, name : String)
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "doc test #{name}", "color": "#abc123"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: %({
      "doctype": "Widget",
      "domain": "#{name}",
      "schema_version": 1,
      "display_name": "{{ name }}",
      "fields": {
        "name": {"type": "string"}
      }
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.WidgetNote",
    content: %({
      "doctype": "WidgetNote",
      "domain": "#{name}",
      "schema_version": 1,
      "display_name": "{{ widget }}",
      "fields": {
        "body": {"type": "string"},
        "widget": {"type": "reference", "doctype": "#{name}.Widget"}
      }
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, name, "Widget",
    doc_id: "#{name}.Widget.1",
    content: %({"name": "Acme Widget"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, name, "WidgetNote",
    doc_id: "#{name}.Widget.note_a1",
    content: %({"body": "hello", "widget": "#{name}.Widget.1"}),
    meta: %({"parent_id": "#{name}.Widget.note_a1"}),
    actioner_id: "system:test",
  )
end

describe "Domain::Portable end-to-end" do
  # ── Export ──────────────────────────────────────────────────────────

  describe "Export" do
    it "captures the domain, doctypes, document views, and general collection views" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "exporttest")

        result = Facet::Domain::Portable::Export.call(db, "exporttest")
        result.should be_a(Facet::Domain::Portable::Export::Result)
        res = result.as(Facet::Domain::Portable::Export::Result)
        bundle = res.bundle

        bundle.source_domain.should eq("exporttest")
        bundle.domain.content["color"].as_s.should eq("blue")
        bundle.doctypes.size.should eq(1)
        bundle.doctypes[0][:doctype].should eq("exporttest.Widget")
        bundle.document_views["exporttest.Widget"].size.should eq(1)
        bundle.document_views["exporttest.Widget"][0][:kind].should eq("view")
        bundle.collection_views["exporttest.Widget"].size.should eq(1)
        bundle.collection_views["exporttest.Widget"][0].entry.content["name"].as_s.should eq("All")
        res.document_view_count.should eq(1)
        res.collection_view_count.should eq(1)
      end
    end

    it "refuses to export a draft domain" do
      with_db do |db|
        portable_reseed_core(db)

        # Create a draft domain the long way — writes the `draft: true` flag
        # directly via Mutation::Client.create on the core.Domain doctype.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "draftdemo",
          content: %({"description": "draft domain", "draft": true}),
          actioner_id: "system:test",
        )

        result = Facet::Domain::Portable::Export.call(db, "draftdemo")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("draft")
      end
    end

    it "returns a 404 when the domain does not exist" do
      with_db do |db|
        portable_reseed_core(db)
        result = Facet::Domain::Portable::Export.call(db, "nonexistent")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end
  end

  # ── Import ──────────────────────────────────────────────────────────

  describe "Import" do
    it "creates the target domain on fresh import" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "targetdomain")
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)
        res.domain.should eq("targetdomain")
        res.created.should be_true
        res.doctypes_created.should eq(1)
        res.document_views_created.should eq(1)
        res.collection_views_created.should eq(1)

        # The target doctype carries the rewritten domain field.
        widget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "targetdomain.Widget")
        widget.content["domain"].as_s.should eq("targetdomain")

        # B-78: the import writes `core.DocType` rows through the raw
        # mutation path, so it must stage the projection GUCs itself — an
        # unstaged GUC stores a NULL corpus, and the row then matches
        # nothing on `filters[search]`. The templates come from the stored
        # `core.DocType` definition, so the corpus is the row's qualified id
        # and the display label is the bare doctype name (no label set) —
        # the same way a pipeline write renders them.
        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'targetdomain.Widget'
          SQL
        row[:search].should eq("targetdomain.widget")
        row[:display_name].should eq("Widget")

        # The domain content color was preserved.
        domain = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "targetdomain")
        domain.content["color"].as_s.should eq("blue")
      end
    end

    it "re-stages the projection GUCs when a merge upsert changes a definition (B-78)" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle
        Facet::Domain::Portable::Import.call(db, bundle, into: "mergedomain")

        # Change only the doctype's description — a same-version edit the
        # merge branch accepts without a version bump — and re-import with
        # `merge: true`. The upsert must write the row through
        # `upsert_doctype_merge` AND re-stage the projection GUCs from the
        # new content, so the corpus keeps matching the stored definition.
        widget_entry = bundle.doctypes.first[:entry]
        changed_content = widget_entry.content.as_h.clone
        changed_content["description"] = JSON::Any.new("changed for merge")
        changed_bundle = Facet::Domain::Portable::Archive::Bundle.new(
          source_domain: bundle.source_domain,
          exported_at: bundle.exported_at,
          facet_version: bundle.facet_version,
          domain: bundle.domain,
          doctypes: [{doctype: bundle.doctypes.first[:doctype],
                      entry:   Facet::Domain::Portable::Archive::Entry.new(
                        content: JSON::Any.new(changed_content),
                        meta: widget_entry.meta,
                      )}],
          document_views: bundle.document_views,
          collection_views: bundle.collection_views,
          documents: bundle.documents,
        )
        result = Facet::Domain::Portable::Import.call(db, changed_bundle, into: "mergedomain", merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)
        result.as(Facet::Domain::Portable::Import::Result).doctypes_updated.should eq(1)

        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'mergedomain.Widget'
          SQL
        row[:search].should eq("mergedomain.widget")
        row[:display_name].should eq("Widget")
      end
    end

    it "refuses without --merge when the target domain already exists" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        # Pre-create the target domain so it already exists.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "sourcedomain",
          content: %({"description": "pre-existing"}),
          actioner_id: "system:test",
        )

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(409)
        err.message.should contain("--merge")
      end
    end

    it "creates the target domain when --merge is passed and the target does not exist" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "mergetarget", merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)
        res.domain.should eq("mergetarget")
        res.created.should be_true
        res.doctypes_created.should eq(1)
      end
    end

    it "is idempotent when re-importing an identical domain with --merge" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        # Round-trip into a fresh target.
        first = Facet::Domain::Portable::Import.call(db, bundle, into: "idemtarget")
        first.should be_a(Facet::Domain::Portable::Import::Result)
        first.as(Facet::Domain::Portable::Import::Result).doctypes_created.should eq(1)

        # Re-import the same bundle with --merge — no mutation should land.
        second = Facet::Domain::Portable::Import.call(db, bundle, into: "idemtarget", merge: true)
        second.should be_a(Facet::Domain::Portable::Import::Result)
        res = second.as(Facet::Domain::Portable::Import::Result)
        res.doctypes_created.should eq(0)
        res.doctypes_updated.should eq(0)
        res.doctypes_unchanged.should eq(1)
        res.document_views_created.should eq(0)
        res.document_views_updated.should eq(0)
        res.document_views_deleted.should eq(0)
      end
    end

    it "deletes a target-only document view when the merged bundle carries views for the doctype" do
      with_db do |db|
        # The counterpart of the iam-fixture rule: once the bundle carries
        # at least one view for the doctype, it owns the set — a live kind
        # the bundle does not carry converges away.
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "viewmerge")

        bundle = Facet::Domain::Portable::Export.call(db, "viewmerge")
          .as(Facet::Domain::Portable::Export::Result).bundle

        # Fresh import creates the doctype with its bundled `view` kind.
        Facet::Domain::Portable::Import.call(db, bundle, into: "viewmergetarget")
          .should be_a(Facet::Domain::Portable::Import::Result)

        # A view kind the bundle does not carry, authored on the target
        # after the first import.
        Facet::Mutation::Client.create(
          db, "core", "DocumentView",
          content: %({"parent_doctype": "viewmergetarget.Widget", "kind": "quickView", "template": {"layout": "single"}}),
          meta: %({"parent_id": "viewmergetarget.Widget"}),
          actioner_id: "system:test",
        )

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "viewmergetarget", merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)
        res.document_views_deleted.should eq(1)

        live = db.query_one(
          <<-SQL, as: Int64)
          SELECT count(*) FROM projections
          WHERE domain = 'core' AND doc_type = 'DocumentView'
            AND meta->>'parent_id' = 'viewmergetarget.Widget'
            AND deleted_at IS NULL
        SQL
        live.should eq(1)
      end
    end

    it "rejects a version-decrease when merging" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        # Build the bundle from v1 of the doctype.
        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        # Round-trip into a target — creates the v1 doctype.
        Facet::Domain::Portable::Import.call(db, bundle, into: "vdtarget")
          .should be_a(Facet::Domain::Portable::Import::Result)

        # Now bump the target's doctype to v2 — the bundle's v1 will then
        # decrease, which the version gate must reject.
        Facet::Database.with_transaction do |txn|
          Facet::Mutation::Client.update(
            txn, "core", "DocType", "vdtarget.Widget",
            diff_json: %({"set": [{"path": ["schema_version"], "value": 2}]}),
            actioner_id: "system:test",
          )
        end
        Facet::Doctype::DefinitionStore.cache.clear

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "vdtarget", merge: true)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("schema_version cannot decrease")
      end
    end

    it "rejects a bundle whose core.Domain has draft=true (defense-in-depth)" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "sourcedomain")

        bundle = Facet::Domain::Portable::Export.call(db, "sourcedomain")
          .as(Facet::Domain::Portable::Export::Result).bundle

        # Tamper: set `draft: true` on the bundled domain entry. This never
        # happens via Export (it refuses drafts at export time), but a
        # hand-crafted bundle could carry it.
        tampered = Facet::Domain::Portable::Archive::Bundle.new(
          source_domain: bundle.source_domain,
          exported_at: bundle.exported_at,
          facet_version: bundle.facet_version,
          domain: Facet::Domain::Portable::Archive::Entry.new(
            JSON.parse(%({"description": "evil", "draft": true})),
            bundle.domain.meta,
          ),
          doctypes: bundle.doctypes,
          document_views: bundle.document_views,
          collection_views: bundle.collection_views,
        )

        result = Facet::Domain::Portable::Import.call(db, tampered, into: "eviltarget")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("draft")
      end
    end

    it "round-trips through a directory on disk" do
      path = File.join(Dir.tempdir, "facet-portable-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(path)
      begin
        with_db do |db|
          portable_reseed_core(db)
          portable_seed_crm_shaped_domain(db, "roundtrip")

          bundle = Facet::Domain::Portable::Export.call(db, "roundtrip")
            .as(Facet::Domain::Portable::Export::Result).bundle
          written = Facet::Domain::Portable::Archive.write(bundle, path)

          File.exists?(File.join(written, "bundle.yml")).should be_true
          loaded = Facet::Domain::Portable::Archive.read(written)

          result = Facet::Domain::Portable::Import.call(db, loaded, into: "roundtripclone")
          result.should be_a(Facet::Domain::Portable::Import::Result)
          res = result.as(Facet::Domain::Portable::Import::Result)
          res.doctypes_created.should eq(1)
          res.document_views_created.should eq(1)
          res.collection_views_created.should eq(1)
        end
      ensure
        FileUtils.rm_r(path) if Dir.exists?(path)
      end
    end

    it "externalizes doctype and hook scripts to sidecars on disk and round-trips them" do
      path = File.join(Dir.tempdir, "facet-portable-ext-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(path)
      begin
        with_db do |db|
          portable_reseed_core(db)

          # A doctype with a lifecycle script.
          lua = "local export = {}\nfunction export.create(ctx) ctx.root.ok = true end\nreturn export\n"
          Facet::Mutation::Client.create(
            db, "core", "Domain",
            doc_id: "extsrc",
            content: %({"description": "ext source", "color": "#123456"}),
            actioner_id: "system:test",
          )
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "extsrc.Widget",
            content: %({
              "doctype": "Widget",
              "domain": "extsrc",
              "schema_version": 1,
              "search": "{{ display_name }}",
              "fields": {},
              "script": #{lua.to_json}
            }),
            meta: %({"parent_id": "extsrc"}),
            actioner_id: "system:test",
          )

          bundle = Facet::Domain::Portable::Export.call(db, "extsrc")
            .as(Facet::Domain::Portable::Export::Result).bundle
          written = Facet::Domain::Portable::Archive.write(bundle, path)

          # The doctype script was externalized to a co-located sidecar.
          sidecar = File.join(written, "doctypes", "extsrc.Widget.lua")
          File.exists?(sidecar).should be_true
          File.read(sidecar).should eq(lua)
          File.read(File.join(written, "doctypes", "extsrc.Widget.yml"))
            .should contain("script: !read_file extsrc.Widget.lua")

          # Importing the on-disk bundle restores the script.
          loaded = Facet::Domain::Portable::Archive.read(written)
          result = Facet::Domain::Portable::Import.call(db, loaded, into: "exttgt")
          result.should be_a(Facet::Domain::Portable::Import::Result)
          result.as(Facet::Domain::Portable::Import::Result).doctypes_created.should eq(1)

          widget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "exttgt.Widget")
          widget.content["script"].as_s.should eq(lua)
        end
      ensure
        FileUtils.rm_r(path) if Dir.exists?(path)
      end
    end

    # ── Documents (`--with-documents`) ────────────────────────────────────

    it "does NOT capture documents by default" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "nodefault")

        result = Facet::Domain::Portable::Export.call(db, "nodefault")
        result.should be_a(Facet::Domain::Portable::Export::Result)
        res = result.as(Facet::Domain::Portable::Export::Result)
        res.document_count.should eq(0)
        res.bundle.documents.should be_empty
      end
    end

    it "captures documents with with_documents: true and excludes core.*" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "capdocs")

        result = Facet::Domain::Portable::Export.call(db, "capdocs", with_documents: true)
        result.should be_a(Facet::Domain::Portable::Export::Result)
        res = result.as(Facet::Domain::Portable::Export::Result)
        res.document_count.should eq(2)
        bundle = res.bundle

        # Two doctypes carry documents.
        bundle.documents.size.should eq(2)
        bundle.documents["capdocs.Widget"].size.should eq(1)
        bundle.documents["capdocs.WidgetNote"].size.should eq(1)

        # Definition doctypes (core.*) are never captured as documents —
        # export's `fetch_documents` skips the core domain entirely.
        bundle.documents["core.DocType"]?.should be_nil
        bundle.documents["core.DocumentView"]?.should be_nil
        bundle.documents["core.Domain"]?.should be_nil
      end
    end

    it "round-trips documents on a fresh import" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "rtsource")

        bundle = Facet::Domain::Portable::Export.call(db, "rtsource", with_documents: true)
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "rttarget")
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)
        res.created.should be_true
        res.doctypes_created.should eq(2)
        res.documents_created.should eq(2)

        # The Widget document exists under the target identity with its
        # content intact.
        w = Facet::Mutation::Client.fetch_projection(db, "rttarget", "Widget", "rttarget.Widget.1")
        w.content["name"].as_s.should eq("Acme Widget")

        # The child document was created with its parent linkage intact.
        n = Facet::Mutation::Client.fetch_projection(db, "rttarget", "WidgetNote", "rttarget.Widget.note_a1")
        n.content["body"].as_s.should eq("hello")
        n.content["widget"].as_s.should eq("rttarget.Widget.1")
      end
    end

    it "rewrites document ids and reference tokens under --into" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "rewritesrc")

        bundle = Facet::Domain::Portable::Export.call(db, "rewritesrc", with_documents: true)
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "rewritetgt")
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)
        res.documents_created.should eq(2)

        # Both documents exist under the target identity — the leading
        # `rewritesrc.` segment was rewritten to `rewritetgt.`.
        Facet::Mutation::Client.fetch_projection(db, "rewritetgt", "Widget", "rewritetgt.Widget.1")
          .content["name"].as_s.should eq("Acme Widget")
        note = Facet::Mutation::Client.fetch_projection(db, "rewritetgt", "WidgetNote", "rewritetgt.Widget.note_a1")
        note.content["widget"].as_s.should eq("rewritetgt.Widget.1")
      end
    end

    it "relinks same-domain reference targets in doctype definitions under --into" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "relinksrc")

        bundle = Facet::Domain::Portable::Export.call(db, "relinksrc")
          .as(Facet::Domain::Portable::Export::Result).bundle

        # The bundle's `relinksrc.WidgetNote` declares
        # `widget: {type: reference, doctype: relinksrc.Widget}` — the
        # definition stored on the target must declare `relinktgt.Widget`.
        Facet::Domain::Portable::Import.call(db, bundle, into: "relinktgt")
          .should be_a(Facet::Domain::Portable::Import::Result)

        note_def = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "relinktgt.WidgetNote")
        note_def.content["fields"]["widget"]["doctype"].as_s.should eq("relinktgt.Widget")
      end
    end

    it "round-trips documents through disk (directory layout)" do
      path = File.join(Dir.tempdir, "facet-portable-docs-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(path)
      begin
        with_db do |db|
          portable_reseed_core(db)
          portable_seed_doc_shaped_domain(db, "disksrc")

          bundle = Facet::Domain::Portable::Export.call(db, "disksrc", with_documents: true)
            .as(Facet::Domain::Portable::Export::Result).bundle
          written = Facet::Domain::Portable::Archive.write(bundle, path)

          # The documents directory was written next to doctypes/.
          File.directory?(File.join(written, "documents")).should be_true
          File.exists?(File.join(written, "documents", "disksrc.Widget", "disksrc.Widget.1.yml")).should be_true

          loaded = Facet::Domain::Portable::Archive.read(written)
          loaded.documents.size.should eq(2)

          result = Facet::Domain::Portable::Import.call(db, loaded, into: "disktgt")
          result.should be_a(Facet::Domain::Portable::Import::Result)
          result.as(Facet::Domain::Portable::Import::Result).documents_created.should eq(2)
        end
      ensure
        FileUtils.rm_r(path) if Dir.exists?(path)
      end
    end

    it "is idempotent for documents on re-import with --merge" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_doc_shaped_domain(db, "idemsrc")

        bundle = Facet::Domain::Portable::Export.call(db, "idemsrc", with_documents: true)
          .as(Facet::Domain::Portable::Export::Result).bundle

        Facet::Domain::Portable::Import.call(db, bundle, into: "idemtgt")
          .as(Facet::Domain::Portable::Import::Result).documents_created.should eq(2)

        # Re-import the same bundle with --merge — no document should be
        # re-created (every id already exists on the target).
        second = Facet::Domain::Portable::Import.call(db, bundle, into: "idemtgt", merge: true)
          .as(Facet::Domain::Portable::Import::Result)
        second.documents_created.should eq(0)
      end
    end

    it "refuses a merge bundle whose document violates a unique constraint (B-32)" do
      with_db do |db|
        portable_reseed_core(db)

        # Source domain with a unique field and one row.
        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: "usrc",
          content: %({"description": "u", "color": "#abc123"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "usrc.Widget",
          content: %({"doctype": "Widget", "domain": "usrc", "schema_version": 1, "search": "{{ reg_no }}", "fields": {"reg_no": {"type": "string", "unique": true}}}),
          meta: %({"parent_id": "usrc"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "usrc", "Widget", content: %({"reg_no": "TR-101"}),
          actioner_id: "system:test",
        )

        bundle = Facet::Domain::Portable::Export.call(db, "usrc", with_documents: true)
          .as(Facet::Domain::Portable::Export::Result).bundle

        # Fresh import lands the row.
        Facet::Domain::Portable::Import.call(db, bundle, into: "utgt")
          .as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)

        # A colliding bundle entry: different document id, same reg_no.
        src_entry = bundle.documents["usrc.Widget"].first
        bundle.documents["usrc.Widget"] << Facet::Domain::Portable::Archive::DocumentEntry.new(
          "usrc.Widget.collide", src_entry.entry)

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "utgt", merge: true)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("reg_no")
        err.message.should contain("TR-101")
        err.details.not_nil!.first.field.should eq("reg_no")

        # The colliding row never landed — exactly one Widget row.
        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'utgt' AND doc_type = 'Widget' AND deleted_at IS NULL",
          as: Int64)
        count.should eq(1)
      end
    end

    it "files an inactive grant ticket for a bundled cross-domain replicate edge (B-10)" do
      with_db do |db|
        portable_reseed_core(db)

        # Producer domain with one doctype carrying the source field.
        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: "psrc",
          content: %({"description": "p", "color": "#111111"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "psrc.PDoc",
          content: %({"doctype": "PDoc", "domain": "psrc", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}, "status": {"type": "string", "tags": ["ops"]}}}),
          meta: %({"parent_id": "psrc"}),
          actioner_id: "system:test",
        )

        # Consumer domain whose doctype replicates from the producer.
        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: "csrc",
          content: %({"description": "c", "color": "#222222"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "csrc.CDoc",
          # The replica carries the source field's `ops` tag — the tag-superset
          # invariant (B-271) refuses a replica that would leak a tagged source
          # value to roles the source hides it from.
          content: %({"doctype": "CDoc", "domain": "csrc", "schema_version": 1, "search": "{{ pstatus }}", "fields": {"pdoc": {"type": "reference", "doctype": "psrc.PDoc"}, "pstatus": {"type": "string", "tags": ["ops"], "replicate": {"via": "pdoc", "field": "status"}}}}),
          meta: %({"parent_id": "csrc"}),
          actioner_id: "system:test",
        )

        bundle = Facet::Domain::Portable::Export.call(db, "csrc")
          .as(Facet::Domain::Portable::Export::Result).bundle

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "ctgt")
        result.should be_a(Facet::Domain::Portable::Import::Result)
        res = result.as(Facet::Domain::Portable::Import::Result)

        # The ticket surfaced on the result — producer reached, filed
        # inactive (the import is a system actor; acceptance stays
        # explicit).
        res.grant_tickets.size.should eq(1)
        ticket = res.grant_tickets.first
        ticket.producer.should eq("psrc")
        ticket.filed.should be_true
        ticket.active.should be_false

        # The grant document exists under the producer, inactive, naming
        # the consumer and the producer doctype with the source field's
        # tags.
        row = db.query_one?("
          SELECT content->>'consumer_domain', content->>'active', content->'resources'
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DomainGrant' AND deleted_at IS NULL
            AND meta->>'parent_id' = 'psrc'",
          as: {String, String, JSON::Any})
        row.should_not be_nil
        consumer, active, resources = row.not_nil!
        consumer.should eq("core.Domain.ctgt")
        active.should eq("false")
        resources.to_s.should contain("PDoc")
        resources.to_s.should contain("ops")
      end
    end

    it "still merges a non-colliding document bundle" do
      with_db do |db|
        portable_reseed_core(db)

        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: "umsrc",
          content: %({"description": "u", "color": "#abc123"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "umsrc.Widget",
          content: %({"doctype": "Widget", "domain": "umsrc", "schema_version": 1, "search": "{{ reg_no }}", "fields": {"reg_no": {"type": "string", "unique": true}}}),
          meta: %({"parent_id": "umsrc"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "umsrc", "Widget", content: %({"reg_no": "TR-101"}),
          actioner_id: "system:test",
        )

        bundle = Facet::Domain::Portable::Export.call(db, "umsrc", with_documents: true)
          .as(Facet::Domain::Portable::Export::Result).bundle

        Facet::Domain::Portable::Import.call(db, bundle, into: "umtgt")
          .as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)

        # A non-colliding bundle entry merges cleanly.
        src_entry = bundle.documents["umsrc.Widget"].first
        bundle.documents["umsrc.Widget"] << Facet::Domain::Portable::Archive::DocumentEntry.new(
          "umsrc.Widget.fresh",
          Facet::Domain::Portable::Archive::Entry.new(JSON.parse(%({"reg_no": "TR-202"})), src_entry.entry.meta),
        )

        result = Facet::Domain::Portable::Import.call(db, bundle, into: "umtgt", merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)
        result.as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'umtgt' AND doc_type = 'Widget' AND deleted_at IS NULL",
          as: Int64)
        count.should eq(2)
      end
    end
  end

  # ── Multi-domain CLI helpers ──────────────────────────────────────────

  describe Facet::Domain::Portable::CLI do
    describe ".expand_comma_list" do
      it "accepts whitespace-separated values" do
        Facet::Domain::Portable::CLI.expand_comma_list(["crm", "hr", "production"])
          .should eq(["crm", "hr", "production"])
      end

      it "accepts one comma-separated token" do
        Facet::Domain::Portable::CLI.expand_comma_list(["crm,hr,production"])
          .should eq(["crm", "hr", "production"])
      end

      it "accepts a mix of comma and whitespace separators" do
        Facet::Domain::Portable::CLI.expand_comma_list(["crm,hr", "production,identity"])
          .should eq(["crm", "hr", "production", "identity"])
      end

      it "strips whitespace around every comma-separated token" do
        Facet::Domain::Portable::CLI.expand_comma_list([" crm , hr ,production "])
          .should eq(["crm", "hr", "production"])
      end

      it "de-duplicates while preserving order" do
        Facet::Domain::Portable::CLI.expand_comma_list(["crm,hr", "crm,production"])
          .should eq(["crm", "hr", "production"])
      end

      it "rejects empty tokens" do
        Facet::Domain::Portable::CLI.expand_comma_list(["crm,,hr, "])
          .should eq(["crm", "hr"])
      end
    end
  end

  # ── End-to-end multi-domain loop (mirrors what CLI.run_export/run_import ─
  # exactly) ────────────────────────────────────────────────────────────────

  describe "Multi-domain export/import loop" do
    it "exports two domains and imports them back aligned with --into" do
      with_db do |db|
        portable_reseed_core(db)
        portable_seed_crm_shaped_domain(db, "multi_a")
        portable_seed_crm_shaped_domain(db, "multi_b", widget_color: "green")

        # The loop the CLI runs: one Export call + one Archive.write per
        # domain, outputs fanned out into a shared directory.
        out_dir = File.join(Dir.tempdir, "facet-multi-domain-spec-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(out_dir)
        begin
          ["multi_a", "multi_b"].each do |domain|
            bundle = Facet::Domain::Portable::Export.call(db, domain)
              .as(Facet::Domain::Portable::Export::Result).bundle
            Facet::Domain::Portable::Archive.write(bundle, File.join(out_dir, "#{domain}.facet-domain"))
          end

          # Aligned --into list: multi_a -> tgt-a, multi_b -> tgt-b. Dash
          # names: the import authoring gate (B-302) enforces the same
          # domain-name grammar the REST door does, and an underscore is
          # never legal in a live domain name.
          into_targets = ["tgt-a", "tgt-b"]
          ["multi_a", "multi_b"].each_with_index do |domain, i|
            bundle = Facet::Domain::Portable::Archive.read(
              File.join(out_dir, "#{domain}.facet-domain"))
            result = Facet::Domain::Portable::Import.call(db, bundle, into: into_targets[i])
            result.should be_a(Facet::Domain::Portable::Import::Result)
            result.as(Facet::Domain::Portable::Import::Result)
              .domain.should eq(into_targets[i])
          end

          # Each target received its own Widget doctype, rewritten to the
          # target domain field.
          ["tgt-a", "tgt-b"].each do |target|
            dt = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{target}.Widget")
            dt.content["domain"].as_s.should eq(target)
          end
        ensure
          FileUtils.rm_r(out_dir) if Dir.exists?(out_dir)
        end
      end
    end
  end

  describe "importing the crm fixture bundle" do
    it "populates the search column so a full domain value matches" do
      with_db do |db|
        portable_reseed_core(db)

        bundle = Facet::Domain::Portable::Archive.read(data_path("crm.facet-domain"))
        result = Facet::Domain::Portable::Import.call(db, bundle)
        result.should be_a(Facet::Domain::Portable::Import::Result)

        # The crm.Company doctype declares `search: "{{ name }} {{ domain_name }}"`
        # and the fixture crm.Company.1 has domain_name "acme.com". The full
        # domain value (with a literal dot) must match that company.
        list = Facet::Document::List.call(
          db, "crm", "Company",
          filters: {"search" => JSON::Any.new("acme.com")},
          auth_context: Facet::RBAC::AuthContext.system
        )
        list.should be_a(Facet::Document::List::Result)
        result_list = list.as(Facet::Document::List::Result)
        result_list.items.size.should eq(1)
        result_list.items.first.content["name"].as_s.should eq("Acme Corp")
      end
    end

    it "stamps the derived per-field operators onto the stored definition" do
      with_db do |db|
        portable_reseed_core(db)

        # The raw-persist path (`Domain::Copy.upsert_doctype_definition`, the
        # import/publish branch) stores the bundle verbatim. The frontend
        # filter bar reads only the derived `operators` member
        # (`Doctype::Create`/`Update` stamp it on the authoring paths), so a
        # definition imported without it leaves every field non-filterable
        # in the UI. The persist must stamp the same member the struct
        # writer would.
        bundle = Facet::Domain::Portable::Archive.read(data_path("crm.facet-domain"))
        Facet::Domain::Portable::Import.call(db, bundle)

        content = Facet::Mutation::Client.fetch_content(db, "core", "DocType", "crm.Company")

        # `status` is an enum field declaring `filters: [equality]` → the
        # derived family is `[eq]` plus the enum `in` supplement.
        status = content["fields"]["status"]
        status["operators"].as_a.map(&.as_s).should eq(["eq", "in"])

        # `name` declares `filters: [equality, text_search]` → the families
        # de-duplicate in Operator declaration order.
        name = content["fields"]["name"]
        name["operators"].as_a.map(&.as_s).should eq(["eq", "match", "starts_with"])

        # A field without `filters` carries no derived member.
        content["fields"]["address"].as_h.has_key?("operators").should be_false
      end
    end

    it "re-import of the stamped bundle stays a no-op" do
      with_db do |db|
        portable_reseed_core(db)

        bundle = Facet::Domain::Portable::Archive.read(data_path("crm.facet-domain"))
        first_result = Facet::Domain::Portable::Import.call(db, bundle)
        first_result.should be_a(Facet::Domain::Portable::Import::Result)
        first = first_result.as(Facet::Domain::Portable::Import::Result)

        # The stamp rewrites the stored content relative to the bundle, so
        # the merge path must compare like-for-like — deriving the member on
        # the bundled content before the SHA-256 match, not only on the
        # create branch. Otherwise the second import "updates" every
        # doctype and each re-import drifts the mutation log.
        second_result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)
        second_result.should be_a(Facet::Domain::Portable::Import::Result)
        second = second_result.as(Facet::Domain::Portable::Import::Result)

        first.doctypes_created.should eq(second.doctypes_unchanged)
        second.doctypes_created.should eq(0)
        second.doctypes_updated.should eq(0)
      end
    end
  end

  describe "importing the iam fixture bundle" do
    it "merges into the seed-created iam domain with every doctype unchanged" do
      with_db do |db|
        # The dev flow: `IAM::Seed` pre-creates the iam doctypes from
        # `data/seeds/` (here: the same content, via the spec helper), then
        # `scripts/import-fixtures` merges this bundle on top. Pin the
        # bundle-seed sync: a seed edit without regenerating the bundle
        # would make some doctype drift, and the merge would either fail
        # the same-version field-removal gate (removed field) or silently
        # overwrite the seed side (removed `search` template / edited title
        # — presentation drift passes the shape gates but changes the
        # stored definition).
        seed_iam_doctypes(db)

        # The bundle's `production_editor` role carries `$mine` scopes on
        # `production.*` doctypes. The import authoring gate (B-277) enforces
        # the API rule those scopes must resolve — so the production bundle
        # must import first, the order `scripts/import-fixtures` has to use.
        production_bundle = Facet::Domain::Portable::Archive.read(data_path("production.facet-domain"))
        Facet::Domain::Portable::Import.call(db, production_bundle).should be_a(Facet::Domain::Portable::Import::Result)

        bundle = Facet::Domain::Portable::Archive.read(data_path("iam.facet-domain"))
        result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)

        merged = result.as(Facet::Domain::Portable::Import::Result)
        merged.doctypes_unchanged.should eq(3)
        merged.doctypes_created.should eq(0)
        merged.doctypes_updated.should eq(0)
      end
    end

    it "keeps the seed-created document views when the bundle carries none for the doctype" do
      with_db do |db|
        # The dev flow: `db_reset` seeds every core doctype — including the
        # `core.DocumentView` templates for the iam doctypes (the full seed
        # below creates them through the same `Doctype::Seed.seed` pass) —
        # then `scripts/import-fixtures` merges this bundle on top. The
        # bundle re-declares `iam.Account` / `iam.Roles` without carrying
        # their views; the merge must read the empty bundled set as "the
        # bundle states nothing", not as "delete everything live".
        portable_reseed_core(db)

        seed_views = db.query_one(
          <<-SQL, as: Int64)
          SELECT count(*) FROM projections
          WHERE domain = 'core' AND doc_type = 'DocumentView'
            AND meta->>'parent_id' = 'iam.Account'
            AND deleted_at IS NULL
        SQL
        seed_views.should be > 0

        # The bundle's role rows scope against `production.*` doctypes — the
        # import authoring gate (B-277) needs them registered, so the
        # production bundle imports first (see the sibling example).
        production_bundle = Facet::Domain::Portable::Archive.read(data_path("production.facet-domain"))
        Facet::Domain::Portable::Import.call(db, production_bundle).should be_a(Facet::Domain::Portable::Import::Result)

        bundle = Facet::Domain::Portable::Archive.read(data_path("iam.facet-domain"))
        result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)

        merged = result.as(Facet::Domain::Portable::Import::Result)
        merged.document_views_deleted.should eq(0)

        live_after = db.query_one(
          <<-SQL, as: Int64)
          SELECT count(*) FROM projections
          WHERE domain = 'core' AND doc_type = 'DocumentView'
            AND meta->>'parent_id' = 'iam.Account'
            AND deleted_at IS NULL
        SQL
        live_after.should eq(seed_views)
      end
    end
  end
end
