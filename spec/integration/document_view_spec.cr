# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../../src/rbac"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# ─────────────────────────────────────────────────────────────────────────────────
# DocumentView integration — schema, document validation, and child CRUD
#
# These tests exercise the full lifecycle of core.DocumentView, a child doctype
# of core.DocType. They cover:
#   - Schema parsing and field validation
#   - Document-level validation (kind enum, required fields)
#   - Child CRUD via HTTP routes
#   - Duplicate kind enforcement via Lua script
# ────────────────────────────────────────────────────────────────────────────

# Load the seeded core.DocumentView definition from the seed directory
def view_defn
  Facet::Doctype::DoctypeDefinition.from_yaml(File.read("data/seeds/core.DocumentView/definition.yml"))
end

# Template-gate fixtures. A root object without a `type` discriminator cannot
# render — the validator reports it as an `:error`. Duplicate relation column
# keys collapse to the first occurrence in the renderer — a `:warning`, never
# a refusal. File-scoped private defs — see the top-level-defs rule in
# doc/backend/workflow.md.
private def malformed_template : String
  %({"columns": 2})
end

private def duplicate_columns_template : String
  %({"type": "relation", "label": "Items", "doctype": "other.Thing", "view": "table", "source": {"kind": "children", "rel": "things"}, "columns": [{"key": "name", "label": "Name"}, {"key": "name", "label": "Copy"}]})
end

# Helper: create a minimal core.DocType document and return its ID
def create_test_doctype_id : String
  with_db do |db|
    # Re-ensure the core doctypes (truncated by before_each) so that the
    # core.DocumentView definition and the core.DocType definition (with
    # children.document_view) exist. Idempotent within a single test.
    %w[core.DocType core.Domain core.DocumentView].each do |dir|
      domain, doctype = dir.split(".", 2)
      Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
    end
    Facet::Doctype::DefinitionStore.cache.clear
    doctype_name = "TView#{unique_suffix(8)}"
    defn = Facet::Doctype::DoctypeDefinition.new(
      doctype: doctype_name,
      domain: "core",
      schema_version: 1,
      aggregate_root: true, search: "{{ display_name }}",
    )
    result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    expect_create_success(result).projection.id
  end
end

# Creates a view on the given doctype via HTTP and returns the parsed response data
def create_view_via_http(doctype_id : String, kind : String, template : String? = nil)
  body_parts = [] of String
  body_parts << "\"parent_doctype\": \"#{doctype_id}\""
  body_parts << "\"kind\": \"#{kind}\""
  if t = template
    body_parts << "\"template\": #{t}"
  end
  body = "{#{body_parts.join(",")}}"

  resp = call_api(HTTP::Request.new("POST", "/Api/core/DocType/#{doctype_id}/document_view", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body))
  {resp: resp, data: JSON.parse(resp.body)}
end

describe "core.DocumentView" do
  # ──────────────────────────────────────────────────────────────────────────
  # 1. Schema parsing and validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "schema" do
    it "parses core.DocumentView" do
      defn = view_defn
      defn.doctype.should eq("DocumentView")
      defn.domain.should eq("core")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_false
      defn.member_of.should eq("DocType")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "has expected fields: parent_doctype, kind, template" do
      fields = view_defn.fields
      fields.has_key?("parent_doctype").should be_true
      fields.has_key?("kind").should be_true
      fields.has_key?("template").should be_true
    end

    it "kind is an enum with five valid values" do
      kind = view_defn.fields["kind"]
      kind.type.not_nil!.type_name.should eq("enum")
      kind.values.not_nil!.should contain(Facet::Doctype::EnumValue.new(key: "view"))
      kind.values.not_nil!.should contain(Facet::Doctype::EnumValue.new(key: "form"))
      kind.values.not_nil!.should contain(Facet::Doctype::EnumValue.new(key: "inline"))
      kind.values.not_nil!.should contain(Facet::Doctype::EnumValue.new(key: "card"))
      kind.values.not_nil!.should contain(Facet::Doctype::EnumValue.new(key: "quickView"))
      kind.values.not_nil!.size.should eq(5)
    end

    it "parent_doctype is a required string" do
      field = view_defn.fields["parent_doctype"]
      field.type.not_nil!.type_name.should eq("string")
      field.required.should be_true
    end

    it "template is an optional object" do
      field = view_defn.fields["template"]
      field.type.not_nil!.type_name.should eq("object")
      field.required.should be_false
    end

    it "core.DocType seed includes children.document_view → DocumentView" do
      core_dt_defn = Facet::Doctype::DoctypeDefinition.from_yaml(File.read("data/seeds/core.DocType/definition.yml"))
      core_dt_defn.children.has_key?("document_view").should be_true
      core_dt_defn.children["document_view"].doctype.should eq("DocumentView")
      core_dt_defn.children["document_view"].collection?.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. Document-level validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "document validation" do
    it "accepts a valid DocumentView document" do
      doc = JSON.parse(%({
        "parent_doctype": "hr.Employee",
        "kind": "view"
      }))
      Facet::Document::Validation.validate(doc, view_defn).should be_empty
    end

    it "accepts a valid DocumentView with template" do
      doc = JSON.parse(%({
        "parent_doctype": "hr.Employee",
        "kind": "form",
        "template": { "sections": ["main", "sidebar"] }
      }))
      Facet::Document::Validation.validate(doc, view_defn).should be_empty
    end

    it "accepts all five valid kinds" do
      %w[view form inline card quickView].each do |k|
        doc = JSON.parse(%({"parent_doctype": "test.T", "kind": "#{k}"}))
        Facet::Document::Validation.validate(doc, view_defn).should be_empty
      end
    end

    it "rejects invalid kind" do
      doc = JSON.parse(%({
        "parent_doctype": "hr.Employee",
        "kind": "invalid_kind"
      }))
      errs = Facet::Document::Validation.validate(doc, view_defn)
      errs.any? { |e| e.field == "kind" && e.message.includes?("invalid_kind") }.should be_true
    end

    it "rejects missing parent_doctype" do
      doc = JSON.parse(%({"kind": "view"}))
      errs = Facet::Document::Validation.validate(doc, view_defn)
      errs.any? { |e| e.field == "parent_doctype" && e.code == "required" }.should be_true
    end

    it "rejects missing kind" do
      doc = JSON.parse(%({"parent_doctype": "test.T"}))
      errs = Facet::Document::Validation.validate(doc, view_defn)
      errs.any? { |e| e.field == "kind" && e.code == "required" }.should be_true
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────────
  # 3. HTTP integration — DocumentView as child of core.DocType
  #
  # The seeded core.DocType definition includes children.document_view → DocumentView,
  # so the child routing automatically resolves POST/GET/PATCH/DELETE
  # on /Api/core/DocType/:id/document_view.
  #
  # Response format:
  #   Success: { "data": <content fields>, "meta": { "id": "...", ... } }
  #   Error:   { "error": "message" }
  # ──────────────────────────────────────────────────────────────────────────
  describe "HTTP child CRUD" do
    it "creates a view via child route" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "view", %({"type": "section", "label": "Main", "children": []}))
      assert_http_status(result[:resp], 201)

      data = result[:data]["data"]
      data["kind"].as_s.should eq("view")
      data["template"]["type"].as_s.should eq("section")
      data["parent_doctype"].as_s.should eq(doctype_id)
    end

    it "lists views for a doctype" do
      doctype_id = create_test_doctype_id

      create_view_via_http(doctype_id, "view")
      create_view_via_http(doctype_id, "form")

      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/document_view"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["data"].as_a.size.should eq(2)
    end

    it "reads a specific view" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "card")
      view_meta = result[:data]["meta"]
      view_id = view_meta["id"].as_s

      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/document_view/#{view_id}"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["data"]["kind"].as_s.should eq("card")
      body["data"]["parent_doctype"].as_s.should eq(doctype_id)
    end

    it "updates a view" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "inline")
      view_meta = result[:data]["meta"]
      view_id = view_meta["id"].as_s

      patch_body = %({"kind": "card"})
      response = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/document_view/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      assert_http_status(response, 200)
    end

    it "deletes a view" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "quickView")
      view_meta = result[:data]["meta"]
      view_id = view_meta["id"].as_s

      response = call_api(HTTP::Request.new("DELETE", "/Api/core/DocType/#{doctype_id}/document_view/#{view_id}"))
      assert_http_status(response, 204)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. Definition-plane children of a readable doctype (F04-03)
  #
  # Reading a doctype implies reading its presentation templates: a role
  # holding only `read core.DocType.<name>` lists and reads that doctype's
  # document_view children without a grant on `core.DocType.DocumentView`.
  # ──────────────────────────────────────────────────────────────────────────
  describe "definition-plane children of a readable doctype" do
    it "lists document_view children for a caller holding only a read on the doctype" do
      doctype_id = create_test_doctype_id
      create_view_via_http(doctype_id, "view")

      role = Facet::RBAC::ActiveRole.new(
        role_id: "test_document_view_reader",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [Facet::RBAC::Permission.new(action: "read", domain: "core", path: [doctype_id.split('.', 2)[1]])],
      )
      Fiber.current.auth_context = Facet::RBAC::AuthContext.authenticated("account_clerk", role)

      resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/document_view?items=100"))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"].as_a.size.should eq(1)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. Duplicate kind enforcement (Lua validation)
  # ──────────────────────────────────────────────────────────────────────────
  describe "duplicate kind enforcement" do
    it "creates views with different kinds for the same doctype" do
      doctype_id = create_test_doctype_id
      assert_http_status(create_view_via_http(doctype_id, "view")[:resp], 201)
      assert_http_status(create_view_via_http(doctype_id, "form")[:resp], 201)
    end

    it "rejects creating a view with a duplicate kind for the same doctype" do
      doctype_id = create_test_doctype_id
      assert_http_status(create_view_via_http(doctype_id, "view")[:resp], 201)

      result = create_view_via_http(doctype_id, "view")
      assert_http_status(result[:resp], 422)
      details = result[:data]["details"]
      details.as_a.any? { |d| d["message"].as_s.downcase.includes?("duplicate") }.should be_true
    end

    it "allows the same kind for different doctypes" do
      doctype_id1 = create_test_doctype_id
      doctype_id2 = create_test_doctype_id

      assert_http_status(create_view_via_http(doctype_id1, "view")[:resp], 201)
      assert_http_status(create_view_via_http(doctype_id2, "view")[:resp], 201)
    end

    it "rejects updating a view to a kind that conflicts with another view" do
      doctype_id = create_test_doctype_id

      result1 = create_view_via_http(doctype_id, "view")
      assert_http_status(result1[:resp], 201)
      view1_id = result1[:data]["meta"]["id"].as_s

      assert_http_status(create_view_via_http(doctype_id, "form")[:resp], 201)

      # Update view1 to "form" which conflicts with view2
      patch_body = %({"kind": "form"})
      patch_resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/document_view/#{view1_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      assert_http_status(patch_resp, 422)
      err_body = JSON.parse(patch_resp.body)
      details = err_body["details"]
      details.as_a.any? { |d| d["message"].as_s.downcase.includes?("duplicate") }.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # 5. Template gate — every write door refuses `:error` template issues
  #
  # The `template` field is a free-form object at the document layer, so
  # the write doors run `Document::ViewTemplateGate` (the
  # `Doctype::ViewTemplateValidator` pass against the parent doctype
  # definition). `:error` issues answer 422 with the issue list; `:warning`
  # issues (duplicate relation column keys included) stay non-blocking.
  # ────────────────────────────────────────────────────────────────────
  describe "template gate" do
    it "refuses a malformed template on the nested create with a 422 naming the problem" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "view", malformed_template)
      assert_http_status(result[:resp], 422)

      details = result[:data]["details"].as_a
      details.any? { |d| d["code"].as_s == "template" && d["message"].as_s.includes?("type") }.should be_true
    end

    it "refuses an input bound to an unknown field on the nested create" do
      doctype_id = create_test_doctype_id
      template = %({"type": "input", "field": "ghost_field"})
      result = create_view_via_http(doctype_id, "form", template)
      assert_http_status(result[:resp], 422)

      details = result[:data]["details"].as_a
      details.any? { |d| d["code"].as_s == "template" && d["message"].as_s.includes?("ghost_field") }.should be_true
    end

    it "keeps duplicate relation column keys warning-only on the nested create" do
      doctype_id = create_test_doctype_id
      result = create_view_via_http(doctype_id, "view", duplicate_columns_template)
      assert_http_status(result[:resp], 201)
      result[:data]["data"]["template"]["columns"].as_a.size.should eq(2)
    end

    it "refuses the filed repro: bare-string and keyless relation columns, duplicates stay out of the refusal" do
      doctype_id = create_test_doctype_id
      template = %({"type": "relation", "label": "R", "doctype": "other.Thing", "source": {"kind": "children", "rel": "things"}, "columns": ["bare-str-col", {"label": "nokey"}, {"key": "f_string", "label": "A"}, {"key": "f_string", "label": "B"}]})
      result = create_view_via_http(doctype_id, "view", template)
      assert_http_status(result[:resp], 422)

      details = result[:data]["details"].as_a
      # The two `:error` shapes are named; the duplicate key is a `:warning`
      # and never appears in the refusal.
      details.any? { |d| d["message"].as_s.includes?("must be an object with 'key'") }.should be_true
      details.any? { |d| d["message"].as_s.includes?("missing a non-empty 'key'") }.should be_true
      details.any? { |d| d["message"].as_s.downcase.includes?("duplicate") }.should be_false
    end

    it "refuses a malformed template on the flat PATCH" do
      doctype_id = create_test_doctype_id
      created = create_view_via_http(doctype_id, "view")
      assert_http_status(created[:resp], 201)
      view_id = created[:data]["meta"]["id"].as_s

      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocumentView/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: %({"template": #{malformed_template}})))
      assert_http_status(resp, 422)
      details = JSON.parse(resp.body)["details"].as_a
      details.any? { |d| d["code"].as_s == "template" }.should be_true
    end

    it "refuses a malformed template on the nested PATCH" do
      doctype_id = create_test_doctype_id
      created = create_view_via_http(doctype_id, "view")
      assert_http_status(created[:resp], 201)
      view_id = created[:data]["meta"]["id"].as_s

      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/document_view/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: %({"template": #{malformed_template}})))
      assert_http_status(resp, 422)
      details = JSON.parse(resp.body)["details"].as_a
      details.any? { |d| d["code"].as_s == "template" }.should be_true
    end

    it "stores a valid template on the flat PATCH and accepts a patch that does not touch the template" do
      doctype_id = create_test_doctype_id
      created = create_view_via_http(doctype_id, "view", %({"type": "section", "label": "Main", "children": []}))
      assert_http_status(created[:resp], 201)
      view_id = created[:data]["meta"]["id"].as_s

      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocumentView/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: %({"kind": "form"})))
      assert_http_status(resp, 200)
      data = JSON.parse(resp.body)["data"]
      data["kind"].as_s.should eq("form")
      data["template"]["type"].as_s.should eq("section")
    end

    it "replaces the stored template on write instead of merging it (F10-02)" do
      doctype_id = create_test_doctype_id
      stored = %({"type": "section", "label": "Old", "children": [{"type": "label", "value": "Stale"}]})
      created = create_view_via_http(doctype_id, "quickView", stored)
      assert_http_status(created[:resp], 201)
      view_id = created[:data]["meta"]["id"].as_s

      patch = %({"template": {"type": "label", "value": "ONLY-LABEL"}})
      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocumentView/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch))
      assert_http_status(resp, 200)

      template = JSON.parse(resp.body)["data"]["template"]
      template.as_h.keys.sort!.should eq(["type", "value"])
      template["type"].as_s.should eq("label")
      template["value"].as_s.should eq("ONLY-LABEL")
    end
  end
end
