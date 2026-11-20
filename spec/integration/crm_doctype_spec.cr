# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "json"
require "pg"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Registers all CRM doctypes via the service layer (no HTTP calls).
# Avoids HTTP calls in before_each, which would hit the corrupted handler
# chain when multiple spec files compile together.
def setup_crm_doctypes : Nil
  create_doctype(load_doctype_schema("crm.PipelineStage/definition.yml"))
  create_doctype(build_doctype_definition("crm.Company/definition.yml", "crm.Company/script.lua"))
  create_doctype(build_doctype_definition("crm.Prospect/definition.yml", "crm.Prospect/script.lua"))
  create_doctype(build_doctype_definition("crm.Customer/definition.yml"))
  create_doctype(build_doctype_definition("crm.Contact/definition.yml", "crm.Contact/script.lua"))
  create_doctype(build_doctype_definition("crm.CompanyMembership/definition.yml", "crm.CompanyMembership/script.lua"))
  create_doctype(build_doctype_definition("crm.Deal/definition.yml", "crm.Deal/script.lua"))
  create_doctype(build_doctype_definition("crm.Activity/definition.yml", "crm.Activity/script.lua"))
end

# ── Load schemas once for the suite ──────────────────────────────────────
PIPELINE_STAGE_DEFN     = load_doctype_schema("crm.PipelineStage/definition.yml")
COMPANY_DEFN            = build_doctype_definition("crm.Company/definition.yml", "crm.Company/script.lua")
PROSPECT_DEFN           = build_doctype_definition("crm.Prospect/definition.yml", "crm.Prospect/script.lua")
CUSTOMER_DEFN           = build_doctype_definition("crm.Customer/definition.yml")
CONTACT_DEFN            = build_doctype_definition("crm.Contact/definition.yml", "crm.Contact/script.lua")
COMPANY_MEMBERSHIP_DEFN = build_doctype_definition("crm.CompanyMembership/definition.yml", "crm.CompanyMembership/script.lua")
DEAL_DEFN               = build_doctype_definition("crm.Deal/definition.yml", "crm.Deal/script.lua")
ACTIVITY_DEFN           = build_doctype_definition("crm.Activity/definition.yml", "crm.Activity/script.lua")

# ────────────────────────────────────────────────────────────────────────────
# CRM Integration Test Suite
#
# These tests exercise a B2B CRM domain with Prospect/Customer lifecycle:
# PipelineStage, Company, Prospect, Customer, Contact, Deal, Activity.
#
# Scenarios covered:
#   1. Schema parsing and validation
#   2. Document-level field validation (types, enums, references)
#   3. Composition and cardinality (Company -> CompanyMembership)
#   4. Action definitions
#   5. Full HTTP CRUD (create, read, update, delete)
#   6. Child document routes (memberships under Company)
#   7. Named actions with state transitions
#     - Prospect.convert -> creates Customer (same Company), deletes Prospect
#     - Deal.win with company_id -> also converts any Prospect on that Company
#     - Deal.lose -> soft-deletes every Activity linked by deal_id
#   8. Children linkage (meta.parent_id set correctly on memberships under Company)
#   9. No child leakage across parents
#  10. Metadata tracking on mutations (action names in _reason)
# ────────────────────────────────────────────────────────────────────────────
describe "CRM integration" do
  around_each do |example|
    Facet::HTTP::AuthHandler.enabled = false
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = true
      redis_cleanup
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 1. Schema parsing and validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "doctype schemas" do
    it "parses crm.PipelineStage" do
      defn = PIPELINE_STAGE_DEFN
      defn.doctype.should eq("PipelineStage")
      defn.domain.should eq("crm")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Company" do
      defn = COMPANY_DEFN
      defn.doctype.should eq("Company")
      defn.domain.should eq("crm")
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.actions.keys.should contain("convert")
      defn.actions.keys.should contain("merge")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Prospect" do
      defn = PROSPECT_DEFN
      defn.doctype.should eq("Prospect")
      defn.domain.should eq("crm")
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.actions.keys.should contain("convert")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Customer" do
      defn = CUSTOMER_DEFN
      defn.doctype.should eq("Customer")
      defn.domain.should eq("crm")
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.actions.should be_empty
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Contact" do
      defn = CONTACT_DEFN
      defn.doctype.should eq("Contact")
      defn.domain.should eq("crm")
      # Contact is an aggregate root: it participates in companies through
      # crm.CompanyMembership rows (an N-N join doctype), not as a child of
      # Company carrying a company_id reference.
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Deal" do
      defn = DEAL_DEFN
      defn.doctype.should eq("Deal")
      defn.domain.should eq("crm")
      defn.aggregate_root.should be_true
      defn.actions.keys.should contain("move_stage")
      defn.actions.keys.should contain("win")
      defn.actions.keys.should contain("lose")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses crm.Activity" do
      defn = ACTIVITY_DEFN
      defn.doctype.should eq("Activity")
      defn.domain.should eq("crm")
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.actions.keys.should contain("complete")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "PipelineStage has expected fields" do
      fields = PIPELINE_STAGE_DEFN.fields
      fields.has_key?("name").should be_true
      fields.has_key?("order").should be_true
      fields.has_key?("probability_default").should be_true
      fields.has_key?("is_closing_stage").should be_true
      fields.has_key?("color").should be_true

      fields["name"].type.not_nil!.type_name.should eq("string")
      fields["name"].unique.should be_true
      fields["order"].type.not_nil!.type_name.should eq("integer")
      fields["order"].required.should be_true
      fields["probability_default"].type.not_nil!.type_name.should eq("integer")
      fields["is_closing_stage"].type.not_nil!.type_name.should eq("boolean")
    end

    it "Prospect has expected fields and no owned children" do
      fields = PROSPECT_DEFN.fields
      fields.has_key?("name").should be_true
      fields.has_key?("status").should be_true
      fields.has_key?("company_id").should be_true
      fields.has_key?("industry").should be_true
      fields.has_key?("owner_id").should be_true

      # The prospect's company name is replicated from the referenced Company.
      fields["name"].replicate.should_not be_nil
      fields["name"].replicate.not_nil!.via.should eq("company_id")
      fields["name"].replicate.not_nil!.field.should eq("name")

      # Prospect does not own contacts or deals ≈ they belong to the Company.
      PROSPECT_DEFN.children.empty?.should be_true
    end

    it "Customer has expected fields and no owned children" do
      fields = CUSTOMER_DEFN.fields
      fields.has_key?("name").should be_true
      fields.has_key?("status").should be_true
      fields.has_key?("company_id").should be_true

      # The customer's company name is replicated from the referenced Company.
      fields["name"].replicate.should_not be_nil
      fields["name"].replicate.not_nil!.via.should eq("company_id")
      fields["name"].replicate.not_nil!.field.should eq("name")

      CUSTOMER_DEFN.children.empty?.should be_true
    end

    it "Deal has expected fields, references, and computed fields" do
      fields = DEAL_DEFN.fields
      fields.has_key?("title").should be_true
      fields.has_key?("value").should be_true
      fields.has_key?("status").should be_true
      fields.has_key?("probability").should be_true
      fields.has_key?("company_id").should be_true
      fields.has_key?("primary_contact_id").should be_true
      fields.has_key?("stage_id").should be_true
      fields.has_key?("owner_id").should be_true
      fields.has_key?("weighted_value").should be_true

      # Computed field
      fields["weighted_value"].type.not_nil!.type_name.should eq("data")
      fields["weighted_value"].compute.should eq("deal_weighted_value")

      # Company reference (required) ≈ Deal belongs to a Company
      fields["company_id"].type.not_nil!.type_name.should eq("reference")
      fields["company_id"].doctype.should eq("crm.Company")
      fields["company_id"].required.should be_true

      # Money field
      fields["value"].type.not_nil!.type_name.should eq("money")

      # Activity is linked by reference (deal_id), not composition —
      # Deal owns no child doctypes.
      DEAL_DEFN.children.empty?.should be_true
    end

    it "Activity has computed field activity_preview" do
      fields = ACTIVITY_DEFN.fields
      fields.has_key?("activity_preview").should be_true
      fields["activity_preview"].type.not_nil!.type_name.should eq("data")
      fields["activity_preview"].compute.should eq("activity_preview")
      fields["activity_preview"].compute_when.should eq(["body"])
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. Document-level validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "document validation" do
    it "accepts a valid PipelineStage document" do
      doc = JSON.parse(%({
        "name": "Prospecting",
        "order": 1,
        "probability_default": 10,
        "is_closing_stage": false,
        "color": "#2196F3"
      }))
      Facet::Document::Validation.validate(doc, PIPELINE_STAGE_DEFN).should be_empty
    end

    it "accepts a valid Prospect document" do
      doc = JSON.parse(%({
        "status": "lead",
        "industry": "technology",
        "company_id": "crm.Company.1"
      }))
      Facet::Document::Validation.validate(doc, PROSPECT_DEFN).should be_empty
    end

    it "accepts a valid Customer document" do
      doc = JSON.parse(%({
        "status": "active"
      }))
      Facet::Document::Validation.validate(doc, CUSTOMER_DEFN).should be_empty
    end

    it "rejects a Prospect payload that sets the replicated name" do
      doc = JSON.parse(%({
        "name": "Hand Written",
        "company_id": "crm.Company.1"
      }))
      errs = Facet::Document::Validation.validate(doc, PROSPECT_DEFN)
      errs.any? { |e| e.field == "name" && e.code == "read_only" }.should be_true
    end

    it "rejects a Prospect with invalid status enum" do
      doc = JSON.parse(%({
        "status": "unknown"
      }))
      errs = Facet::Document::Validation.validate(doc, PROSPECT_DEFN)
      errs.any? { |e| e.field == "status" && e.message.includes?("unknown") }.should be_true
    end

    it "accepts a valid Contact document" do
      doc = JSON.parse(%({
        "first_name": "Alice",
        "last_name": "Smith",
        "email": "alice@acme.com",
        "job_title": "CTO",
        "role": "decision_maker",
        "is_primary": true
      }))
      Facet::Document::Validation.validate(doc, CONTACT_DEFN).should be_empty
    end

    it "rejects a Contact with invalid role enum" do
      doc = JSON.parse(%({
        "first_name": "Bob",
        "last_name": "Jones",
        "email": "bob@acme.com",
        "role": "ceo"
      }))
      errs = Facet::Document::Validation.validate(doc, CONTACT_DEFN)
      errs.any? { |e| e.field == "role" && e.message.includes?("ceo") }.should be_true
    end

    it "accepts a valid Deal document" do
      doc = JSON.parse(%({
        "title": "Big Deal",
        "value": #{money_json("100000.00", "USD")},
        "status": "open",
        "probability": 50,
        "stage_id": "crm.PipelineStage.some-stage-id",
        "company_id": "crm.Company.some-company-id"
      }))
      Facet::Document::Validation.validate(doc, DEAL_DEFN).should be_empty
    end

    it "accepts a valid Activity document" do
      doc = JSON.parse(%({
        "type": "meeting",
        "subject": "Project kickoff",
        "body": "Discussed timeline and milestones",
        "datetime": "2025-06-01T10:00:00Z",
        "duration_minutes": 60
      }))
      Facet::Document::Validation.validate(doc, ACTIVITY_DEFN).should be_empty
    end

    it "rejects an Activity with invalid type" do
      doc = JSON.parse(%({
        "type": "workshop",
        "subject": "Bad type",
        "datetime": "2025-06-01T10:00:00Z"
      }))
      errs = Facet::Document::Validation.validate(doc, ACTIVITY_DEFN)
      errs.any? { |e| e.field == "type" && e.message.includes?("workshop") }.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 3. Composition and cardinality
  # ──────────────────────────────────────────────────────────────────────────
  describe "composition and cardinality" do
    it "Contact has no member_of (free aggregate root)" do
      CONTACT_DEFN.member_of.should be_nil
      CONTACT_DEFN.aggregate_root.should be_true
    end

    it "Prospect is an aggregate root" do
      PROSPECT_DEFN.aggregate_root.should be_true
    end

    it "Customer is an aggregate root" do
      CUSTOMER_DEFN.aggregate_root.should be_true
    end

    it "Deal is an aggregate root" do
      DEAL_DEFN.aggregate_root.should be_true
    end

    it "Prospect has no children (contacts/deals are owned by Company)" do
      PROSPECT_DEFN.children.empty?.should be_true
    end

    it "Customer has no children (contacts/deals are owned by Company)" do
      CUSTOMER_DEFN.children.empty?.should be_true
    end

    it "Company has memberships as collection child (N-N join doctype)" do
      COMPANY_DEFN.children.has_key?("memberships").should be_true
      COMPANY_DEFN.children["memberships"].collection?.should be_true
      COMPANY_DEFN.children["memberships"].doctype.should eq("CompanyMembership")
    end

    it "Deal has no children; Activity references it by deal_id" do
      DEAL_DEFN.children.empty?.should be_true
      deal_field = ACTIVITY_DEFN.fields["deal_id"]
      deal_field.type.not_nil!.type_name.should eq("reference")
      deal_field.doctype.should eq("crm.Deal")
      deal_field.filters.try(&.includes?(Facet::Doctype::FilterCapability::Equality)).should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. Actions and workflow (schema-level contracts)
  # ──────────────────────────────────────────────────────────────────────────
  describe "actions" do
    it "Prospect defines convert action" do
      actions = PROSPECT_DEFN.actions
      actions.keys.should contain("convert")
    end

    it "Customer has no actions" do
      CUSTOMER_DEFN.actions.should be_empty
    end

    it "Deal defines expected actions with args" do
      actions = DEAL_DEFN.actions
      actions.keys.should contain("move_stage")
      actions.keys.should contain("win")
      actions.keys.should contain("lose")
    end

    it "Activity defines complete action" do
      actions = ACTIVITY_DEFN.actions
      actions.keys.should contain("complete")
    end

    it "no reserved action names used" do
      [PROSPECT_DEFN, DEAL_DEFN, ACTIVITY_DEFN].each do |defn|
        defn.actions.each_key do |action_name|
          Facet::Doctype::Validation::RESERVED_ACTIONS.includes?(action_name).should be_false
        end
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Full HTTP integration scenarios
  # ──────────────────────────────────────────────────────────────────────────

  describe "full HTTP lifecycle" do
    before_each do
      setup_crm_doctypes
    end

    # ────────────────────────────────────────────────────────────────────────
    # 5. CRUD operations via HTTP
    # ────────────────────────────────────────────────────────────────────────
    describe "CRUD operations" do
      it "creates and reads a PipelineStage" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Prospecting", "order": 1, "probability_default": 10}))

        read_resp = get_document_http("crm", "PipelineStage", stage_id)
        assert_http_status(read_resp, 200)
        read_data = parse_body(read_resp)
        read_data["data"]["name"].as_s.should eq("Prospecting")
        read_data["data"]["order"].as_i.should eq(1)
        read_data["data"]["probability_default"].as_i.should eq(10)
      end

      it "creates a Prospect with default status 'lead' and a replicated name" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Prospect Inc"}))
        body = %({"company_id": "#{company_id}"})
        resp = create_document_http("crm", "Prospect", body)
        assert_http_status(resp, 201)
        data = parse_body(resp)
        data["data"]["status"].as_s.should eq("lead")
        # The name is pulled from the referenced Company at create time.
        data["data"]["name"].as_s.should eq("Prospect Inc")
      end

      it "creates a Customer with default status 'active' and a replicated name" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Customer Inc"}))
        body = %({"company_id": "#{company_id}"})
        resp = create_document_http("crm", "Customer", body)
        assert_http_status(resp, 201)
        data = parse_body(resp)
        data["data"]["status"].as_s.should eq("active")
        # The name is pulled from the referenced Company at create time.
        data["data"]["name"].as_s.should eq("Customer Inc")
      end

      it "rejects a duplicate company name" do
        # Company.name carries the unique constraint the replica fields used
        # to duplicate; the replica on Prospect/Customer follows the source.
        body = %({"name": "Unique Corp"})
        resp1 = create_document_http("crm", "Company", body)
        assert_http_status(resp1, 201)
        resp2 = create_document_http("crm", "Company", body)
        assert_http_status(resp2, 422)
      end

      it "updates a Prospect via PATCH" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Prospect Co"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"company_id": "#{company_id}", "industry": "technology"}))

        patch_resp = patch_document_http("crm", "Prospect", prospect_id, %({"industry": "finance"}))
        assert_http_status(patch_resp, 200)

        read_resp = get_document_http("crm", "Prospect", prospect_id)
        assert_http_status(read_resp, 200)
        content = parse_body(read_resp)["data"]
        content["industry"].as_s.should eq("finance")
        content["name"].as_s.should eq("Prospect Co")
      end

      it "deletes a Prospect soft" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Doomed Co"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"company_id": "#{company_id}"}))

        delete_resp = delete_document_http("crm", "Prospect", prospect_id)
        assert_http_status(delete_resp, 204)

        read_resp = get_document_http("crm", "Prospect", prospect_id)
        assert_http_status(read_resp, 410)
      end

      it "lists documents with pagination" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Pagination Co"}))
        create_document_http("crm", "Prospect", %({"company_id": "#{company_id}"}))
        create_document_http("crm", "Prospect", %({"company_id": "#{company_id}"}))

        list_resp = list_documents_http("crm", "Prospect")
        assert_http_status(list_resp, 200)
        list_data = parse_body(list_resp)
        list_data["meta"]["count"].as_i.should eq(2)
        list_data["data"].as_a.size.should eq(2)
      end

      it "filters documents by field value" do
        create_document_http("crm", "PipelineStage", %({"name": "Prospecting", "order": 1}))
        create_document_http("crm", "PipelineStage", %({"name": "Negotiation", "order": 2}))

        list_resp = list_documents_http("crm", "PipelineStage", "filters[name__eq]=Prospecting")
        assert_http_status(list_resp, 200)
        list_data = parse_body(list_resp)
        list_data["meta"]["count"].as_i.should eq(1)
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # 6. Child document routes (Company -> Contact; Deal -> Activity)
    # ──────────────────────────────────────────────────────────────────────
    describe "child document routes" do
      it "creates a CompanyMembership as child of Company via nested route" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Prospect Co"}))

        # A contact is a free aggregate root -- create it directly, no
        # company_id field (the membership row holds the reference).
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "Alice", "last_name": "Smith", "email": "alice@prospect.com"}))

        # The membership row is the only Company child -- it carries the
        # contact reference plus the per-company role.
        membership_id = create_child_doc_id_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_id}", "role": "primary"}))

        read_resp = get_document_http("crm", "CompanyMembership", membership_id)
        assert_http_status(read_resp, 200)
        content = parse_body(read_resp)["data"]
        content["contact"].as_s.should eq("crm.Contact.#{contact_id}")
        content["role"].as_s.should eq("primary")
        meta = parse_body(read_resp)["meta"]
        meta["parent_id"].as_s.should eq(company_id)
      end

      it "lists child CompanyMemberships under a Company" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Multi Contact Co"}))

        # Two contacts (aggregate roots) and two membership rows under the
        # same company, each pointing at one of the contacts.
        contact_a_id = create_doc_id_http("crm", "Contact", %({"first_name": "A", "last_name": "One", "email": "a1@test.com"}))
        contact_b_id = create_doc_id_http("crm", "Contact", %({"first_name": "B", "last_name": "Two", "email": "b2@test.com"}))
        create_child_document_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_a_id}", "role": "primary"}))
        create_child_document_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_b_id}", "role": "secondary"}))

        list_resp = list_nested_http("crm", "Company", company_id, "memberships")
        assert_http_status(list_resp, 200)
        list_data = parse_body(list_resp)
        list_data["meta"]["count"].as_i.should eq(2)
      end

      it "creates a Deal as a root document referencing a Company" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Prospecting", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Deal Parent"}))

        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Prospect Deal", "value": #{money_json("50000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        read_resp = get_document_http("crm", "Deal", deal_id)
        assert_http_status(read_resp, 200)
        content = parse_body(read_resp)["data"]
        content["title"].as_s.should eq("Prospect Deal")
        content["status"].as_s.should eq("open")
        content["company_id"].as_s.should eq("crm.Company.#{company_id}")
      end

      it "creates a Deal referencing a Customer's Company" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Prospecting", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Customer Co"}))

        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Customer Deal", "value": #{money_json("75000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        read_resp = get_document_http("crm", "Deal", deal_id)
        assert_http_status(read_resp, 200)
        content = parse_body(read_resp)["data"]
        content["title"].as_s.should eq("Customer Deal")
        content["status"].as_s.should eq("open")
      end

      it "creates an Activity referencing a Deal and lists it by deal_id filter" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Dev", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Act Parent"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Deal with activity", "value": #{money_json("1000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        activity_id = create_doc_id_http("crm", "Activity", %({"type": "meeting", "subject": "Initial call", "body": "Discussed requirements", "datetime": "2025-06-10T14:00:00Z", "duration_minutes": 30, "deal_id": "#{deal_id}"}))

        read_resp = get_document_http("crm", "Activity", activity_id)
        assert_http_status(read_resp, 200)
        content = parse_body(read_resp)["data"]
        content["type"].as_s.should eq("meeting")
        content["subject"].as_s.should eq("Initial call")
        content["completed"].as_bool.should be_false
        content["deal_id"].as_s.should eq("crm.Deal.#{deal_id}")

        # The Deal-side relation lists activities by deal_id equality —
        # the dual-form reference clause accepts the bare row id.
        list_resp = list_documents_http("crm", "Activity", "filters[deal_id__eq]=#{deal_id}")
        assert_http_status(list_resp, 200)
        list_data = parse_body(list_resp)
        list_data["meta"]["count"].as_i.should eq(1)
        list_data["data"].as_a.first["data"]["subject"].as_s.should eq("Initial call")
      end

      # 8a. Children linkage: Verify meta.parent_id is set on child documents.
      # The Company -> CompanyMembership edge is the only owned-composition
      # link in the new model; the membership carries the contact reference.
      it "sets meta.parent_id on child documents" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Parent Test"}))
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "Link", "last_name": "Test", "email": "link@test.com"}))

        membership_id = create_child_doc_id_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_id}", "role": "primary"}))

        read_resp = get_document_http("crm", "CompanyMembership", membership_id)
        assert_http_status(read_resp, 200)
        meta = parse_body(read_resp)["meta"]
        meta["parent_id"].as_s.should eq(company_id)
      end

      # 8b. No child leakage: membership rows under one company do not appear
      # under another. (The inverse N-N direction -- "memberships of a contact"
      # -- is filtered via the contact__eq query filter, not the parent route.)
      it "prevents child leakage between parents" do
        company_a_id = create_doc_id_http("crm", "Company", %({"name": "Parent A"}))
        company_b_id = create_doc_id_http("crm", "Company", %({"name": "Parent B"}))

        contact_a_id = create_doc_id_http("crm", "Contact", %({"first_name": "Alice", "last_name": "A", "email": "alice@a.com"}))
        contact_b_id = create_doc_id_http("crm", "Contact", %({"first_name": "Bob", "last_name": "B", "email": "bob@b.com"}))
        create_child_document_http("crm", "Company", company_a_id, "memberships", %({"contact": "crm.Contact.#{contact_a_id}", "role": "primary"}))
        create_child_document_http("crm", "Company", company_b_id, "memberships", %({"contact": "crm.Contact.#{contact_b_id}", "role": "primary"}))

        # List children of Company A
        list_resp_a = list_nested_http("crm", "Company", company_a_id, "memberships")
        assert_http_status(list_resp_a, 200)
        list_a = parse_body(list_resp_a)

        # List children of Company B
        list_resp_b = list_nested_http("crm", "Company", company_b_id, "memberships")
        assert_http_status(list_resp_b, 200)
        list_b = parse_body(list_resp_b)

        # Each parent should see exactly 1 membership (its own)
        list_a["meta"]["count"].as_i.should eq(1)
        list_a["data"].as_a.size.should eq(1)
        list_a["data"].as_a.first["data"]["contact"].as_s.should eq("crm.Contact.#{contact_a_id}")

        list_b["meta"]["count"].as_i.should eq(1)
        list_b["data"].as_a.size.should eq(1)
        list_b["data"].as_a.first["data"]["contact"].as_s.should eq("crm.Contact.#{contact_b_id}")
      end

      # 8c. Cascade delete: deleting a Company tombstones its owned
      # CompanyMembership children. The platform primitive
      # Document::Delete#cascade_delete_children walks every children: entry
      # whose target declares member_of == parent_doctype, so the Company ->
      # CompanyMembership edge is walked automatically -- no Lua hook on
      # Company is needed (unlike Contact, which is an aggregate root and
      # owns no membership rows).
      it "cascade-deletes CompanyMembership children when Company is deleted" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "Cascade Co"}))
        contact_a_id = create_doc_id_http("crm", "Contact", %({"first_name": "C1", "last_name": "A", "email": "c1@casc.com"}))
        contact_b_id = create_doc_id_http("crm", "Contact", %({"first_name": "C2", "last_name": "B", "email": "c2@casc.com"}))
        membership_a_id = create_child_doc_id_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_a_id}", "role": "primary"}))
        membership_b_id = create_child_doc_id_http("crm", "Company", company_id, "memberships", %({"contact": "crm.Contact.#{contact_b_id}", "role": "secondary"}))

        # Sanity: both memberships are live before the delete.
        assert_http_status(get_document_http("crm", "CompanyMembership", membership_a_id), 200)
        assert_http_status(get_document_http("crm", "CompanyMembership", membership_b_id), 200)

        delete_resp = delete_document_http("crm", "Company", company_id)
        assert_http_status(delete_resp, 204)

        # The Company is gone (410 Gone).
        assert_http_status(get_document_http("crm", "Company", company_id), 410)

        # Both owned membership rows are tombstoned by the cascade.
        assert_http_status(get_document_http("crm", "CompanyMembership", membership_a_id), 410)
        assert_http_status(get_document_http("crm", "CompanyMembership", membership_b_id), 410)

        # The contacts survive: they are aggregate roots, not owned by the
        # company. This is the asymmetry that requires the Lua delete hook on
        # Contact (the inverse direction) but no hook on Company.
        assert_http_status(get_document_http("crm", "Contact", contact_a_id), 200)
        assert_http_status(get_document_http("crm", "Contact", contact_b_id), 200)
      end

      # 8d. Activity is a standalone aggregate — it carries no parent_id
      # linkage. The Deal side lists activities by the deal_id reference
      # filter (covered above).
    end

    # ────────────────────────────────────────────────────────────────────────
    # 7. Named actions with state transitions
    # ────────────────────────────────────────────────────────────────────────
    describe "Prospect actions" do
      it "convert promotes a Prospect to Customer without transferring children" do
        # Create a Company the Prospect and its contacts/deals reference
        company_id = create_doc_id_http("crm", "Company", %({"name": "ConvertCo"}))

        # Create a prospect referencing the company (the name comes from the
        # Company through replication).
        prospect_id = create_doc_id_http("crm", "Prospect", %({"status": "lead", "industry": "technology", "company_id": "#{company_id}"}))

        # Create a contact as a free aggregate root. The per-company
        # association now lives on a CompanyMembership row; for this scenario
        # the contact just needs to survive the prospect's convert unscathed.
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "Transfer", "last_name": "Me", "email": "transfer@test.com"}))

        # Create a deal referencing the company
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Pipeline", "order": 1}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Transfer Deal", "value": #{money_json("10000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        # Execute convert action - this creates a Customer (same Company) and deletes the Prospect.
        # Contacts and deals are owned by the Company, so nothing is transferred.
        action_resp = execute_action_http("crm", "Prospect", prospect_id, "convert")
        assert_http_status(action_resp, 200)
        action_data = parse_body(action_resp)

        # Prospect should no longer be available (deleted)
        read_prospect = get_document_http("crm", "Prospect", prospect_id)
        assert_http_status(read_prospect, 410)

        # The action response should indicate the customer created
        action_data["data"]["converted_to_customer_id"].should_not be_nil
        customer_id = action_data["data"]["converted_to_customer_id"].as_s

        # Verify the Customer exists and references the same Company
        read_customer = get_document_http("crm", "Customer", customer_id)
        assert_http_status(read_customer, 200)
        customer_data = parse_body(read_customer)["data"]
        customer_data["name"].as_s.should eq("ConvertCo")
        customer_data["status"].as_s.should eq("active")
        customer_data["industry"].as_s.should eq("technology")
        customer_data["company_id"].as_s.should eq("crm.Company.#{company_id}")

        # The contact survives unchanged.
        read_contact = get_document_http("crm", "Contact", contact_id)
        assert_http_status(read_contact, 200)
        # The contact has no company_id field anymore; verify it survived by
        # its email (the unique invariant that outlives the prospect convert).
        contact_content = parse_body(read_contact)["data"]
        contact_content["email"].as_s.should eq("transfer@test.com")

        # The deal survives unchanged, still referencing the original Company
        read_deal = get_document_http("crm", "Deal", deal_id)
        assert_http_status(read_deal, 200)
        deal_content = parse_body(read_deal)["data"]
        deal_content["company_id"].as_s.should eq("crm.Company.#{company_id}")
      end

      it "convert rejects if prospect is already converted" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "OnceOnly Co"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"company_id": "#{company_id}"}))

        # First convert succeeds
        action_resp = execute_action_http("crm", "Prospect", prospect_id, "convert")
        assert_http_status(action_resp, 200)

        # Second convert fails because the prospect was deleted (expect 410 or 422).
        second_resp = execute_action_http("crm", "Prospect", prospect_id, "convert")
        [409, 410, 422].includes?(second_resp.status_code).should be_true
      end
    end

    describe "Deal actions" do
      it "win closes a deal as won with actual_close_date" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Closing", "order": 5}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Win Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Winnable Deal", "value": #{money_json("20000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        action_resp = execute_action_http("crm", "Deal", deal_id, "win", %({"actual_close_date": "2025-06-15"}))
        assert_http_status(action_resp, 200)

        read_resp = get_document_http("crm", "Deal", deal_id)
        content = parse_body(read_resp)["data"]
        content["status"].as_s.should eq("won")
        content["actual_close_date"].as_s.should eq("2025-06-15")
      end

      it "win on a deal referencing a Prospect converts the Prospect to Customer" do
        # Set up a Company, a Prospect referencing it, a contact and a deal.
        company_id = create_doc_id_http("crm", "Company", %({"name": "WinConvertCo"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"status": "lead", "industry": "finance", "company_id": "#{company_id}"}))
        # Create a contact as a free aggregate root (no company_id on Contact).
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "Win", "last_name": "Convert", "email": "winconv@test.com"}))

        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Final", "order": 10}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Winning Prospect Deal", "value": #{money_json("50000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        # Win the deal - this should also convert the prospect
        action_resp = execute_action_http("crm", "Deal", deal_id, "win", %({"actual_close_date": "2025-06-20"}))
        assert_http_status(action_resp, 200)

        # Verify the deal is won
        read_deal = get_document_http("crm", "Deal", deal_id)
        deal_content = parse_body(read_deal)["data"]
        deal_content["status"].as_s.should eq("won")
        deal_content["actual_close_date"].as_s.should eq("2025-06-20")

        # Verify the prospect was deleted
        read_prospect = get_document_http("crm", "Prospect", prospect_id)
        assert_http_status(read_prospect, 410)

        # A Customer referencing the same Company was created.
        with_db do |db|
          customer_rows = db.query_all(
            "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2",
            "crm", "Customer",
            as: String
          )
          customer_rows.empty?.should be_false
        end

        # The deal keeps referencing the original Company (no transfer).
        deal_content["company_id"].as_s.should eq("crm.Company.#{company_id}")

        # The contact survives unchanged.
        read_contact = get_document_http("crm", "Contact", contact_id)
        assert_http_status(read_contact, 200)
        contact_content = parse_body(read_contact)["data"]
        contact_content["email"].as_s.should eq("winconv@test.com")
      end

      it "lose closes a deal as lost with reason and soft-deletes its activities" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Qualification", "order": 2}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Lost Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Losing Deal", "value": #{money_json("5000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        # Two activities linked to this deal, one linked elsewhere —
        # only the deal's activities must go.
        linked_a = create_doc_id_http("crm", "Activity", %({"type": "call", "subject": "Linked call", "datetime": "2025-04-01T09:00:00Z", "deal_id": "#{deal_id}"}))
        linked_b = create_doc_id_http("crm", "Activity", %({"type": "note", "subject": "Linked note", "datetime": "2025-04-02T09:00:00Z", "deal_id": "#{deal_id}"}))
        other_deal_id = create_doc_id_http("crm", "Deal", %({"title": "Other Deal", "value": #{money_json("1000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))
        untouched = create_doc_id_http("crm", "Activity", %({"type": "email", "subject": "Other deal activity", "datetime": "2025-04-03T09:00:00Z", "deal_id": "#{other_deal_id}"}))

        action_resp = execute_action_http("crm", "Deal", deal_id, "lose", %({"reason": "Budget too low", "actual_close_date": "2025-05-01"}))
        assert_http_status(action_resp, 200)

        read_resp = get_document_http("crm", "Deal", deal_id)
        content = parse_body(read_resp)["data"]
        content["status"].as_s.should eq("lost")
        content["lost_reason"].as_s.should eq("Budget too low")
        content["actual_close_date"].as_s.should eq("2025-05-01")

        # The deal's activities are soft-deleted (410 tombstones)...
        assert_http_status(get_document_http("crm", "Activity", linked_a), 410)
        assert_http_status(get_document_http("crm", "Activity", linked_b), 410)

        # ...and every other activity survives.
        assert_http_status(get_document_http("crm", "Activity", untouched), 200)
      end

      it "win rejects if deal is not open" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Late", "order": 9}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Already Lost"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Closed Deal", "value": #{money_json("1000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        execute_action_http("crm", "Deal", deal_id, "lose", %({"reason": "No need", "actual_close_date": "2025-04-01"}))

        action_resp = execute_action_http("crm", "Deal", deal_id, "win", %({"actual_close_date": "2025-06-15"}))
        assert_http_status(action_resp, 422)
      end

      it "move_stage advances the deal to a new stage" do
        stage1_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Qualification", "order": 1}))
        stage2_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Proposal", "order": 2}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Move Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Moving Deal", "value": #{money_json("7500.00", "USD")}, "stage_id": "#{stage1_id}", "company_id": "#{company_id}"}))

        action_resp = execute_action_http("crm", "Deal", deal_id, "move_stage", %({"target_stage_id": "#{stage2_id}"}))
        assert_http_status(action_resp, 200)

        read_resp = get_document_http("crm", "Deal", deal_id)
        content = parse_body(read_resp)["data"]
        content["stage_id"].as_s.should eq("crm.PipelineStage.#{stage2_id}")
      end

      it "move_stage rejects moving to the same stage" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Same", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Same Stage Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Same Stage Deal", "value": #{money_json("3000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        action_resp = execute_action_http("crm", "Deal", deal_id, "move_stage", %({"target_stage_id": "#{stage_id}"}))
        assert_http_status(action_resp, 422)
      end
    end

    describe "Activity actions" do
      it "complete marks a task as completed" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Task Stage", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Task Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Task Deal", "value": #{money_json("100.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))
        activity_id = create_doc_id_http("crm", "Activity", %({"type": "task", "subject": "Follow up", "datetime": "2025-06-01T00:00:00Z", "deal_id": "#{deal_id}"}))

        action_resp = execute_action_http("crm", "Activity", activity_id, "complete")
        assert_http_status(action_resp, 200)

        read_resp = get_document_http("crm", "Activity", activity_id)
        content = parse_body(read_resp)["data"]
        content["completed"].as_bool.should be_true
      end

      it "complete rejects a non-task activity" do
        activity_id = create_doc_id_http("crm", "Activity", %({"type": "note", "subject": "Just a note", "datetime": "2025-06-01T00:00:00Z"}))

        action_resp = execute_action_http("crm", "Activity", activity_id, "complete")
        assert_http_status(action_resp, 422)
      end
    end

    # ────────────────────────────────────────────────────────────────────────
    # 9. Metadata tracking on mutations
    # ────────────────────────────────────────────────────────────────────────
    describe "mutation metadata" do
      it "action mutations stamp a structured cause with parent linkage on nested document.* creates" do
        company_id = create_doc_id_http("crm", "Company", %({"name": "MetaTest Co"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"company_id": "#{company_id}"}))

        # Execute convert (event name: "converted")
        action_resp = execute_action_http("crm", "Prospect", prospect_id, "convert")
        assert_http_status(action_resp, 200)

        # The Prospect.convert Lua script calls document.create("Customer", ...).
        # The resulting Customer create mutation must carry a structured
        # cause on the typed provenance columns: kind=action, event=converted,
        # and `cause_parent` bound to the action's own update mutation id —
        # not in `arguments._reason`.
        with_db do |db|
          customer_rows = db.query_all(
            "SELECT cause_kind, cause_event, cause_parent FROM mutations WHERE domain = $1 AND doc_type = $2 AND action = 'create' ORDER BY emitted_at DESC LIMIT 5",
            "crm", "Customer",
            as: {String, String?, String?}
          )

          customer_rows.any? do |row|
            row[0] == "action" &&
              row[1] == "converted" &&
              !row[2].nil?
          end.should be_true
        end
      end

      it "deal win action stamps the event name as cause.event on the action update" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "WinMeta", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "MetaCustomer Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Meta Deal", "value": #{money_json("1000.00", "USD")}, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        execute_action_http("crm", "Deal", deal_id, "win", %({"actual_close_date": "2025-07-01"}))

        with_db do |db|
          # The Document::Action stamps its own update mutation with a
          # structured cause: kind=action, name=win, event=won.
          deal_rows = db.query_all(
            "SELECT cause_kind, cause_name, cause_event FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update' ORDER BY emitted_at DESC LIMIT 5",
            "crm", "Deal", deal_id,
            as: {String, String?, String?}
          )

          deal_rows.any? do |row|
            row[0] == "action" &&
              row[1] == "win" &&
              row[2] == "won"
          end.should be_true
        end
      end
    end

    # ────────────────────────────────────────────────────────────────────────
    # 8. Computed fields (basic — kept from original)
    # ────────────────────────────────────────────────────────────────────────
    describe "computed fields" do
      it "Deal weighted_value is computed from value and probability" do
        stage_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Weighted Stage", "order": 1}))
        company_id = create_doc_id_http("crm", "Company", %({"name": "Weighted Co"}))
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Weighted Deal", "value": #{money_json("100000.00", "USD")}, "probability": 75, "stage_id": "#{stage_id}", "company_id": "#{company_id}"}))

        read_resp = get_document_http("crm", "Deal", deal_id)
        content = parse_body(read_resp)["data"]
        content["weighted_value"].as_f.should eq(75000.0)
      end

      it "Contact full_name is computed from first_name and last_name" do
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "Jane", "last_name": "Doe", "email": "jane@computed.com"}))

        read_resp = get_document_http("crm", "Contact", contact_id)
        content = parse_body(read_resp)["data"]
        content["full_name"].as_s.should eq("Jane Doe")
      end

      it "Activity preview is first 200 chars of body" do
        body_text = "A" * 500
        activity_id = create_doc_id_http("crm", "Activity", %({"type": "note", "subject": "Long note", "body": "#{body_text}", "datetime": "2025-06-01T00:00:00Z"}))

        read_resp = get_document_http("crm", "Activity", activity_id)
        content = parse_body(read_resp)["data"]
        content["activity_preview"].as_s.size.should eq(200)
      end
    end

    # ────────────────────────────────────────────────────────────────────────
    # 9. End-to-end scenario: full pipeline
    # ────────────────────────────────────────────────────────────────────────
    describe "full pipeline scenario" do
      it "creates a prospect, adds contacts, opens a deal, wins it (auto-converts)" do
        # 1. Create pipeline stages
        stage1_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Prospecting", "order": 1, "probability_default": 10}))
        stage2_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Qualification", "order": 2, "probability_default": 25}))
        stage3_id = create_doc_id_http("crm", "PipelineStage", %({"name": "Proposal", "order": 3, "probability_default": 50}))

        # 2. Create a Company and a Prospect referencing it
        company_id = create_doc_id_http("crm", "Company", %({"name": "FullPipeline Co"}))
        prospect_id = create_doc_id_http("crm", "Prospect", %({"industry": "technology", "status": "lead", "company_id": "#{company_id}"}))

        # 3. Add a contact (free aggregate root -- no company_id field on
        #    Contact in the new N-N model).
        contact_id = create_doc_id_http("crm", "Contact", %({"first_name": "John", "last_name": "Doe", "email": "john@pipeline.com", "role": "decision_maker"}))

        # 4. Create a deal referencing the Company
        deal_id = create_doc_id_http("crm", "Deal", %({"title": "Pipeline Deal", "value": #{money_json("100000.00", "USD")}, "probability": 10, "stage_id": "#{stage1_id}", "company_id": "#{company_id}", "primary_contact_id": "#{contact_id}"}))

        # 5. Add activity to the deal (flat create with deal_id reference)
        activity_resp = create_document_http("crm", "Activity", %({"type": "meeting", "subject": "Discovery call", "body": "Discussed needs", "datetime": "2025-01-15T10:00:00Z", "deal_id": "#{deal_id}"}))
        assert_http_status(activity_resp, 201)

        # 6. Move deal through stages
        execute_action_http("crm", "Deal", deal_id, "move_stage", %({"target_stage_id": "#{stage2_id}"}))
        execute_action_http("crm", "Deal", deal_id, "move_stage", %({"target_stage_id": "#{stage3_id}"}))

        # 7. Win the deal -- this should auto-convert the prospect to a customer
        win_resp = execute_action_http("crm", "Deal", deal_id, "win", %({"actual_close_date": "2025-06-01"}))
        assert_http_status(win_resp, 200)

        # 8. Verify deal final state
        read_deal = get_document_http("crm", "Deal", deal_id)
        deal_content = parse_body(read_deal)["data"]
        deal_content["status"].as_s.should eq("won")
        deal_content["stage_id"].as_s.should eq("crm.PipelineStage.#{stage3_id}")
        deal_content["actual_close_date"].as_s.should eq("2025-06-01")

        # 9. Verify prospect is gone
        read_prospect = get_document_http("crm", "Prospect", prospect_id)
        assert_http_status(read_prospect, 410)

        # 10. Verify a Customer was created referencing the same Company
        with_db do |db|
          customer_rows = db.query_all(
            "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2",
            "crm", "Customer",
            as: String
          )
          customer_rows.empty?.should be_false
        end

        # 11. Verify contact survives unchanged. Contact is a free aggregate
        # root (no company_id field -- the per-company link lives on a
        # CompanyMembership row). Verify the contact survived the convert by
        # its email, the unique invariant that outlives the prospect deletion.
        read_contact = get_document_http("crm", "Contact", contact_id)
        contact_content = parse_body(read_contact)["data"]
        contact_content["email"].as_s.should eq("john@pipeline.com")
      end
    end

    # ────────────────────────────────────────────────────────────────────────
    # Search (trigram substring over the accent-folded `search` column)
    # ────────────────────────────────────────────────────────────────────────
    it "searches a Company by its full domain value (acme.com)" do
      create_document_http("crm", "Company", %({"name": "Acme Corp", "domain_name": "acme.com"}))
      create_document_http("crm", "Company", %({"name": "Globex Inc", "domain_name": "globex.com"}))

      # The doctype declares `search: "{{ name }} {{ domain_name }}"`, so the
      # search column is "acme corp acme.com". A full domain value with a
      # literal dot must match the company whose domain_name is acme.com.
      list_resp = list_documents_http("crm", "Company", "filters[search]=acme.com")
      assert_http_status(list_resp, 200)
      list_data = parse_body(list_resp)
      list_data["meta"]["count"].as_i.should eq(1)
      list_data["data"].as_a.first["data"]["name"].as_s.should eq("Acme Corp")
    end

    it "answers 422 for a suffixed search filter key (search__match)" do
      # The bare `search` key is the only production of the filter grammar;
      # a suffixed form is refused by the strict grammar (B-20) instead of
      # silently widening to a contains match.
      list_resp = list_documents_http("crm", "Company", "filters[search__match]=acme.com")
      assert_http_status(list_resp, 422)
      error = parse_body(list_resp)["error"].as_s
      error.should contain("'match'")
      error.should contain("'search'")
    end
  end
end
