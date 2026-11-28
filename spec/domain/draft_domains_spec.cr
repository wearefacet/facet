# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/domain"
require "../../src/doctype"
require "../../src/doctype/check"
require "../../src/document"
require "../../src/rbac"
require "../../src/replication"
require "../../src/mutation/json_diff"
require "../replication/validator_spec" # brings this spec's describe blocks

# ── Helpers ─────────────────────────────────────────────────────────────────

# Re-registers the core.DocType definition for `core.Domain`. The global
# TRUNCATE before each example wipes the seeded `core.DocType` projection,
# so any spec that exercises `Document::Update.call` on `core.Domain` must
# re-create the definition first.
def seed_core_domain_doctype(db)
  defn_path = File.join(__DIR__, "..", "..", "data", "seeds", "core.Domain", "definition.yml")
  yaml = YAML.parse(File.read(defn_path))
  json_any = Facet::Doctype::YamlHelper.to_json_any(yaml)
  defn = Facet::Doctype::DoctypeDefinition.from_json(json_any)
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "core.Domain",
    content: defn.to_json,
    actioner_id: "system",
  )
  Facet::Doctype::DefinitionStore.invalidate("core.Domain")
end

# Creates a draft domain via the Draft module and returns its name.
def create_draft_domain(db, content = "{}")
  result = Facet::Domain::Draft.create(
    db, content,
    "system:test",
  )
  result.should be_a(Facet::Domain::Draft::Result)
  result.as(Facet::Domain::Draft::Result).projection.id
end

# Persists a doctype definition under the given draft domain by writing
# directly to core.DocType — bypasses Doctype::Create's domain-name regex
# (which rejects the `_` prefix) the same way Domain::Copy does.
def create_doctype_in_domain(db, domain, doctype, fields = nil)
  content = if fields
              %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": #{fields}})
            else
              %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": {}})
            end
  doc_id = "#{domain}.#{doctype}"
  mut = Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  {mut, doc_id}
end

# Creates a document under the (draft) domain + doctype.
def create_doc(db, domain, doctype, content = "{}")
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, domain, doctype,
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  doc_id
end

# Creates a `core.DocumentView` child of the qualified doctype id
# (e.g. `"_draftX.Widget"`). The parent link lives on `meta.parent_id`;
# `content.parent_doctype` mirrors it.
def create_document_view(db, doctype_id, kind = "table")
  Facet::Mutation::Client.create(
    db, "core", "DocumentView",
    content: %({"parent_doctype": "#{doctype_id}", "kind": "#{kind}", "template": {}}),
    meta: %({"parent_id": "#{doctype_id}"}),
    actioner_id: "system:test",
  )
end

# Creates a `core.CollectionView` child of the qualified doctype id.
# `owner_id` omitted → general (shared) view; set → personal view.
def create_collection_view(db, doctype_id, owner_id = nil)
  content = if owner_id
              %({"name": "v-#{unique_suffix}", "surface": "table", "owner_id": "#{owner_id}"})
            else
              %({"name": "v-#{unique_suffix}", "surface": "table"})
            end
  Facet::Mutation::Client.create(
    db, "core", "CollectionView",
    content: content,
    meta: %({"parent_id": "#{doctype_id}"}),
    actioner_id: "system:test",
  )
end

# Seeds one `doctype_indexes` tracking row for the domain and returns the
# number of tracking rows for the domain afterwards.
def seed_doctype_index_row(db, domain)
  db.exec(
    "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name) VALUES ($1, 'Widget', 'name', 'btree', 'idx-#{unique_suffix}')",
    domain,
  )
end

# Seeds a live domain (with one doctype + one document) and a draft derived
# from it via `Draft.create_from`, then overwrites the draft's doctype
# definition with the caller's shape. Returns the draft name.
#
# `live_fields` is the live doctype's fields. `draft_fields` / `draft_version` /
# `draft_migrations` / `draft_script` shape the draft's doctype definition
# relative to the live one (defaults: same fields, same version, no migrations).
def seed_live_and_draft(
  db,
  live_fields = %({"name": {"type": "string"}}),
  draft_fields = nil,
  draft_version = 1,
  draft_migrations = nil,
  draft_script = nil,
)
  draft_fields = draft_fields || live_fields

  ensure_domain(db, "orders")
  create_doctype_in_domain(db, "orders", "Widget", live_fields)
  create_doc(db, "orders", "Widget", %({"name": "alice"}))

  draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
  draft_result.should be_a(Facet::Domain::Draft::Result)
  draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

  # Overwrite the draft's Widget definition with the caller's shape.
  content = JSON.build do |j|
    j.object do
      j.field "doctype", "Widget"
      j.field "domain", draft
      j.field "schema_version", draft_version
      j.field "search", "{{ display_name }}"
      j.field "fields", JSON.parse(draft_fields)
      if draft_migrations
        j.field "migrations", JSON.parse(draft_migrations)
      end
      if draft_script
        j.field "script", draft_script
      end
    end
  end
  Facet::Mutation::Client.update(
    db, "core", "DocType", "#{draft}.Widget",
    diff_json: Facet::Mutation::JsonDiff.diff(
      Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Widget"),
      JSON.parse(content),
    ).to_json,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")
  draft
end

# Builds `core.Domain` content carrying one event hook. Every caller sets
# the hook's source domain to the publish target, so the grant-ticket scan
# sees a same-domain edge and files nothing.
private def domain_hooks_content(source_domain : String, hook_id = "notify-credit") : String
  %({"hooks": [{"id": "#{hook_id}", "kind": "event", "script": "local export = {}\\nfunction export.on_event(ctx) end\\nreturn export", "source": {"domain": "#{source_domain}"}}]})
end

module Facet::Domain
  describe Draft do
    describe ".create" do
      it "creates a draft core.Domain document with draft=true and a _ prefixed name" do
        with_db do |db|
          result = Draft.create(db, %({"description": "test draft"}), "user-1")

          result.should be_a(Draft::Result)
          res = result.as(Draft::Result)

          res.projection.id.should start_with("_")
          res.projection.content["draft"].raw.should be_true
          res.projection.content["description"].as_s.should eq("test draft")
        end
      end

      it "overwrites any draft field on the input body and forces draft=true" do
        with_db do |db|
          # Caller tries to escape draft mode by passing draft: false —
          # the system must force it to true.
          result = Draft.create(db, %({"draft": false}), "user-1")
          res = result.as(Draft::Result)
          res.projection.content["draft"].raw.should be_true
        end
      end

      it "overwrites any id/domain field on the input body" do
        with_db do |db|
          # Caller tries to pick their own name — must be ignored.
          result = Draft.create(db, %({"id": "evil", "domain": "evil"}), "user-1")
          res = result.as(Draft::Result)
          res.projection.id.should start_with("_")
          res.projection.id.should_not eq("evil")
        end
      end

      it "rejects an invalid JSON body" do
        with_db do |db|
          result = Draft.create(db, "not json", "user-1")
          result.should be_a(Facet::ServiceError)
          (result.as(Facet::ServiceError)).status.should eq(422)
        end
      end

      # B-307: the draft door writes through `Mutation::Client` directly,
      # so the `name` content field must be checked here — a value the
      # update door would reject must not land on the draft.
      it "rejects a name that fails the core.Domain pattern (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"name": "Bad Name!"}), "user-1")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          details = err.details.not_nil!
          details.any? { |e| e.field == "name" && e.code == "invalid_format" }.should be_true
        end
      end

      it "rejects a name that is not a string (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"name": 42}), "user-1")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.details.not_nil!.any? { |e| e.field == "name" }.should be_true
        end
      end

      it "accepts a name that satisfies the core.Domain pattern (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"name": "orders-2"}), "user-1")
          result.should be_a(Draft::Result)
          result.as(Draft::Result).projection.content["name"].as_s.should eq("orders-2")
        end
      end

      it "accepts a label next to the name (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"name": "orders-2", "label": "Orders"}), "user-1")
          result.should be_a(Draft::Result)
          res = result.as(Draft::Result)
          res.projection.content["name"].as_s.should eq("orders-2")
          res.projection.content["label"].as_s.should eq("Orders")
        end
      end

      it "rejects a label that is not a string (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"label": 42}), "user-1")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.details.not_nil!.any? { |e| e.field == "label" }.should be_true
        end
      end

      it "rejects a label longer than the definition's max (B-307)" do
        with_db do |db|
          seed_core_domain_doctype(db)

          result = Draft.create(db, %({"label": "#{"x" * 65}"}), "user-1")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.details.not_nil!.any? { |e| e.field == "label" }.should be_true
        end
      end
    end

    describe ".create_from" do
      it "copies a live domain's structure into a new draft with source_domain provenance" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            # Source live domain with a doctype + document data.
            ensure_domain(txn, "hr")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))
            create_doc(txn, "hr", "Employee", %({"name": "alice"}))

            result = Draft.create_from(txn, "hr", "user-1")

            result.should be_a(Draft::Result)
            res = result.as(Draft::Result)

            # New draft has a _-prefixed name, draft=true, source_domain provenance.
            res.projection.id.should start_with("_")
            res.projection.content["draft"].raw.should be_true
            res.projection.content["source_domain"].as_s.should eq("hr")
          end
        end
      end

      it "copies the doctype definitions but not the document data" do
        draft_name = uninitialized String
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "hr")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))
            create_doc(txn, "hr", "Employee", %({"name": "alice"}))
            create_doc(txn, "hr", "Employee", %({"name": "bob"}))

            result = Draft.create_from(txn, "hr", "user-1").as(Draft::Result)
            draft_name = result.projection.id
          end

          # Doctype definition copied under the draft domain.
          draft_def = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{draft_name}.Employee")
          draft_def.content["domain"].as_s.should eq(draft_name)
          draft_def.content["doctype"].as_s.should eq("Employee")

          # No document data copied — zero Employee documents under the draft.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = 'Employee'",
            draft_name, as: Int64)
          count.should eq(0)
        end
      end

      it "copies the doctype's DocumentView children into the draft" do
        draft_name = uninitialized String
        with_db do |db|
          # Re-seed core doctypes (core.DocType, core.DocumentView, core.Domain)
          # so DefinitionStore can resolve core.DocType's children → DocumentView.
          restore_seeded_baseline(db)
          Facet::Doctype::DefinitionStore.cache.clear

          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "hr")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))

            # Create two DocumentViews under hr.Employee.
            ["view", "form"].each do |kind|
              body = %({"parent_doctype": "hr.Employee", "kind": "#{kind}"})
              meta = %({"parent_id": "hr.Employee"})
              Facet::Mutation::Client.create(
                txn, "core", "DocumentView",
                content: body, meta: meta, actioner_id: "system:test",
              )
            end

            result = Draft.create_from(txn, "hr", "user-1").as(Draft::Result)
            draft_name = result.projection.id
          end

          # Doctype definition copied.
          draft_def = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{draft_name}.Employee")
          draft_def.content["domain"].as_s.should eq(draft_name)

          # Two DocumentViews copied, parent_doctype rewritten to the draft.
          views = db.query_all(
            "SELECT content->>'parent_doctype', content->>'kind' FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'DocumentView' AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
            "#{draft_name}.Employee",
          ) do |rs|
            {rs.read(String), rs.read(String)}
          end
          views.size.should eq(2)
          kinds = views.map(&.[1]).sort!
          kinds.should eq(["form", "view"])
          views.each { |(pd, _)| pd.should eq("#{draft_name}.Employee") }
        end
      end

      it "preserves the source live domain untouched" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "hr")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))
            create_doc(txn, "hr", "Employee", %({"name": "alice"}))

            Draft.create_from(txn, "hr", "user-1").as(Draft::Result)
          end

          # Source domain document still live, no draft flag, no source_domain.
          hr = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "hr")
          hr.content["draft"]?.should be_nil
          hr.content["source_domain"]?.should be_nil

          # Source doctype + data intact.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'hr' AND doc_type = 'Employee'",
            as: Int64,
          )
          count.should eq(1)
        end
      end

      it "rejects with 409 if a draft already exists for the source domain" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "hr")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))

            Draft.create_from(txn, "hr", "user-1").should be_a(Draft::Result)

            second = Draft.create_from(txn, "hr", "user-1")
            second.should be_a(Facet::ServiceError)
            err = second.as(Facet::ServiceError)
            err.status.should eq(409)
            err.message.should contain("already exists")
          end
        end
      end

      it "rejects with 422 if the source does not exist" do
        with_db do |db|
          result = Draft.create_from(db, "_ghost", "user-1")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("not found")
        end
      end

      it "rejects with 422 if the source is itself a draft" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            create_doctype_in_domain(txn, draft, "Widget", %({"name": {"type": "string"}}))

            result = Draft.create_from(txn, draft, "user-1")
            result.should be_a(Facet::ServiceError)
            err = result.as(Facet::ServiceError)
            err.status.should eq(422)
            err.message.should contain("Cannot draft from a draft")
          end
        end
      end

      it "allows drafts from different source domains simultaneously" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "hr")
            ensure_domain(txn, "crm")
            create_doctype_in_domain(txn, "hr", "Employee", %({"name": {"type": "string"}}))
            create_doctype_in_domain(txn, "crm", "Company", %({"name": {"type": "string"}}))

            r1 = Draft.create_from(txn, "hr", "user-1").as(Draft::Result)
            r2 = Draft.create_from(txn, "crm", "user-1").as(Draft::Result)

            r1.projection.content["source_domain"].as_s.should eq("hr")
            r2.projection.content["source_domain"].as_s.should eq("crm")
            r1.projection.id.should_not eq(r2.projection.id)
          end
        end
      end
    end
  end

  describe Scratch do
    describe ".drop" do
      it "soft-deletes a draft domain's projections and preserves the mutation log" do
        with_db do |db|
          draft = create_draft_domain(db)

          # Seed a doctype definition + a document under the draft.
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))
          create_doc(db, draft, "Widget", %({"name": "w"}))

          # Sanity: rows exist before drop.
          db.query_one("SELECT COUNT(*) FROM projections WHERE domain = $1", draft, as: Int64).should eq(1)
          Facet::Database.with_transaction do |txn|
            # core.DocType + core.Domain rows live under core, not the draft name.
            txn.query_one(
              "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND content->>'domain' = $1",
              draft, as: Int64).should eq(1)
          end

          Scratch.drop(db, draft)

          # Draft's own projections soft-deleted (deleted_at set).
          db.query_one("SELECT COUNT(*) FROM projections WHERE domain = $1 AND deleted_at IS NULL", draft, as: Int64).should eq(0)
          db.query_one("SELECT COUNT(*) FROM projections WHERE domain = $1 AND deleted_at IS NOT NULL", draft, as: Int64).should eq(1)

          # Mutation log is preserved — the append-only contract is intact.
          db.query_one("SELECT COUNT(*) FROM mutations WHERE domain = $1", draft, as: Int64).should_not eq(0)

          # Draft's core.DocType definition rows soft-deleted.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND content->>'domain' = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)

          # Draft's own core.Domain document soft-deleted.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)
        end
      end

      it "tombstones the draft's view rows (orphaned-view leak fix)" do
        with_db do |db|
          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))
          create_document_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget", owner_id: "user-1")

          # Sanity: three live view rows under core before the drop.
          db.query_one(
            <<-SQL, draft, as: Int64
              SELECT COUNT(*) FROM projections
              WHERE domain = 'core'
                AND doc_type IN ('DocumentView', 'CollectionView')
                AND deleted_at IS NULL
                AND split_part(meta->>'parent_id', '.', 1) = $1
            SQL
          ).should eq(3)

          Scratch.drop(db, draft)

          # Every view row of the draft's doctypes is tombstoned —
          # DocumentView, general CollectionView, and personal
          # CollectionView alike (the draft is disposed wholesale).
          db.query_one(
            <<-SQL, draft, as: Int64
              SELECT COUNT(*) FROM projections
              WHERE domain = 'core'
                AND doc_type IN ('DocumentView', 'CollectionView')
                AND deleted_at IS NULL
                AND split_part(meta->>'parent_id', '.', 1) = $1
            SQL
          ).should eq(0)
        end
      end

      it "refuses to drop a non-draft domain (fail-closed)" do
        with_db do |db|
          # `hr` is a live domain (no draft flag, or draft != true).
          ensure_domain(db, "hr")

          expect_raises(Scratch::Error, /not a draft/) do
            Scratch.drop(db, "hr")
          end

          # Live domain's projection must still exist.
          exists = db.query_one?(
            "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'hr'",
            as: Int32,
          )
          exists.should_not be_nil
        end
      end

      it "refuses to drop a missing domain" do
        with_db do |db|
          expect_raises(Scratch::Error, /not a draft/) do
            Scratch.drop(db, "_nonexistent")
          end
        end
      end

      it "cleans artifact provenance for the domain but leaves artifacts rows" do
        with_db do |db|
          draft = create_draft_domain(db)

          # Seed an artifact + owner + reference row scoped to the draft.
          artifact_id = "art-drop-#{unique_suffix}"
          db.exec(
            "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) VALUES ($1, 'a.txt', 'text/plain', 4, 'sha', 'sha/#{artifact_id}')",
            artifact_id,
          )
          db.exec(
            "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) VALUES ($1, $2, $3, 'Asset', 'doc-1', 'file', 'sys')",
            "owner-#{artifact_id}", artifact_id, draft,
          )
          db.exec(
            "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field) VALUES ($1, $2, 'doc-1', 'file')",
            artifact_id, draft,
          )

          Scratch.drop(db, draft)

          # Provenance rows for the domain are gone; artifacts rows remain
          # (they fall out on the next prune, which is join-derived).
          db.query_one("SELECT COUNT(*) FROM artifact_owners WHERE domain = $1", draft, as: Int64).should eq(0)
          db.query_one("SELECT COUNT(*) FROM artifact_references WHERE domain = $1", draft, as: Int64).should eq(0)
          db.query_one("SELECT COUNT(*) FROM artifacts WHERE id = $1", artifact_id, as: Int64).should eq(1)
        end
      end
    end

    describe ".dispose_definitions!" do
      it "removes the definition surface and keeps data rows, personal views, and provenance" do
        with_db do |db|
          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))
          create_doc(db, draft, "Widget", %({"name": "w"}))
          create_document_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget", owner_id: "user-1")
          seed_doctype_index_row(db, draft)

          # Seed a provenance row scoped to the domain.
          artifact_id = "art-disp-#{unique_suffix}"
          db.exec(
            "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) VALUES ($1, 'a.txt', 'text/plain', 4, 'sha', 'sha/#{artifact_id}')",
            artifact_id,
          )
          db.exec(
            "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) VALUES ($1, $2, $3, 'Asset', 'doc-1', 'file', 'sys')",
            "owner-#{artifact_id}", artifact_id, draft,
          )

          Scratch.dispose_definitions!(db, draft)

          # core.DocType definition rows tombstoned.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND content->>'domain' = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)

          # core.Domain row tombstoned.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)

          # DocumentView + general CollectionView tombstoned.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocumentView' AND deleted_at IS NULL",
            as: Int64,
          ).should eq(0)
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'CollectionView' AND deleted_at IS NULL AND content->>'owner_id' IS NULL",
            as: Int64,
          ).should eq(0)

          # Personal (owner-bound) CollectionView kept — user data.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'CollectionView' AND content->>'owner_id' = 'user-1' AND deleted_at IS NULL",
            as: Int64,
          ).should eq(1)

          # Data rows kept live.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(1)

          # doctype_indexes tracking rows hard-deleted.
          db.query_one(
            "SELECT COUNT(*) FROM doctype_indexes WHERE domain = $1",
            draft, as: Int64).should eq(0)

          # Artifact provenance kept.
          db.query_one(
            "SELECT COUNT(*) FROM artifact_owners WHERE domain = $1",
            draft, as: Int64).should eq(1)
        end
      end

      # The managed indexes are partial indexes on the shared `projections`
      # table, so deleting the `doctype_indexes` tracking rows alone leaves
      # the real indexes (and their field statistics objects) behind. Nothing
      # would ever drop them again — every write and query plan would keep
      # paying for a domain that no longer exists. This asserts the physical
      # DDL goes with the domain.
      it "drops the domain's physical indexes and statistics objects" do
        with_db do |db|
          draft = create_draft_domain(db)

          # A field with an equality capability plans to a btree index (plus
          # a statistics object), so `sync` creates real DDL on `projections`.
          defn = Facet::Doctype::DoctypeDefinition.new(
            doctype: "Widget", domain: draft,
            fields: {"code" => Facet::Doctype::FieldDefinition.new(
              type: Facet::Doctype::FieldType.parse("string"),
              filters: [Facet::Doctype::FilterCapability::Equality],
            )},
          )
          Facet::Index::Manager.sync(db, defn)

          index_name = Facet::Index::Naming.index_name(draft, "Widget", "code", "btree")
          stats_name = Facet::Index::Naming.statistics_name(draft, "Widget", "code")

          # Both the index and the statistics object exist before disposal.
          db.query_one(
            "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'projections' AND indexname = $1",
            index_name, as: Int64).should eq(1)
          db.query_one(
            "SELECT COUNT(*) FROM pg_statistic_ext WHERE stxname = $1",
            stats_name, as: Int64).should eq(1)

          Scratch.dispose_definitions!(db, draft)

          # Tracking rows, physical index, and statistics object all gone.
          db.query_one(
            "SELECT COUNT(*) FROM doctype_indexes WHERE domain = $1",
            draft, as: Int64).should eq(0)
          db.query_one(
            "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'projections' AND indexname = $1",
            index_name, as: Int64).should eq(0)
          db.query_one(
            "SELECT COUNT(*) FROM pg_statistic_ext WHERE stxname = $1",
            stats_name, as: Int64).should eq(0)
        end
      end

      it "leaves view rows of other domains untouched" do
        with_db do |db|
          draft_a = create_draft_domain(db)
          draft_b = create_draft_domain(db)
          create_doctype_in_domain(db, draft_a, "Widget", %({"name": {"type": "string"}}))
          create_doctype_in_domain(db, draft_b, "Widget", %({"name": {"type": "string"}}))
          create_document_view(db, "#{draft_b}.Widget")

          Scratch.dispose_definitions!(db, draft_a)

          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocumentView' AND deleted_at IS NULL",
            as: Int64,
          ).should eq(1)
        end
      end
    end

    describe ".dispose!" do
      it "removes definitions, all views (incl. personal), data rows, and provenance" do
        with_db do |db|
          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))
          create_doc(db, draft, "Widget", %({"name": "w"}))
          create_document_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget")
          create_collection_view(db, "#{draft}.Widget", owner_id: "user-1")
          seed_doctype_index_row(db, draft)

          artifact_id = "art-full-#{unique_suffix}"
          db.exec(
            "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) VALUES ($1, 'a.txt', 'text/plain', 4, 'sha', 'sha/#{artifact_id}')",
            artifact_id,
          )
          db.exec(
            "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) VALUES ($1, $2, $3, 'Asset', 'doc-1', 'file', 'sys')",
            "owner-#{artifact_id}", artifact_id, draft,
          )
          db.exec(
            "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field) VALUES ($1, $2, 'doc-1', 'file')",
            artifact_id, draft,
          )

          Scratch.dispose!(db, draft)

          # Definition surface gone.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND content->>'domain' = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)

          # Every view row gone — personal included.
          db.query_one(
            <<-SQL, draft, as: Int64
              SELECT COUNT(*) FROM projections
              WHERE domain = 'core'
                AND doc_type IN ('DocumentView', 'CollectionView')
                AND deleted_at IS NULL
                AND split_part(meta->>'parent_id', '.', 1) = $1
            SQL
          ).should eq(0)

          # Data rows tombstoned.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1 AND deleted_at IS NULL",
            draft, as: Int64).should eq(0)

          # Provenance gone; artifacts row remains.
          db.query_one("SELECT COUNT(*) FROM artifact_owners WHERE domain = $1", draft, as: Int64).should eq(0)
          db.query_one("SELECT COUNT(*) FROM artifact_references WHERE domain = $1", draft, as: Int64).should eq(0)
          db.query_one("SELECT COUNT(*) FROM artifacts WHERE id = $1", artifact_id, as: Int64).should eq(1)
        end
      end
    end
  end

  describe Copy do
    describe ".structure" do
      it "copies the core.Domain document and doctype definitions to the target name" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn, %({"description": "draft"}))

            # Seed doctype definitions under the draft.
            create_doctype_in_domain(txn, draft, "Widget", %({"name": {"type": "string"}}))
            create_doctype_in_domain(txn, draft, "Gadget", %({"title": {"type": "string"}}))

            # Copy structure to a real-named target.
            Copy.structure(txn, from: draft, to: "orders", draft: false)
          end

          # Target domain document exists with draft=false, description preserved.
          target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "orders")
          target.content["draft"].raw.should be_false
          target.content["description"].as_s.should eq("draft")

          # Both doctypes were re-created under the new domain string.
          orders_widget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          orders_widget.content["domain"].as_s.should eq("orders")
          orders_widget.content["doctype"].as_s.should eq("Widget")

          orders_gadget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Gadget")
          orders_gadget.content["domain"].as_s.should eq("orders")
        end
      end

      it "does NOT copy draft document data (structure-only copy)" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            create_doctype_in_domain(txn, draft, "Widget", %({"name": {"type": "string"}}))
            create_doc(txn, draft, "Widget", %({"name": "w1"}))
            create_doc(txn, draft, "Widget", %({"name": "w2"}))

            Copy.structure(txn, from: draft, to: "orders", draft: false)
          end

          # Target domain has zero documents of its doctype (data not copied).
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'orders' AND doc_type = 'Widget'",
            as: Int64,
          )
          count.should eq(0)
        end
      end

      it "sets draft=false on the copied core.Domain document" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            create_doctype_in_domain(txn, draft, "W", %({"n": {"type": "string"}}))
            Copy.structure(txn, from: draft, to: "livecopy", draft: false)
          end

          proj = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "livecopy")
          proj.content["draft"].raw.should be_false
        end
      end

      it "raises if the source domain does not exist" do
        with_db do |_db|
          expect_raises(Exception, /not found/) do
            Facet::Database.with_transaction do |txn|
              Copy.structure(txn, from: "_ghost", to: "orders", draft: false)
            end
          end
        end
      end

      it "merges extra_content fields onto the target domain document" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "source")
            create_doctype_in_domain(txn, "source", "Widget", %({"name": {"type": "string"}}))

            Copy.structure(
              txn,
              from: "source",
              to: "_draft1",
              draft: true,
              extra_content: {"source_domain" => JSON::Any.new("source")},
            )
          end

          target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "_draft1")
          target.content["draft"].raw.should be_true
          target.content["source_domain"].as_s.should eq("source")
          target.content["id"].as_s.should eq("_draft1")
        end
      end

      it "lets id and draft always win over extra_content" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            ensure_domain(txn, "source")
            create_doctype_in_domain(txn, "source", "Widget", %({"name": {"type": "string"}}))

            Copy.structure(
              txn,
              from: "source",
              to: "_draft2",
              draft: true,
              extra_content: {
                "id"            => JSON::Any.new("evil"),
                "draft"         => JSON::Any.new(false),
                "source_domain" => JSON::Any.new("source"),
              },
            )
          end

          target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "_draft2")
          target.id.should eq("_draft2")
          target.content["id"].as_s.should eq("_draft2")
          target.content["draft"].raw.should be_true
          target.content["source_domain"].as_s.should eq("source")
        end
      end
    end
  end

  describe Publish do
    describe ".call" do
      it "publishes a draft into a fresh real-named domain and drops the draft" do
        with_db do |db|
          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn, %({"description": "scratch"}))

            create_doctype_in_domain(txn, draft, "Widget", %({"name": {"type": "string"}}))
            create_doc(txn, draft, "Widget", %({"name": "scratch-data"}))

            Publish.call(txn, draft, "orders", actioner_id: "user-1")
          end

          result.should be_a(Publish::Result)
          res = result.as(Publish::Result)
          res.target_domain.should eq("orders")

          # Target domain document exists and is NOT a draft.
          target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "orders")
          target.content["draft"].raw.should be_false
          target.content["description"].as_s.should eq("scratch")

          # Target doctype definition exists under the new domain.
          orders_widget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          orders_widget.content["domain"].as_s.should eq("orders")

          # The draft's data is gone (no documents, no doctype defs).
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1",
            res.target_domain.not_nil!.split('_').first, # safety; unused
            as: Int64)                                   # no-op sanity — the real check is below.

          # Draft's own doctype data is soft-deleted.
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' " \
            "AND content->>'domain' LIKE '\\_%' AND deleted_at IS NULL", # drafts always start with _
            as: Int64).should eq(0)

          # Target doctype data absent (structure-only publish, data dropped).
          db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'orders' AND doc_type = 'Widget'",
            as: Int64,
          ).should eq(0)
        end
      end

      it "rejects a target name already owned by a live domain" do
        with_db do |db|
          # Pre-create a live domain with the target name.
          ensure_domain(db, "orders")

          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            create_doctype_in_domain(txn, draft, "W", %({"n": {"type": "string"}}))
            Publish.call(txn, draft, "orders")
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(409)
          err.message.should contain("already in use")
          err.message.should contain("overwrite:true")
        end
      end

      it "rejects a target name starting with _" do
        with_db do |_db|
          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            Publish.call(txn, draft, "_evil")
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("must not start with '_'")
        end
      end

      it "rejects when the source is not draft=true" do
        with_db do |db|
          ensure_domain(db, "hr")

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, "hr", "produced")
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("not a draft")
        end
      end

      it "rejects an invalid target name" do
        with_db do |_db|
          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)
            Publish.call(txn, draft, "BadName") # uppercase
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("invalid")
        end
      end

      it "rollback leaves the draft intact when the transaction aborts" do
        with_db do |db|
          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "W", %({"n": {"type": "string"}}))

          # Force an abort mid-transaction: pre-create the target so the
          # publish's target_name_taken? check fails inside the txn.
          ensure_domain(db, "orders")

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders")
          end
          result.should be_a(Facet::ServiceError)

          # Draft domain document should still exist.
          draft_doc = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", draft)
          draft_doc.content["draft"].raw.should be_true

          # Draft's doctype definition should still exist.
          draft_dt = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{draft}.W")
          draft_dt.content["domain"].as_s.should eq(draft)
        end
      end

      it "enqueues core.Domain created and core.DocType registered events on publish" do
        with_db do |_db|
          # Capture the in-process event manager so we can inspect events.
          manager = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
          manager.clear!

          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn, %({"description": "scratch"}))
            create_doctype_in_domain(txn, draft, "Widget", %({"name": {"type": "string"}}))
            create_doctype_in_domain(txn, draft, "Gadget", %({"title": {"type": "string"}}))
            Publish.call(txn, draft, "orders", actioner_id: "user-1")
          end
          result.should be_a(Publish::Result)
          Facet::Event::Publisher.flush

          # core.Domain created event for the new target.
          domain_events = manager.events_for("FACET:RESOURCE:core:Domain")
          domain_events.any? { |e| e.headers["event"]?.try(&.as_s) == "created" }.should be_true
          domain_events.any? do |e|
            e.headers["event"]?.try(&.as_s) == "created" &&
              e.content["id"]?.try(&.as_s) == "orders"
          end.should be_true

          # core.DocType registered events for each published doctype.
          doctype_events = manager.events_for("FACET:RESOURCE:core:DocType")
          doctype_events.any? do |e|
            e.headers["event"]?.try(&.as_s) == "registered" &&
              e.content["id"]?.try(&.as_s) == "orders.Widget"
          end.should be_true
          doctype_events.any? do |e|
            e.headers["event"]?.try(&.as_s) == "registered" &&
              e.content["id"]?.try(&.as_s) == "orders.Gadget"
          end.should be_true
        end
      end

      it "relinks same-domain reference targets to the target domain on fresh publish" do
        with_db do |db|
          result = Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)

            create_doctype_in_domain(txn, draft, "Brand", %({"name": {"type": "string"}}))
            create_doctype_in_domain(
              txn, draft, "Machine",
              %({
                   "brand": {"type": "reference", "doctype": "#{draft}.Brand"},
                   "owner_id": {"type": "reference", "doctype": "iam.Account"},
                   "tags": {"type": "array", "items": {"type": "reference", "doctype": "#{draft}.Brand"}},
                   "meta": {"type": "object", "properties": {"alt": {"type": "reference", "doctype": "#{draft}.Brand"}}},
                   "attrs": {"type": "dictionary", "values": {"type": "reference", "doctype": "#{draft}.Brand"}}
                 }),
            )

            Publish.call(txn, draft, "orders", actioner_id: "user-1")
          end
          result.should be_a(Publish::Result)

          machine = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Machine")
          fields = machine.content["fields"]

          # Same-domain targets follow the identity change...
          fields["brand"]["doctype"].as_s.should eq("orders.Brand")
          fields["tags"]["items"]["doctype"].as_s.should eq("orders.Brand")
          fields["meta"]["properties"]["alt"]["doctype"].as_s.should eq("orders.Brand")
          fields["attrs"]["values"]["doctype"].as_s.should eq("orders.Brand")

          # ...cross-domain targets are untouched.
          fields["owner_id"]["doctype"].as_s.should eq("iam.Account")
        end
      end

      it "relinks live same-domain reference targets to the draft domain on create_from" do
        with_db do |db|
          ensure_domain(db, "orders")
          create_doctype_in_domain(db, "orders", "Brand", %({"name": {"type": "string"}}))
          create_doctype_in_domain(
            db, "orders", "Machine",
            %({"brand": {"type": "reference", "doctype": "orders.Brand"}}),
          )

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          machine = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{draft}.Machine")
          machine.content["fields"]["brand"]["doctype"].as_s.should eq("#{draft}.Brand")
        end
      end

      it "carries the draft's hooks into the target domain document on fresh publish" do
        with_db do |db|
          draft = create_draft_domain(db, domain_hooks_content("freshorders"))

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "freshorders", actioner_id: "user-1")
          end
          result.should be_a(Publish::Result)
          result.as(Publish::Result).warnings.should be_empty

          # Fresh publish copies the whole core.Domain content — hooks ride
          # along, and the hooks registry picks them up on the next rebuild.
          target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "freshorders")
          hooks = target.content["hooks"].as_a
          hooks.size.should eq(1)
          hooks.first["id"].as_s.should eq("notify-credit")
        end
      end
    end

    describe "overwrite publish" do
      it "treats a domain-relinked draft as structurally identical (no version bump)" do
        with_db do |db|
          # Live orders.Machine references orders.Brand; the draft derived
          # from it carries the same schema pointing at the draft identity.
          # The only difference is the reference-target relink, which is not
          # a structural change — the gate must not demand a version bump.
          ensure_domain(db, "orders")
          create_doctype_in_domain(db, "orders", "Brand", %({"name": {"type": "string"}}))
          create_doctype_in_domain(
            db, "orders", "Machine",
            %({"brand": {"type": "reference", "doctype": "orders.Brand"}}),
          )

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          live = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Machine")
          live.content["schema_version"].as_i.should eq(1)
          live.content["fields"]["brand"]["doctype"].as_s.should eq("orders.Brand")
        end
      end

      it "allows publishing over an existing domain when structure is identical" do
        with_db do |db|
          draft = seed_live_and_draft(db)

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # Live definition replaced (same version, same structure).
          live = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          live.content["domain"].as_s.should eq("orders")
          live.content["schema_version"].as_i.should eq(1)

          # Live document still present, still at version 1.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'orders' AND doc_type = 'Widget' AND deleted_at IS NULL",
            as: Int64)
          count.should eq(1)
        end
      end

      it "requires schema_version = live + 1 and a migration entry when structure changed" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            live_fields: %({"name": {"type": "string"}}),
            draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
            draft_version: 2,
            draft_migrations: %({"1": "migrate_from_1"}),
            draft_script: "local export = {}; function export.migrate_from_1(ctx) end; return export",
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # Live definition replaced at v2.
          live = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          live.content["schema_version"].as_i.should eq(2)
          live.content["fields"]["age"].should_not be_nil

          # Live document still there; lazy migration will run on read.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'orders' AND doc_type = 'Widget' AND deleted_at IS NULL",
            as: Int64)
          count.should eq(1)
        end
      end

      it "rejects with 422 when structure changed but version is not live + 1" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
            draft_version: 1, # same as live — must be 2
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("schema_version must be 2")
        end
      end

      it "rejects with 422 when structure changed and the migration entry is missing" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
            draft_version: 2,
            # no migrations, no script
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("Migration from v1 to v2 is missing")
        end
      end

      it "rejects with 422 when structure changed and the version skipped ahead" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
            draft_version: 3, # skips v2
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("schema_version must be 2")
        end
      end

      it "rejects with 409 when overwrite is false and the target exists" do
        with_db do |db|
          ensure_domain(db, "orders")
          draft = create_draft_domain(db)

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders")
          end
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(409)
          err.message.should contain("already in use")
          err.message.should contain("overwrite:true")
        end
      end

      it "adds a new doctype when the draft defines one the target lacks" do
        with_db do |db|
          ensure_domain(db, "orders")
          create_doctype_in_domain(db, "orders", "Widget", %({"name": {"type": "string"}}))

          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Gadget", %({"title": {"type": "string"}}))

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # New doctype registered under the target; existing doctype untouched.
          gadget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Gadget")
          gadget.content["domain"].as_s.should eq("orders")
          widget = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          widget.content["schema_version"].as_i.should eq(1)
        end
      end

      it "reconciles DocumentViews per kind on overwrite" do
        with_db do |db|
          restore_seeded_baseline(db)
          Facet::Doctype::DefinitionStore.cache.clear

          ensure_domain(db, "orders")
          create_doctype_in_domain(db, "orders", "Widget", %({"name": {"type": "string"}}))

          # Live views: quickView (template A) + view (to be removed in draft).
          # Valid template trees — the publish reconcile writes them through
          # the gated document pipeline.
          [
            %({"parent_doctype": "orders.Widget", "kind": "quickView", "template": {"type": "section", "label": "A", "children": []}}),
            %({"parent_doctype": "orders.Widget", "kind": "view", "template": {"type": "section", "label": "A", "children": []}}),
          ].each do |body|
            Facet::Mutation::Client.create(
              db, "core", "DocumentView",
              content: body, meta: %({"parent_id": "orders.Widget"}),
              actioner_id: "system:test",
            )
          end

          # Draft: quickView (template B) + form (new kind).
          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))
          [
            %({"parent_doctype": "#{draft}.Widget", "kind": "quickView", "template": {"type": "section", "label": "B", "children": []}}),
            %({"parent_doctype": "#{draft}.Widget", "kind": "form"}),
          ].each do |body|
            Facet::Mutation::Client.create(
              db, "core", "DocumentView",
              content: body, meta: %({"parent_id": "#{draft}.Widget"}),
              actioner_id: "system:test",
            )
          end

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          views = db.query_all(
            "SELECT content->>'kind', content->'template' FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'DocumentView' AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
            "orders.Widget",
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any?)}
          end
          kinds = views.map(&.[0]).sort!
          kinds.should eq(["form", "quickView"])
          quick = views.find! { |v| v[0] == "quickView" }
          quick[1].not_nil!["label"].as_s.should eq("B") # template updated in place
        end
      end

      it "keeps CollectionViews untouched on overwrite" do
        with_db do |db|
          restore_seeded_baseline(db)
          Facet::Doctype::DefinitionStore.cache.clear

          ensure_domain(db, "orders")
          create_doctype_in_domain(db, "orders", "Widget", %({"name": {"type": "string"}}))

          # A live CollectionView tab.
          Facet::Mutation::Client.create(
            db, "core", "CollectionView",
            content: %({"name": "All", "surface": "table", "config": {"columns": []}}),
            meta: %({"parent_id": "orders.Widget"}),
            actioner_id: "system:test",
          )

          draft = create_draft_domain(db)
          create_doctype_in_domain(db, draft, "Widget", %({"name": {"type": "string"}}))

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # The live CollectionView survives untouched.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'CollectionView' " \
            "AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
            "orders.Widget",
            as: Int64,
          )
          count.should eq(1)
        end
      end

      it "keeps live documents and defers migration to lazy read-time migration" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            live_fields: %({"name": {"type": "string"}}),
            draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
            draft_version: 2,
            draft_migrations: %({"1": "migrate_from_1"}),
            draft_script: "local export = {}; function export.migrate_from_1(ctx) ctx.root.age = 30; end; return export",
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # The live document is still present, still at v1 in storage.
          doc_id = db.query_one(
            "SELECT id FROM projections WHERE domain = 'orders' AND doc_type = 'Widget' AND deleted_at IS NULL",
            as: String)
          proj = Facet::Mutation::Client.fetch_projection(db, "orders", "Widget", doc_id)
          proj.content["name"].as_s.should eq("alice")

          # Lazy migration on read: definition is now v2, doc is v1.
          defn = Facet::Doctype::DefinitionStore.fetch(db, "orders.Widget")
          migrated = Facet::Document::Migrate.call(db, defn.not_nil!, proj)
          migrated.should be_a(Facet::Document::Migrate::Result)
          migrated_proj = migrated.as(Facet::Document::Migrate::Result).projection
          migrated_proj.content["age"].as_i.should eq(30)
        end
      end

      it "publishes over a live domain at the same schema_version when only non-structural attributes changed (operators, title)" do
        with_db do |db|
          draft = seed_live_and_draft(
            db,
            live_fields: %({"name": {"type": "string"}}),
            draft_fields: %({"name": {"type": "string", "title": "Name", "filters": ["comparison"]}}),
            draft_version: 1, # same as live — no bump required for non-structural edits
          )

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)

          # Live definition replaced at v1, now carrying the title + operators.
          live = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "orders.Widget")
          live.content["schema_version"].as_i.should eq(1)
          live.content["fields"]["name"]["title"]?.try(&.as_s).should eq("Name")
          live.content["fields"]["name"]["filters"]?.try(&.as_a.map(&.as_s)).should eq(["comparison"])
        end
      end

      it "warns when the draft declares hooks the live domain lacks (B-352)" do
        with_db do |db|
          ensure_domain(db, "orders")
          draft = create_draft_domain(db, domain_hooks_content("orders"))

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)
          res = result.as(Publish::Result)

          # The response names the hooks the publish did not carry.
          res.warnings.size.should eq(1)
          res.warnings.first.should contain("does not copy hooks")
          res.warnings.first.should contain("'notify-credit'")
          res.warnings.first.should contain("'orders'")

          # The live domain document is unchanged — the draft's hooks did
          # not land on it. The workaround is a patch of its `hooks` field.
          live = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "orders")
          live.content["hooks"]?.should be_nil
        end
      end

      it "does not warn when the draft declares no hooks" do
        with_db do |db|
          ensure_domain(db, "orders")
          draft = create_draft_domain(db)

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)
          result.as(Publish::Result).warnings.should be_empty
        end
      end

      it "does not warn when the live domain already carries the draft's hooks" do
        with_db do |db|
          Facet::Mutation::Client.create(
            db, "core", "Domain",
            doc_id: "orders",
            content: domain_hooks_content("orders"),
            actioner_id: "system:test",
          )
          draft = create_draft_domain(db, domain_hooks_content("orders"))

          result = Facet::Database.with_transaction do |txn|
            Publish.call(txn, draft, "orders", actioner_id: "user-1", overwrite: true)
          end
          result.should be_a(Publish::Result)
          result.as(Publish::Result).warnings.should be_empty
        end
      end
    end
  end
end

module Facet::Doctype
  describe Update do
    describe "draft-mode capability switch" do
      it "allows a destructive same-version edit on a draft doctype (would be rejected live)" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)

            # Create v1 with two fields.
            create_doctype_in_domain(txn, draft, "W",
              %({"name": {"type": "string"}, "age": {"type": "integer"}}))

            # Same-version edit that removes `age` and changes `name`'s
            # type — both rejected in live mode without $force.
            new_def = %({
              "doctype": "W",
              "domain": "#{draft}",
              "schema_version": 1,
              "fields": {
                "name": {"type": "integer"}
              }
            })

            result = Update.call(txn, "#{draft}.W", new_def, Facet::RBAC::AuthContext.system)
            result.should be_a(Update::Result)
          end
        end
      end

      it "allows a version decrease on a draft doctype" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)

            # Start at v2 with a migration function (would normally be
            # required to create from scratch, but drafts bypass all that —
            # insert directly).
            create_doctype_in_domain(txn, draft, "W",
              %({"name": {"type": "string"}}))

            # Force v2 via direct insert (drafts allow skipping versions
            # upward, so first set v2).
            v2_body = %({
              "doctype": "W",
              "domain": "#{draft}",
              "schema_version": 2,
              "fields": {"name": {"type": "string"}}
            })
            result = Update.call(txn, "#{draft}.W", v2_body, Facet::RBAC::AuthContext.system)
            result.should be_a(Update::Result)

            # Now decrease back to v1 — would be 422 in live mode.
            v1_body = %({
              "doctype": "W",
              "domain": "#{draft}",
              "schema_version": 1,
              "fields": {"name": {"type": "string"}}
            })
            result = Update.call(txn, "#{draft}.W", v1_body, Facet::RBAC::AuthContext.system)
            result.should be_a(Update::Result)

            # Sanity: stored version is 1.
            proj = Facet::Mutation::Client.fetch_projection(txn, "core", "DocType", "#{draft}.W")
            proj.content["schema_version"].as_i.should eq(1)
          end
        end
      end

      it "still enforces version constraints on a live domain" do
        with_db do |db|
          ensure_domain(db, "live")

          create_doctype_in_domain(db, "live", "W",
            %({"name": {"type": "string"}, "age": {"type": "integer"}}))

          # Same-version destructive edit — must be rejected without $force.
          new_def = %({
            "doctype": "W",
            "domain": "live",
            "schema_version": 1,
            "fields": {"name": {"type": "integer"}}
          })

          result = Facet::Database.with_transaction do |txn|
            Update.call(txn, "live.W", new_def, Facet::RBAC::AuthContext.system)
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          # Either the field-removal message or the type-change message
          # satisfies this — both are destructive same-version edits rejected
          # in live mode.
          err.message.should contain("cannot")
        end
      end
    end
  end

  describe Create do
    describe "cross-doctype resolution is no longer enforced" do
      it "creates a live doctype with a replicate field whose source doctype does not yet exist" do
        with_db do |db|
          # Live consumer domain. Source doctype identity.Person is
          # deliberately not registered — the create succeeds and the broken
          # edge is inert at runtime, surfacable via `Doctype::Check`.
          ensure_domain(db, "hr")

          defn = Facet::Doctype::DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "search": "{{ person_full_name }}",
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))

          result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
          result.should be_a(Facet::Document::Create::Result)

          # /check now surfaces the missing source/grant as diagnostics.
          check_result = Facet::Doctype::Check.call(db, "hr.Employee")
          check_result.should be_a(Facet::Doctype::Check::Result)
          issues = check_result.as(Facet::Doctype::Check::Result).issues
          issues.any? { |i| i.category == :replication && i.message.includes?("identity.Person") }.should be_true
        end
      end
    end
  end
end

module Facet::Document
  describe Update do
    describe "draft field state-machine guard" do
      it "rejects a patch including 'draft' on a draft core.Domain document" do
        with_db do |db|
          seed_core_domain_doctype(db)
          draft = create_draft_domain(db)

          result = Facet::Database.with_transaction do |txn|
            Update.call(
              txn,
              "core", "Domain", draft,
              %({"draft": false}),
              Facet::RBAC::AuthContext.system,
            )
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("'draft' field cannot be modified")
        end
      end

      it "rejects a patch including 'draft' on a live core.Domain document" do
        with_db do |db|
          seed_core_domain_doctype(db)
          ensure_domain(db, "hr")

          result = Facet::Database.with_transaction do |txn|
            Update.call(
              txn,
              "core", "Domain", "hr",
              %({"draft": true}),
              Facet::RBAC::AuthContext.system,
            )
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("'draft' field cannot be modified")
        end
      end

      it "allows a normal description update on a draft core.Domain" do
        with_db do |db|
          seed_core_domain_doctype(db)
          draft = create_draft_domain(db, %({"description": "old"}))

          result = Facet::Database.with_transaction do |txn|
            Update.call(
              txn,
              "core", "Domain", draft,
              %({"description": "new"}),
              Facet::RBAC::AuthContext.system,
            )
          end

          result.should be_a(Update::Result)
          proj = result.as(Update::Result).projection
          proj.content["description"].as_s.should eq("new")
          proj.content["draft"].raw.should be_true
        end
      end

      it "rejects a draft core.Domain 'name' (display name) that breaks the live-name contract" do
        with_db do |db|
          seed_core_domain_doctype(db)
          draft = create_draft_domain(db)

          result = Facet::Database.with_transaction do |txn|
            Update.call(
              txn,
              "core", "Domain", draft,
              %({"name": "Orders System!"}),
              Facet::RBAC::AuthContext.system,
            )
          end

          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          # The pattern error rides in `details` (an Array(ValidationError)),
          # not the top-level message (which is the generic "Document validation
          # failed").
          details = err.details.not_nil!
          details.any? { |e| e.field == "name" && e.message.includes?("does not match pattern") }.should be_true
        end
      end

      it "accepts a draft core.Domain 'name' that matches the live-name contract" do
        with_db do |db|
          seed_core_domain_doctype(db)
          draft = create_draft_domain(db)

          result = Facet::Database.with_transaction do |txn|
            Update.call(
              txn,
              "core", "Domain", draft,
              %({"name": "hr-ops"}),
              Facet::RBAC::AuthContext.system,
            )
          end

          result.should be_a(Update::Result)
          proj = result.as(Update::Result).projection
          proj.content["name"].as_s.should eq("hr-ops")
        end
      end
    end
  end
end

module Facet::Replication
  describe Registry do
    describe "draft isolation" do
      it "excludes draft-domain doctypes from the binding map" do
        with_db do |db|
          Facet::Database.with_transaction do |txn|
            # Set up a draft domain with a doctype that has a replicate field
            # pointing at an existing live source.
            upsert_domain_with_grants(txn, "identity", %([
              {"to": "_d", "doctype": "Person", "fields": ["full_name"]}
            ]))

            # Source doctype: identity.Person
            person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
              "doctype": "Person",
              "domain": "identity",
              "schema_version": 1,
              "aggregate_root": false,
              "fields": {
                "full_name": {"type": "string", "required": true}
              }
            }))
            Facet::Mutation::Client.create(
              txn, "core", "DocType",
              doc_id: "identity.Person",
              content: person_defn.to_json,
              actioner_id: "system",
            )

            # Consumer doctype in a draft domain with a replicate field.
            draft = create_draft_domain(txn)
            consumer_defn_json = %({
              "doctype": "Consumer",
              "domain": "#{draft}",
              "schema_version": 1,
              "aggregate_root": true, "search": "{{ display_name }}",
              "fields": {
                "person": {"type": "reference", "doctype": "identity.Person", "required": true},
                "person_full_name": {
                  "type": "string",
                  "replicate": {"via": "person", "field": "full_name"},
                  "on_source_delete": "keep"
                }
              }
            })
            consumer_defn = Facet::Doctype::DoctypeDefinition.from_json(consumer_defn_json)
            Facet::Mutation::Client.create(
              txn, "core", "DocType",
              doc_id: "#{draft}.Consumer",
              content: consumer_defn.to_json,
              actioner_id: "system",
            )
          end

          # Build the registry — the draft consumer must not appear.
          registry = Registry.new(domain_enabled: ->(_d : String) { true })
          registry.build(db)

          # The draft's Consumer should NOT contribute any binding.
          # (The identity.Person source has no live consumers, so
          # bindings_for should be empty.)
          registry.bindings_for("identity.Person").should be_empty
          registry.source_doctypes.should be_empty
          registry.consumer_domains.should be_empty
        end
      end
    end
  end

  describe Validator do
    describe "draft source isolation" do
      it "rejects a live consumer replicating from a draft source" do
        with_db do |_db|
          Facet::Database.with_transaction do |txn|
            draft = create_draft_domain(txn)

            # Draft source doctype.
            draft_person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
              "doctype": "Person",
              "domain": "#{draft}",
              "schema_version": 1,
              "aggregate_root": false,
              "fields": {
                "full_name": {"type": "string", "required": true}
              }
            }))
            Facet::Mutation::Client.create(
              txn, "core", "DocType",
              doc_id: "#{draft}.Person",
              content: draft_person_defn.to_json,
              actioner_id: "system",
            )

            # Live consumer doctype referencing the draft source.
            ensure_domain(txn, "live")
            consumer_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
              "doctype": "Consumer",
              "domain": "live",
              "schema_version": 1,
              "aggregate_root": true, "search": "{{ display_name }}",
              "fields": {
                "person": {"type": "reference", "doctype": "#{draft}.Person", "required": true},
                "person_full_name": {
                  "type": "string",
                  "replicate": {"via": "person", "field": "full_name"},
                  "on_source_delete": "keep"
                }
              }
            }))

            errors = Validator.validate(consumer_defn, txn)
            errors.any? { |e| e.includes?("live domains cannot replicate from draft domains") }.should be_true
          end
        end
      end
    end
  end
end
