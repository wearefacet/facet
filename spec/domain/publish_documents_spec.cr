# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/domain"

# Publishing a draft carries documents only when the caller selects the
# doctypes to import. A fresh publish may import any draft doctype; an
# overwrite publish may import only the doctypes the live target does not
# define yet. These specs pin the selection, the refusals, and the data that
# lands on the target.

private def pd_draft(db, content = "{}")
  result = Facet::Domain::Draft.create(db, content, "system:test")
  result.should be_a(Facet::Domain::Draft::Result)
  result.as(Facet::Domain::Draft::Result).projection.id
end

private def pd_doctype(db, domain, doctype, fields)
  content = %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields}})
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{domain}.#{doctype}",
    content: content,
    meta: %({"parent_id": "#{domain}"}),
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
end

private def pd_doc(db, domain, doctype, doc_id, content)
  Facet::Mutation::Client.create(
    db, domain, doctype,
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  doc_id
end

private def pd_rows(db, domain, doctype) : Array(String)
  db.query_all(
    "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL ORDER BY id ASC",
    domain, doctype,
    as: String,
  )
end

private def pd_content(db, domain, doctype, doc_id) : JSON::Any
  Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id).content
end

private def pd_publish(db, draft, target, *, documents : Facet::Domain::PublishDocuments::Selection? = nil, overwrite = false)
  Facet::Database.with_transaction do |txn|
    Facet::Domain::Publish.call(
      txn, draft, target,
      actioner_id: "user-1",
      overwrite: overwrite,
      documents: documents,
    )
  end
end

private def pd_selection(names : Array(String))
  Facet::Domain::PublishDocuments::Selection.new(names)
end

describe Facet::Domain::Publish do
  describe "document import" do
    it "carries no documents when the selection is absent" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))

        result = pd_publish(db, draft, "orders")
        result.should be_a(Facet::Domain::Publish::Result)
        result.as(Facet::Domain::Publish::Result).documents_imported.should eq(0)

        pd_rows(db, "orders", "Status").should be_empty
      end
    end

    it "carries the selected doctype's documents under the target name" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))
        pd_doctype(db, draft, "Sample", %({"name": {"type": "string"}}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))
        pd_doc(db, draft, "Status", "#{draft}.Status.2", %({"name": "closed"}))
        pd_doc(db, draft, "Sample", "#{draft}.Sample.1", %({"name": "fixture"}))

        result = pd_publish(db, draft, "orders", documents: pd_selection(["Status"]))
        result.should be_a(Facet::Domain::Publish::Result)
        result.as(Facet::Domain::Publish::Result).documents_imported.should eq(2)

        pd_rows(db, "orders", "Status").should eq(["orders.Status.1", "orders.Status.2"])
        pd_rows(db, "orders", "Sample").should be_empty
        pd_content(db, "orders", "Status", "orders.Status.1")["name"].as_s.should eq("open")
      end
    end

    it "carries every draft doctype when the selection names none" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))
        pd_doctype(db, draft, "Sample", %({"name": {"type": "string"}}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))
        pd_doc(db, draft, "Sample", "#{draft}.Sample.1", %({"name": "fixture"}))

        result = pd_publish(db, draft, "orders", documents: Facet::Domain::PublishDocuments::Selection.new)
        result.should be_a(Facet::Domain::Publish::Result)
        result.as(Facet::Domain::Publish::Result).documents_imported.should eq(2)

        pd_rows(db, "orders", "Status").size.should eq(1)
        pd_rows(db, "orders", "Sample").size.should eq(1)
      end
    end

    it "carries nothing when the selection is an empty list" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))

        result = pd_publish(db, draft, "orders", documents: pd_selection([] of String))
        result.should be_a(Facet::Domain::Publish::Result)
        result.as(Facet::Domain::Publish::Result).documents_imported.should eq(0)
        pd_rows(db, "orders", "Status").should be_empty
      end
    end

    it "rewrites cross-doctype references from the draft identity to the target" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Category", %({"name": {"type": "string"}}))
        pd_doctype(db, draft, "Status",
          %({"name": {"type": "string"}, "category": {"type": "reference", "doctype": "#{draft}.Category"}}))
        pd_doc(db, draft, "Category", "#{draft}.Category.1", %({"name": "general"}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open", "category": "#{draft}.Category.1"}))

        result = pd_publish(db, draft, "orders", documents: pd_selection(["Category", "Status"]))
        result.should be_a(Facet::Domain::Publish::Result)

        pd_content(db, "orders", "Status", "orders.Status.1")["category"].as_s.should eq("orders.Category.1")
      end
    end

    it "orders the imported rows by the doctype's sort_order field" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status",
          %({"name": {"type": "string"}, "sort_order": {"type": "integer"}}))
        # Ids sort opposite to the intended display order, so id order alone
        # would invert the list.
        pd_doc(db, draft, "Status", "#{draft}.Status.a", %({"name": "third", "sort_order": 30}))
        pd_doc(db, draft, "Status", "#{draft}.Status.b", %({"name": "first", "sort_order": 10}))
        pd_doc(db, draft, "Status", "#{draft}.Status.c", %({"name": "second", "sort_order": 20}))

        result = pd_publish(db, draft, "orders", documents: pd_selection(["Status"]))
        result.should be_a(Facet::Domain::Publish::Result)

        names = db.query_all(
          "SELECT content->>'name' FROM projections WHERE domain = 'orders' AND doc_type = 'Status' " \
          "AND deleted_at IS NULL ORDER BY (content->>'sort_order')::int ASC",
          as: String,
        )
        names.should eq(["first", "second", "third"])
      end
    end

    it "refuses a doctype the draft does not define" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))

        result = pd_publish(db, draft, "orders", documents: pd_selection(["Nope"]))
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Nope")
        err.message.should contain("not defined in draft")
      end
    end

    it "rolls the whole publish back when a document violates a unique constraint" do
      with_db do |db|
        draft = pd_draft(db)
        pd_doctype(db, draft, "Status", %({"name": {"type": "string", "unique": true}}))
        pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))
        pd_doc(db, draft, "Status", "#{draft}.Status.2", %({"name": "open"}))

        result = pd_publish(db, draft, "orders", documents: pd_selection(["Status"]))
        result.should be_a(Facet::ServiceError)

        # The transaction rolled back: neither the target nor the drop landed.
        db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'orders' AND deleted_at IS NULL",
          as: Int64,
        ).should eq(0)
        pd_rows(db, draft, "Status").size.should eq(2)
      end
    end

    describe "overwrite publish" do
      it "imports documents into a doctype the live target does not define yet" do
        with_db do |db|
          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "orders",
            content: %({"description": "live"}),
            actioner_id: "system:test",
          )
          pd_doctype(db, "orders", "Order", %({"name": {"type": "string"}}))
          pd_doc(db, "orders", "Order", "orders.Order.1", %({"name": "live order"}))

          draft = pd_draft(db)
          pd_doctype(db, draft, "Order", %({"name": {"type": "string"}}))
          pd_doctype(db, draft, "Status", %({"name": {"type": "string"}}))
          pd_doc(db, draft, "Order", "#{draft}.Order.1", %({"name": "draft order"}))
          pd_doc(db, draft, "Status", "#{draft}.Status.1", %({"name": "open"}))

          result = pd_publish(db, draft, "orders", overwrite: true, documents: pd_selection(["Status"]))
          result.should be_a(Facet::Domain::Publish::Result)
          result.as(Facet::Domain::Publish::Result).documents_imported.should eq(1)

          pd_rows(db, "orders", "Status").should eq(["orders.Status.1"])
          # The live Order rows are untouched.
          pd_rows(db, "orders", "Order").should eq(["orders.Order.1"])
        end
      end

      it "refuses to import documents into a doctype the live target already defines" do
        with_db do |db|
          Facet::Mutation::Client.create(
            db, "core", "Domain", doc_id: "orders",
            content: %({"description": "live"}),
            actioner_id: "system:test",
          )
          pd_doctype(db, "orders", "Order", %({"name": {"type": "string"}}))

          draft = pd_draft(db)
          pd_doctype(db, draft, "Order", %({"name": {"type": "string"}}))
          pd_doc(db, draft, "Order", "#{draft}.Order.9", %({"name": "draft order"}))

          result = pd_publish(db, draft, "orders", overwrite: true, documents: pd_selection(["Order"]))
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("already exists on the target")
          err.message.should contain("orders.Order")

          pd_rows(db, "orders", "Order").should be_empty
        end
      end
    end
  end

  describe ".parse_documents_field" do
    it "answers no selection for an absent field" do
      selection, error = Facet::Domain::Publish.parse_documents_field(nil)
      selection.should be_nil
      error.should be_nil
    end

    it "answers no selection when import is false" do
      selection, error = Facet::Domain::Publish.parse_documents_field(JSON.parse(%({"import": false})))
      selection.should be_nil
      error.should be_nil
    end

    it "answers a whole-draft selection when import is true and doctypes is absent" do
      selection, error = Facet::Domain::Publish.parse_documents_field(JSON.parse(%({"import": true})))
      error.should be_nil
      selection.should_not be_nil
      selection.as(Facet::Domain::PublishDocuments::Selection).doctypes.should be_nil
    end

    it "answers the named doctypes" do
      selection, error = Facet::Domain::Publish.parse_documents_field(
        JSON.parse(%({"import": true, "doctypes": ["Status", "Category"]})),
      )
      error.should be_nil
      selection.as(Facet::Domain::PublishDocuments::Selection).doctypes.should eq(["Status", "Category"])
    end

    it "rejects a non-object field" do
      _selection, error = Facet::Domain::Publish.parse_documents_field(JSON.parse(%("yes")))
      error.should_not be_nil
      error.as(Facet::ServiceError).status.should eq(422)
    end

    it "rejects a doctypes entry that is not a string" do
      _selection, error = Facet::Domain::Publish.parse_documents_field(
        JSON.parse(%({"import": true, "doctypes": [1]})),
      )
      error.should_not be_nil
      error.as(Facet::ServiceError).message.should contain("only strings")
    end
  end
end
