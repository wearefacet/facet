# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

require "../../src/doctype"
require "../../src/doctype/seed"
require "../../src/doctype/definition_store"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/domain"
require "../../src/domain/portable"

# The definition-seed path writes `core.DocType` rows through raw
# `Mutation::Client.create` — outside the document pipeline. The rows'
# derived columns (`search`, `links`, `display_name`) come from the
# transaction-local GUCs the projection trigger reads, so the seed path
# must stage them; an unstaged GUC stores NULL, and a NULL corpus matches
# nothing on `filters[search]` (run-24 finding B-78 — the reference
# picker's search rode that filter).
#
# The templates for a `core.DocType` row come from the STORED `core.DocType`
# definition — never from the definition being written. Staging from the
# definition being written was fix attempt v2's mistake: `crm.Deal`'s
# `{{ title }} {{ value }}` renders NULL against definition content, and
# `iam.Account`'s renders a literal template fragment.
#
# These specs assert the stored row, not the seed file: the declaration
# alone is `spec/doctype/seed_validity_spec.cr`'s job, and it passed while
# the behavior was broken.
module Facet::Doctype
  describe "Seed projection staging" do
    it "renders the search corpus and display_name for a definition row" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'core.DocType'
          SQL
        # No `label` on the core.DocType definition itself: the display
        # template falls back to the bare doctype name, and the corpus is
        # the qualified id (the label token is dropped by the `{% if %}`).
        row[:search].should eq("core.doctype")
        row[:display_name].should eq("DocType")
      end
    end

    it "renders every definition row whose staging path could know the template" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        # Seeded definition rows render their corpus from the stored
        # `core.DocType` definition, so each row's corpus is its qualified
        # id. A NULL corpus on any listed row is a staging gap — the row
        # must carry the rendered template.
        offenders = db.query_all(<<-SQL, as: String)
          SELECT id
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType'
            AND deleted_at IS NULL
            AND content ? 'search'
            AND search IS NULL
            AND id IN (
              'core.DocType', 'core.Webhook', 'crm.Deal',
              'crm.Company', 'crm.Currency', 'iam.Roles', 'core.Currency'
            )
          SQL
        offenders.should eq([] of String)
      end
    end

    it "keeps a definition row matching through the generic list filter" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        result = Facet::Document::List.call(
          db, "core", "DocType",
          {"search" => JSON::Any.new("doctype")},
        )
        result.should be_a(Facet::Document::List::Result)
        ids = result.as(Facet::Document::List::Result).items.map(&.id)
        ids.should contain("core.DocType")
      end
    end

    it "stages from the stored core.DocType definition, not the seeded one" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        # `iam.Account` declares `search: "{{ email }} {{ name }}"`.
        # Staged from that definition, the row rendered the literal template
        # fragment (definition content has a `display_name` declaration, not
        # a value). Staged from the stored `core.DocType` definition, the
        # corpus is the row's qualified id — case-folded, like every corpus
        # — and the display label is the bare doctype name (no label set).
        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Account'
          SQL
        row[:search].should eq("iam.account")
        row[:display_name].should eq("Account")
      end
    end

    it "seeds core.DocType ahead of its siblings so every row reaches the stored definition" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        # Sorted seed order puts `app.App` before `core.DocType`; before the
        # hoist its row hit the no-definition branch (its own display_name
        # template rendered the literal declaration). Hoisted, it stages
        # from the stored definition like every other row.
        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'app.App'
          SQL
        row[:search].should eq("app.app")
        row[:display_name].should eq("App")
      end
    end

    it "renders rows whose seed does not parse as a definition" do
      with_db do |db|
        # `core.Domain`'s seed uses an unregistered field type (`"type": "any"`),
        # so it cannot parse as a DoctypeDefinition. That no longer decides
        # the staging: the templates come from the stored `core.DocType`
        # definition, so the row renders like any pipeline write instead of
        # landing on the no-definition branch with NULL derived columns.
        Facet::Doctype::Seed.seed(db)

        row = db.query_one?(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'core.Domain'
          SQL
        row.should_not be_nil
        row.not_nil![:search].should eq("core.domain")
        row.not_nil![:display_name].should eq("Domain")
      end
    end

    it "leaves no live definition row with a NULL corpus" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)

        # Every `core.DocType` row stages from the stored `core.DocType`
        # definition, whose template renders the qualified id (`domain` and
        # `doctype` are present on every definition row; the label token
        # drops out through the `{% if %}` when no label is set). A NULL
        # corpus anywhere is a staging gap.
        offenders = db.query_all(<<-SQL, as: String)
          SELECT id
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType'
            AND deleted_at IS NULL
            AND search IS NULL
          SQL
        offenders.should eq([] of String)
      end
    end

    it "renders fixture-imported definition rows end to end" do
      with_db do |db|
        Facet::Doctype::Seed.seed(db)
        Facet::Doctype::DefinitionStore.cache.clear

        # The live failing flow: the harness imports the data/fixtures
        # bundles on every backend start. `crm.Deal` declares
        # `search: "{{ title }} {{ value }}"`; staged from that definition,
        # the row stored NULL and the source-doctype picker answered
        # "No doctype matches" for every term. The import's create branch
        # shares `Domain::Copy.upsert_doctype_definition` with publish, so
        # this drives the copy/import staging site for real.
        bundle = Facet::Domain::Portable::Archive.read(crm_fixture_bundle_path)
        result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)
        result.should be_a(Facet::Domain::Portable::Import::Result)

        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'crm.Deal'
          SQL
        row[:search].should eq("crm.deal")
        row[:display_name].should eq("Deal")

        # The picker's tap: the generic list search must find the row.
        list = Facet::Document::List.call(
          db, "core", "DocType",
          {"search" => JSON::Any.new("Deal")},
        )
        list.should be_a(Facet::Document::List::Result)
        ids = list.as(Facet::Document::List::Result).items.map(&.id)
        ids.should contain("crm.Deal")
      end
    end
  end
end

# Path of the real `crm` fixture bundle the dev harness imports on every
# backend start (`scripts/import-fixtures`).
private def crm_fixture_bundle_path : String
  File.expand_path("../../data/fixtures/crm.facet-domain", __DIR__)
end
