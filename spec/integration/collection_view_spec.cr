# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "json"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# ─────────────────────────────────────────────────────────────────────────────────
# CollectionView integration — schema, document validation, child CRUD,
# RBAC scope enforcement (general vs personal), and Lua ownership rules.
#
# These tests exercise the full lifecycle of core.CollectionView, a child
# doctype of core.DocType. They cover:
#   - Schema parsing and field validation
#   - Document-level validation
#   - Child CRUD via HTTP routes (`/Api/core/DocType/:id/collection_view`)
#   - RBAC scope enforcement: general (owner_id is null) vs personal
#     (owner_id = creator) via the `mine` and `general` named scopes
#   - Lua create-hook owner_id forcing based on the create permission's
#     scope alias, and owner_id immutability on update
# ─────────────────────────────────────────────────────────────────────────────────

# Load the seeded core.CollectionView definition from the seed directory
def cv_defn
  Facet::Doctype::DoctypeDefinition.from_yaml(File.read("data/seeds/core.CollectionView/definition.yml"))
end

# Helper: create a minimal core.DocType document and return its ID
def cv_create_test_doctype_id : String
  with_db do |db|
    # Re-ensure the core doctypes (truncated by before_each) so that the
    # core.CollectionView definition and the core.DocType definition (with
    # children.collection_view) exist. Idempotent within a single test.
    %w[core.DocType core.Domain core.CollectionView].each do |dir|
      domain, doctype = dir.split(".", 2)
      Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
    end
    Facet::Doctype::DefinitionStore.cache.clear
    doctype_name = "TCView#{unique_suffix(8)}"
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

# Creates a CollectionView on the given doctype via HTTP and returns the parsed response data
def create_collection_view_via_http(doctype_id : String, name : String, surface : String = "table", config : String? = nil)
  body_parts = [] of String
  body_parts << "\"name\": \"#{name}\""
  body_parts << "\"surface\": \"#{surface}\""
  if c = config
    body_parts << "\"config\": #{c}"
  end
  body = "{#{body_parts.join(",")}}"

  resp = call_api(HTTP::Request.new("POST", "/Api/core/DocType/#{doctype_id}/collection_view", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body))
  {resp: resp, data: JSON.parse(resp.body)}
end

# ── RBAC helper constructors for the CollectionView specs ───────────────

# Ensures the account row exists — the owner_id reference values used in
# the immutability tests must pass the authoring-time existence check
# before the CollectionView Lua hook runs.
def cv_ensure_account(account_id : String) : Nil
  with_db do |db|
    ensure_iam_account(db, account_id)
  end
end

def cv_auth_with(perms : Array(Facet::RBAC::Permission), account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "test_collection_view_role",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: perms,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# ── RBAC helper constructors for the CollectionView specs ──────────────
#
# CollectionView is a `member_of` child of core.DocType: every route that
# touches it is a nested child route, and nested routes authorize on the
# COMPOSITION path (`["DocType", "CollectionView"]`) — a bare child path
# serves the flat route only, which children refuse. The permissions below
# therefore carry the nested path, exactly as a production role would.

PATH = ["DocType", "CollectionView"]

def cv_create_perm(scope : String | Array(String)? = nil) : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(
    action: "create", domain: "core", path: PATH, scope: scope
  )
end

def cv_read_perm(scope : String | Array(String)? = nil) : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(
    action: "read", domain: "core", path: PATH, scope: scope
  )
end

def cv_update_perm(scope : String | Array(String)? = nil) : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(
    action: "update", domain: "core", path: PATH, scope: scope
  )
end

def cv_delete_perm(scope : String | Array(String)? = nil) : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(
    action: "delete", domain: "core", path: PATH, scope: scope
  )
end

# Read permission on the parent DocType so the parent gate in nested
# routing (ReadEnforcer.parent_authorized?) passes. The nested CollectionView
# path is subtracted via `except` — the documented "blanket line steps aside
# for a scoped re-grant" shape — so an unrestricted parent read cannot swallow
# a scoped nested read through the intra-role OR union.
def cv_doctype_read_perm : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(
    action: "read", domain: "core", path: ["DocType"],
    except: ["core.DocType.CollectionView"],
  )
end

# Read permission on `iam.Account`: `owner_id` is a reference field, so the
# B-356 reference check resolves the owner row under the caller's read
# scope. Specs that exercise the CollectionView owner rules therefore need
# this grant — without it the owner value is refused as unreadable before
# the Lua hook ever runs.
def cv_account_read_perm : Facet::RBAC::Permission
  Facet::RBAC::Permission.new(action: "read", domain: "iam", path: ["Account"])
end

describe "core.CollectionView" do
  # ──────────────────────────────────────────────────────────────────────────
  # 1. Schema parsing and validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "schema" do
    it "parses core.CollectionView" do
      defn = cv_defn
      defn.doctype.should eq("CollectionView")
      defn.domain.should eq("core")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_false
      defn.member_of.should eq("DocType")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "has expected fields: name, surface, config, owner_id" do
      fields = cv_defn.fields
      fields.has_key?("name").should be_true
      fields.has_key?("surface").should be_true
      fields.has_key?("config").should be_true
      fields.has_key?("owner_id").should be_true
    end

    it "surface is an enum with table, calendar, and kanban" do
      field = cv_defn.fields["surface"]
      field.type.not_nil!.type_name.should eq("enum")
      field.values.not_nil!.map(&.key).should contain("table")
      field.values.not_nil!.map(&.key).should contain("calendar")
      field.values.not_nil!.map(&.key).should contain("kanban")
      field.values.not_nil!.size.should eq(3)
    end

    it "name is a required string" do
      field = cv_defn.fields["name"]
      field.type.not_nil!.type_name.should eq("string")
      field.required.should be_true
    end

    it "owner_id is a reference to iam.Account" do
      field = cv_defn.fields["owner_id"]
      field.type.not_nil!.type_name.should eq("reference")
      field.doctype.should eq("iam.Account")
    end

    it "declares the mine and general named scopes" do
      scopes = cv_defn.scopes
      scopes.has_key?("mine").should be_true
      scopes["mine"].where["owner_id"].should eq("$self")
      scopes.has_key?("general").should be_true
      scopes["general"].where["owner_id"].should eq("$null")
    end

    it "core.DocType seed includes children.collection_view → CollectionView" do
      core_dt_defn = Facet::Doctype::DoctypeDefinition.from_yaml(File.read("data/seeds/core.DocType/definition.yml"))
      core_dt_defn.children.has_key?("collection_view").should be_true
      core_dt_defn.children["collection_view"].doctype.should eq("CollectionView")
      core_dt_defn.children["collection_view"].collection?.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. Document-level validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "document validation" do
    it "accepts a minimal personal CollectionView" do
      doc = JSON.parse(%({
        "name": "My Pipeline",
        "surface": "table"
      }))
      Facet::Document::Validation.validate(doc, cv_defn).should be_empty
    end

    it "accepts a general CollectionView with table config" do
      doc = JSON.parse(%({
        "name": "All",
        "surface": "table",
        "config": { "columns": [{ "key": "name" }, { "key": "status" }] }
      }))
      Facet::Document::Validation.validate(doc, cv_defn).should be_empty
    end

    it "accepts a calendar CollectionView with calendar config" do
      doc = JSON.parse(%({
        "name": "Timeline",
        "surface": "calendar",
        "config": { "calendar": { "discriminator": "expected_close_date", "week_start": "monday" } }
      }))
      Facet::Document::Validation.validate(doc, cv_defn).should be_empty
    end

    it "accepts a kanban CollectionView with kanban config" do
      doc = JSON.parse(%({
        "name": "Pipeline",
        "surface": "kanban",
        "config": { "kanban": { "mode": "values", "group_by": "status", "page_size": 25 } }
      }))
      Facet::Document::Validation.validate(doc, cv_defn).should be_empty
    end

    it "rejects missing name" do
      doc = JSON.parse(%({"surface": "table"}))
      errs = Facet::Document::Validation.validate(doc, cv_defn)
      errs.any? { |e| e.field == "name" && e.code == "required" }.should be_true
    end

    it "rejects missing surface" do
      doc = JSON.parse(%({"name": "All"}))
      errs = Facet::Document::Validation.validate(doc, cv_defn)
      errs.any? { |e| e.field == "surface" && e.code == "required" }.should be_true
    end

    it "rejects an unknown surface" do
      doc = JSON.parse(%({"name": "All", "surface": "grid"}))
      errs = Facet::Document::Validation.validate(doc, cv_defn)
      errs.any? { |e| e.field == "surface" && e.message.includes?("grid") }.should be_true
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────────
  # 3. HTTP integration — CollectionView as child of core.DocType
  #
  # The seeded core.DocType definition includes children.collection_view → CollectionView,
  # so the child routing automatically resolves POST/GET/PATCH/DELETE
  # on /Api/core/DocType/:id/collection_view.
  # ─────────────────────────────────────────────────────────────────────────────────
  describe "HTTP child CRUD" do
    before_each do
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
    end

    it "creates a view via child route (system bypass → general view)" do
      doctype_id = cv_create_test_doctype_id
      result = create_collection_view_via_http(doctype_id, "All", "table", %({"columns": [{"key": "name"}]}))
      assert_http_status(result[:resp], 201)

      data = result[:data]["data"]
      data["name"].as_s.should eq("All")
      data["surface"].as_s.should eq("table")
      data["config"]["columns"].as_a.size.should eq(1)
    end

    it "lists views for a doctype" do
      doctype_id = cv_create_test_doctype_id

      # `cv_create_test_doctype_id` now seeds one general "All Records"
      # view automatically (see `Doctype::Create.seed_default_collection_view`).
      # Tests in this block create additional views on top — assertions
      # filter out the seeded view by name so they stay focused on the HTTP
      # behaviour they exercise.
      create_collection_view_via_http(doctype_id, "All")
      create_collection_view_via_http(doctype_id, "Personal")

      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      created = body["data"].as_a.reject { |v| v["data"]["name"].as_s == "All Records" }
      created.size.should eq(2)
    end

    it "reads a specific view" do
      doctype_id = cv_create_test_doctype_id
      result = create_collection_view_via_http(doctype_id, "All", "table", %({"columns": [{"key": "name"}]}))
      view_id = result[:data]["meta"]["id"].as_s

      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["data"]["name"].as_s.should eq("All")
    end

    it "creates and reads back a kanban view" do
      doctype_id = cv_create_test_doctype_id
      result = create_collection_view_via_http(doctype_id, "Pipeline", "kanban", %({"kanban": {"mode": "values", "group_by": "status", "page_size": 25, "filters": {}, "sort": ["-updated_at"]}}))
      assert_http_status(result[:resp], 201)

      data = result[:data]["data"]
      data["surface"].as_s.should eq("kanban")
      data["config"]["kanban"]["mode"].as_s.should eq("values")
      data["config"]["kanban"]["group_by"].as_s.should eq("status")

      view_id = result[:data]["meta"]["id"].as_s
      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["data"]["surface"].as_s.should eq("kanban")
      body["data"]["config"]["kanban"]["mode"].as_s.should eq("values")
      body["data"]["config"]["kanban"]["group_by"].as_s.should eq("status")
    end

    it "updates a view's config" do
      doctype_id = cv_create_test_doctype_id
      result = create_collection_view_via_http(doctype_id, "All")
      view_id = result[:data]["meta"]["id"].as_s

      patch_body = %({"config": {"columns": [{"key": "name"}, {"key": "status"}]}})
      response = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      assert_http_status(response, 200)
    end

    it "rejects updating owner_id (immutable general vs personal)" do
      doctype_id = cv_create_test_doctype_id
      cv_ensure_account("account_a")
      # Create the view as an unrestricted-permission caller (general view, owner_id nil).
      Fiber.current.auth_context = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm(nil), cv_read_perm, cv_update_perm(nil), cv_account_read_perm],
        "account_admin",
      )
      result = create_collection_view_via_http(doctype_id, "All")
      view_id = result[:data]["meta"]["id"].as_s

      # Try to change owner_id to a different account — must be rejected.
      patch_body = %({"owner_id": "account_a"})
      response = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      assert_http_status(response, 422)
      details = JSON.parse(response.body)["details"]?.try(&.as_a) || [] of JSON::Any
      details.any? { |d| d["message"].as_s.downcase.includes?("owner_id") }.should be_true
    end

    it "deletes a view" do
      doctype_id = cv_create_test_doctype_id
      result = create_collection_view_via_http(doctype_id, "All")
      view_id = result[:data]["meta"]["id"].as_s

      response = call_api(HTTP::Request.new("DELETE", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}"))
      assert_http_status(response, 204)
    end

    it "returns a helpful 400 when POST targets a specific child id (the doubled-segment bug)" do
      doctype_id = cv_create_test_doctype_id
      # A POST to `<parent>/collection_view/<id>` (even segment count) targets
      # a specific existing child document, not a collection — POST has no
      # meaning there. The error message must point the caller at the correct
      # child-collection URL rather than the opaque `cannot POST to doc`.
      body = %({"name": "All", "surface": "table"})
      response = call_api(HTTP::Request.new(
        "POST",
        "/Api/core/DocType/#{doctype_id}/collection_view/collection_view",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: body
      ))
      assert_http_status(response, 400)
      json = JSON.parse(response.body)
      message = json["error"].as_s
      # The error must mention POST in some form and reference the
      # collection URL pattern, so a confused client author can self-correct.
      message.should contain("POST")
      message.should contain("collection_view")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. RBAC + Lua ownership enforcement
  #
  # The Lua create hook reads ctx.actor.scope (the matched create-permission's
  # scope alias) to decide general vs personal:
  #   scope == "mine" → personal view, owner_id forced to ctx.actor.id
  #   scope == nil    → unrestricted create, owner_id left as sent (general or personal)
  #
  # These tests construct roles with scoped create permissions and inject them
  # via Fiber.current.auth_context so the HTTP layer enforces them.
  # ──────────────────────────────────────────────────────────────────────────
  describe "RBAC and ownership" do
    # Deterministic start state: every example in this block pins its own
    # principal below, but the reset keeps the block independent of whatever
    # fiber-local identity a previous example (or file) left behind.
    before_each do
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
    end

    it "forces owner_id to the actor when create permission is scoped $mine" do
      doctype_id = cv_create_test_doctype_id
      Fiber.current.auth_context = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm],
        "account_alice",
      )

      result = create_collection_view_via_http(doctype_id, "Personal Table")
      assert_http_status(result[:resp], 201)
      data = result[:data]["data"]
      data["owner_id"].as_s.should eq("iam.Account.account_alice")
    end

    it "rejects a $mine caller trying to set owner_id to another account" do
      doctype_id = cv_create_test_doctype_id
      cv_ensure_account("account_bob")
      Fiber.current.auth_context = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm, cv_account_read_perm],
        "account_alice",
      )

      body = %({"name": "Hijack", "surface": "table", "owner_id": "account_bob"})
      resp = call_api(HTTP::Request.new("POST", "/Api/core/DocType/#{doctype_id}/collection_view", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body))
      assert_http_status(resp, 422)
      details = JSON.parse(resp.body)["details"]?.try(&.as_a) || [] of JSON::Any
      details.any? { |d| d["message"].as_s.downcase.includes?("owner") }.should be_true
    end

    it "leaves owner_id null when create permission is unrestricted (general view)" do
      doctype_id = cv_create_test_doctype_id
      Fiber.current.auth_context = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm(nil), cv_read_perm],
        "account_alice",
      )

      result = create_collection_view_via_http(doctype_id, "Shared All")
      assert_http_status(result[:resp], 201)
      data = result[:data]["data"]
      data["owner_id"]?.try(&.as_s?).should be_nil
    end

    it "lists general views AND own personal views via combined $general + $mine read scope" do
      doctype_id = cv_create_test_doctype_id
      # System creates one general view.
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
      create_collection_view_via_http(doctype_id, "Shared All")

      # Alice (scoped $mine create) creates one personal view.
      Fiber.current.auth_context = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm(["$mine", "$general"])],
        "account_alice",
      )
      create_collection_view_via_http(doctype_id, "Personal")

      # List returns general + alice's personal (but not bob's — bob's not created here).
      # The auto-seeded "All Records" general view is filtered out so this
      # test stays focused on the user-created views.
      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view"))
      assert_http_status(response, 200)
      items = JSON.parse(response.body)["data"].as_a
      names = items.reject { |v| v["data"]["name"].as_s == "All Records" }
        .map(&.["data"]["name"].as_s).sort!
      names.should eq(["Personal", "Shared All"])
    end

    it "hides other users' personal views via the combined read scope" do
      doctype_id = cv_create_test_doctype_id
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
      create_collection_view_via_http(doctype_id, "Shared All")

      alice = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm(["$mine", "$general"])],
        "account_alice",
      )
      bob = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm(["$mine", "$general"])],
        "account_bob",
      )

      Fiber.current.auth_context = alice
      create_collection_view_via_http(doctype_id, "Alice Personal")

      Fiber.current.auth_context = bob
      create_collection_view_via_http(doctype_id, "Bob Personal")

      # Alice sees general + her own personal, NOT Bob's.
      # The auto-seeded "All Records" general view is filtered out so this
      # test stays focused on the user-created views.
      Fiber.current.auth_context = alice
      response = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view"))
      assert_http_status(response, 200)
      names = JSON.parse(response.body)["data"].as_a
        .reject { |v| v["data"]["name"].as_s == "All Records" }
        .map(&.["data"]["name"].as_s).sort!
      names.should eq(["Alice Personal", "Shared All"])
    end

    it "lets a $mine-scoped user update and delete only their own personal view" do
      doctype_id = cv_create_test_doctype_id
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
      create_collection_view_via_http(doctype_id, "Shared All")

      alice = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm(["$mine", "$general"]),
         cv_update_perm("$mine"), cv_delete_perm("$mine")],
        "account_alice",
      )
      bob = cv_auth_with(
        [cv_doctype_read_perm, cv_create_perm("$mine"), cv_read_perm(["$mine", "$general"]),
         cv_update_perm("$mine"), cv_delete_perm("$mine")],
        "account_bob",
      )

      Fiber.current.auth_context = alice
      alice_view = create_collection_view_via_http(doctype_id, "Alice Personal")
      alice_view_id = alice_view[:data]["meta"]["id"].as_s

      Fiber.current.auth_context = alice
      patch_body = %({"config": {"columns": [{"key": "name"}]}})
      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/collection_view/#{alice_view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      assert_http_status(resp, 200)

      # Bob cannot update Alice's view (403 → 404 non-disclosing).
      Fiber.current.auth_context = bob
      resp = call_api(HTTP::Request.new("PATCH", "/Api/core/DocType/#{doctype_id}/collection_view/#{alice_view_id}", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: patch_body))
      [403, 404].should contain(resp.status_code)

      # Bob cannot delete Alice's view.
      resp = call_api(HTTP::Request.new("DELETE", "/Api/core/DocType/#{doctype_id}/collection_view/#{alice_view_id}"))
      [403, 404].should contain(resp.status_code)

      # Alice can delete her own.
      Fiber.current.auth_context = alice
      resp = call_api(HTTP::Request.new("DELETE", "/Api/core/DocType/#{doctype_id}/collection_view/#{alice_view_id}"))
      assert_http_status(resp, 204)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 5. Definition-plane children of a readable doctype
  #
  # Reading a doctype implies reading its configuration: a role holding only
  # `read core.DocType.<name>` must list and read that doctype's
  # CollectionView / DocumentView children without a grant on
  # `core.DocType.CollectionView` itself (F04-03). Writes keep requiring
  # their own grant.
  # ──────────────────────────────────────────────────────────────────────────
  describe "definition-plane children of a readable doctype" do
    before_each do
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
    end

    it "lists collection_view children for a caller holding only a read on the doctype" do
      doctype_id = cv_create_test_doctype_id
      create_collection_view_via_http(doctype_id, "All")

      Fiber.current.auth_context = cv_auth_with(
        [Facet::RBAC::Permission.new(action: "read", domain: "core", path: [doctype_id.split('.', 2)[1]])],
        "account_clerk",
      )

      resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view?items=500"))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"].as_a.map(&.["data"]["name"].as_s).should contain("All")
    end

    it "reads one collection_view child for a caller holding only a read on the doctype" do
      doctype_id = cv_create_test_doctype_id
      view_id = create_collection_view_via_http(doctype_id, "All")[:data]["meta"]["id"].as_s

      Fiber.current.auth_context = cv_auth_with(
        [Facet::RBAC::Permission.new(action: "read", domain: "core", path: [doctype_id.split('.', 2)[1]])],
        "account_clerk",
      )

      resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view/#{view_id}"))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["name"].as_s.should eq("All")
    end

    it "still refuses create on collection_view without a create grant" do
      doctype_id = cv_create_test_doctype_id

      Fiber.current.auth_context = cv_auth_with(
        [Facet::RBAC::Permission.new(action: "read", domain: "core", path: [doctype_id.split('.', 2)[1]])],
        "account_clerk",
      )

      body = %({"name": "Sneaky", "surface": "table"})
      resp = call_api(HTTP::Request.new("POST", "/Api/core/DocType/#{doctype_id}/collection_view", headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body))
      assert_http_status(resp, 403)
    end

    it "keeps the non-disclosing answer for a caller with no grant on the doctype" do
      doctype_id = cv_create_test_doctype_id

      Fiber.current.auth_context = cv_auth_with(
        [Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["OtherDoctype"])],
        "account_stranger",
      )

      # The parent row gate runs first and answers the non-disclosing 404 —
      # an unreachable parent is indistinguishable from a missing one.
      resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/#{doctype_id}/collection_view"))
      assert_http_status(resp, 404)
    end
  end
end
