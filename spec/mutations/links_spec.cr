# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/audit"

# Integration specs for the `links` column on projections.
#
# Exercises the full Document::Create / Document::Update pipeline so the
# `Document::Links.set_guc` → trigger → `projections.links` round-trip is
# verified end-to-end.
LINKS_REF_TYPE      = Facet::Doctype::FieldType.parse("reference")
LINKS_LONGTEXT_TYPE = Facet::Doctype::FieldType.parse("longtext")

# Opens a fresh DB connection (spec_helper has already run db_reset).
def links_with_db(&)
  database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL is required") }
  DB.open(database_url) do |db|
    db.using_connection do |conn|
      yield conn
    end
  end
end

# Creates a `links-test.WorkOrder` doctype with one reference and one
# longtext field, then yields `(db, doc_id)` after creating a document.
# Registers a minimal `hr.Employee` doctype plus the target rows so the
# `assignee` reference values pass the authoring-time existence check.
def with_workorder_doc(initial_body : String, &)
  links_with_db do |db|
    ensure_domain(db, "links-test")
    ensure_domain(db, "hr")
    employee_defn = Facet::Doctype::DoctypeDefinition.from_json(
      %({"doctype": "Employee", "domain": "hr", "schema_version": 1, "fields": {"name": {"type": "string"}}}),
    )
    doctype_result = Facet::Document::Create.call(db, "core", "DocType", employee_defn.to_json, Facet::RBAC::AuthContext.system)
    doctype_result.should be_a(Facet::Document::Create::Result)
    ["01AAA", "01BBB"].each do |employee_id|
      row = Facet::Document::Create.call(db, "hr", "Employee", %({"name": "Employee #{employee_id}"}), Facet::RBAC::AuthContext.system, doc_id: employee_id)
      row.should be_a(Facet::Document::Create::Result)
    end
    defn = Facet::Doctype::DoctypeDefinition.new(
      doctype: "WorkOrder",
      domain: "links-test",
      fields: {
        "assignee" => Facet::Doctype::FieldDefinition.new(
          type: LINKS_REF_TYPE, doctype: "hr.Employee",
        ),
        "notes" => Facet::Doctype::FieldDefinition.new(type: LINKS_LONGTEXT_TYPE),
      },
    )
    create_result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    create_result.should be_a(Facet::Document::Create::Result)

    doc_result = Facet::Document::Create.call(db, "links-test", "WorkOrder", initial_body, Facet::RBAC::AuthContext.system)
    doc_result.should be_a(Facet::Document::Create::Result)
    doc = doc_result.as(Facet::Document::Create::Result)

    yield db, doc.projection.id
  end
end

describe "Projection links column" do
  describe "create" do
    it "populates links from a reference field value" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01AAA"]))
      end
    end

    it "populates links from markdown links in a longtext field" do
      body = %({"notes": "See [Alice](urn:facet:hr:Employee:01BBB)."})
      with_workorder_doc(body) do |db, doc_id|
        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01BBB"]))
      end
    end

    it "merges URNs from reference and longtext fields, deduplicated" do
      body = %({
        "assignee": "hr.Employee.01AAA",
        "notes": "Cc [Alice](urn:facet:hr:Employee:01AAA) and [Bob](urn:facet:hr:Employee:01BBB)."
      })
      with_workorder_doc(body) do |db, doc_id|
        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01AAA","urn:facet:hr:Employee:01BBB"]))
      end
    end

    it "stores an empty array when no links are present" do
      with_workorder_doc(%({"notes": "no links here"})) do |db, doc_id|
        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse("[]")
      end
    end

    it "lands an account-URN mention and a cross-doctype reference link from a longtext" do
      account_id = Facet::Util::ScriptHelpers.ulid
      body = %({"notes": "Mention [Alice](urn:facet:iam:Account:#{account_id}) and see [the owner](urn:facet:hr:Employee:01AAA)."})
      with_workorder_doc(body) do |db, doc_id|
        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        # Both colon-form URNs land: the account mention (iam.Account) and
        # the document reference to another doctype (hr.Employee).
        proj.links.should eq JSON.parse(%(["urn:facet:iam:Account:#{account_id}","urn:facet:hr:Employee:01AAA"]))
      end
    end
  end

  describe "update" do
    it "replaces the URN when a reference is updated" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        # Update to a different reference.
        update = Facet::Document::Update.call(
          db, "links-test", "WorkOrder", doc_id,
          %({"assignee": "hr.Employee.01BBB"}),
          Facet::RBAC::AuthContext.system,
        )
        update.should be_a(Facet::Document::Update::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01BBB"]))
      end
    end

    it "removes the URN when a reference is set to null" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        update = Facet::Document::Update.call(
          db, "links-test", "WorkOrder", doc_id,
          %({"assignee": null}),
          Facet::RBAC::AuthContext.system,
        )
        update.should be_a(Facet::Document::Update::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse("[]")
      end
    end

    it "picks up new markdown links when a longtext is edited" do
      with_workorder_doc(%({"notes": "no links yet"})) do |db, doc_id|
        update = Facet::Document::Update.call(
          db, "links-test", "WorkOrder", doc_id,
          %({"notes": "Now [linked](urn:facet:hr:Employee:01CCC)."}),
          Facet::RBAC::AuthContext.system,
        )
        update.should be_a(Facet::Document::Update::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01CCC"]))
      end
    end

    it "drops a URN when the markdown link is removed from a longtext" do
      body = %({"notes": "See [Alice](urn:facet:hr:Employee:01AAA)."})
      with_workorder_doc(body) do |db, doc_id|
        update = Facet::Document::Update.call(
          db, "links-test", "WorkOrder", doc_id,
          %({"notes": "Link removed."}),
          Facet::RBAC::AuthContext.system,
        )
        update.should be_a(Facet::Document::Update::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        proj.links.should eq JSON.parse("[]")
      end
    end
  end

  describe "delete" do
    it "keeps links on delete (tombstone retention)" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        del = Facet::Document::Delete.call(
          db, "links-test", "WorkOrder", doc_id,
          Facet::RBAC::AuthContext.system,
        )
        del.should be_a(Facet::Document::Delete::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        # The tombstone keeps its pre-delete payload (content/links/search
        # retention) so per-emit RBAC checks can scope-evaluate `deleted`
        # events. The payload is cleared later by
        # `Cron::TombstoneContentPrune` after the retention window.
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01AAA"]))
        proj.content.should eq JSON.parse(%({"assignee": "hr.Employee.01AAA"}))
      end
    end
  end

  describe "snapshot (via audit rollback)" do
    it "recomputes links from the rolled-back content" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        # First, update to a new reference.
        Facet::Document::Update.call(
          db, "links-test", "WorkOrder", doc_id,
          %({"assignee": "hr.Employee.01BBB"}),
          Facet::RBAC::AuthContext.system,
        )

        # Fetch the latest two mutations to find the create mutation id.
        mutations = db.query_all(
          "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx ASC",
          "links-test", "WorkOrder", doc_id, as: String)
        create_mut_id = mutations.first

        # Roll back to the create mutation.
        rollback = Facet::Audit::Rollback.call(
          db, create_mut_id, Facet::RBAC::AuthContext.system,
        )
        rollback.should be_a(Facet::Audit::Rollback::Result)

        proj = Facet::Mutation::Client.fetch_projection(db, "links-test", "WorkOrder", doc_id)
        # After rollback to the create state, the assignee should be back
        # to 01AAA and links recomputed.
        proj.links.should eq JSON.parse(%(["urn:facet:hr:Employee:01AAA"]))
      end
    end
  end

  describe "GIN index — containment queries" do
    it "supports finding documents that link to a given URN" do
      with_workorder_doc(%({"assignee": "hr.Employee.01AAA"})) do |db, doc_id|
        # The GIN index supports the `@>` containment operator on the
        # `links` jsonb column. We query for documents linking to a
        # specific URN.
        results = db.query_all(
          "SELECT id FROM projections \
           WHERE domain = $1 AND doc_type = $2 \
             AND deleted_at IS NULL \
             AND links @> $3::jsonb",
          "links-test", "WorkOrder",
          %(["urn:facet:hr:Employee:01AAA"]),
          as: String,
        )
        results.should contain(doc_id)
      end
    end
  end
end
