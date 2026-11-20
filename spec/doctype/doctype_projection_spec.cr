# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# The REST doctype services write `core.DocType` rows through raw
# `Mutation::Client` calls — outside the document pipeline. The rows'
# derived columns (`search`, `links`, `display_name`) come from the
# transaction-local GUCs the projection trigger reads, and the trigger
# overwrites the columns on EVERY mutation, so both services must stage:
# an unstaged create stores NULL (the doctype matches nothing on
# `filters[search]` — the WebhookDialog picker's "No doctype matches"),
# and an unstaged update WIPES a previously rendered corpus back to NULL
# (run-24 finding B-78, editor-save arm).
#
# The templates come from the stored `core.DocType` definition — the
# doctype every definition row is written under — never from the
# definition being registered or edited.
module Facet::Doctype
  describe "Doctype service projection staging" do
    it "renders derived columns for a REST-registered doctype" do
      with_db do |db|
        restore_seeded_baseline(db)
        domain = "b78create#{unique_suffix}"
        ensure_domain(db, domain)
        dt = "Widget#{unique_suffix}"

        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1,
                  "search": "{{ title }}", "display_name": "{{ title }}",
                  "fields": {"title": {"type": "string"}}})
        result = Create.call(db, "core", "DocType", body, RBAC::AuthContext.system)
        result.should be_a(Create::Result)

        # The new doctype's own document-facing templates (`{{ title }}`)
        # must NOT stage the definition row: staged from those, the corpus
        # renders NULL against definition content. The stored
        # `core.DocType` definition renders the qualified id, and the
        # display label is the bare doctype name (no `label` set).
        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = '#{domain}.#{dt}'
          SQL
        row[:search].should eq("#{domain}.#{dt}".downcase)
        row[:display_name].should eq(dt)
      end
    end

    it "keeps derived columns rendered across a same-version edit" do
      with_db do |db|
        restore_seeded_baseline(db)
        domain = "b78edit#{unique_suffix}"
        ensure_domain(db, domain)
        dt = "Widget#{unique_suffix}"
        doctype_id = "#{domain}.#{dt}"

        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1,
                  "search": "{{ title }}",
                  "fields": {"title": {"type": "string"}}})
        result = Create.call(db, "core", "DocType", body, RBAC::AuthContext.system)
        result.should be_a(Create::Result)

        edited = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1,
                    "description": "edited for B-78",
                    "search": "{{ title }}",
                    "fields": {"title": {"type": "string"}, "note": {"type": "string"}}})
        updated = Update.call(db, doctype_id, edited, RBAC::AuthContext.system)
        updated.should be_a(Update::Result)

        # Before the staging fix, the editor save overwrote the row's
        # derived columns with NULL (the trigger writes them on every
        # mutation from the unstaged GUCs).
        row = db.query_one(<<-SQL, as: {search: String?, display_name: String?})
          SELECT search, display_name
          FROM projections
          WHERE domain = 'core' AND doc_type = 'DocType' AND id = '#{doctype_id}'
          SQL
        row[:search].should eq(doctype_id.downcase)
        row[:display_name].should eq(dt)
      end
    end

    it "keeps a REST-registered doctype matching through the generic list filter" do
      with_db do |db|
        restore_seeded_baseline(db)
        domain = "b78find#{unique_suffix}"
        ensure_domain(db, domain)
        dt = "Widget#{unique_suffix}"
        doctype_id = "#{domain}.#{dt}"

        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1,
                  "search": "{{ title }}",
                  "fields": {"title": {"type": "string"}}})
        result = Create.call(db, "core", "DocType", body, RBAC::AuthContext.system)
        result.should be_a(Create::Result)

        # The WebhookDialog's tap: the picker filters doctypes through the
        # generic list search. The term is the doctype segment, folded the
        # way the corpus is folded.
        list = Document::List.call(
          db, "core", "DocType",
          {"search" => JSON::Any.new(dt.downcase)},
        )
        list.should be_a(Document::List::Result)
        ids = list.as(Document::List::Result).items.map(&.id)
        ids.should contain(doctype_id)
      end
    end
  end
end
