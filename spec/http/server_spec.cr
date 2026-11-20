# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "yaml"
require "../../src/http/server"
require "../../src/doctype/yaml_helper"
require "../../src/iam"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/iam_helper"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Seed the required doctypes via direct DB calls (non-HTTP to avoid chain issues)
def seed_test_doctypes : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    ensure_domain(db, "hr")

    defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(defn)

    employee_defn = build_doctype_definition("hr.Employee/definition.yml", "hr.Employee/script.lua")
    create_doctype(employee_defn)

    defn = load_doctype_schema("hr.CareerEvent/definition.yml")
    create_doctype(defn)

    seed_sidecar_doctype(db)
  end
end

# Registers the sidecar `core.Comment` doctype from the production seed
# directory, so flat-route specs exercise the real definition.
# `Doctype::Create` requires the definition's domain to exist as a
# `core.Domain` document, and the per-test TRUNCATE wipes it.
def seed_sidecar_doctype(db : DB::Connection) : Nil
  ensure_domain(db, "core")
  content = File.read(File.join(__DIR__, "..", "..", "data", "seeds", "core.Comment", "definition.yml"))
  yaml = YAML.parse(content)
  json = Facet::Doctype::YamlHelper.to_json_any(yaml).to_json
  defn = Facet::Doctype::DoctypeDefinition.from_json(json)
  Facet::Doctype::DefinitionStore.cache.clear
  result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  raise "sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
end

# Creates a sidecar Comment row directly (the flat POST route is blocked
# for sidecar doctypes).
def seed_sidecar_comment(domain : String, target : String, body : String) : String
  doc_id = Facet::Util::ScriptHelpers.ulid
  with_db do |db|
    Facet::Mutation::Client.create(
      db,
      domain,
      "Comment",
      doc_id: doc_id,
      content: %({"target": #{target.to_json}, "body": #{body.to_json}}),
      actioner_id: "system",
    )
  end
  doc_id
end

# ── Tests ──────────────────────────────────────────────────────────────────

describe "HTTP Server endpoints" do
  before_each do
    seed_test_doctypes
  end

  # ── LIST ──────────────────────────────────────────────────────────────

  describe "GET /Api/:domain/:doctype (list)" do
    it "returns an empty list for a doctype with no documents" do
      resp = list_documents_http("identity", "Person")
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"].as_a.size.should eq(0)
      body["meta"]["count"].as_i.should eq(0)
    end

    it "lists documents after creation" do
      create_document_http("identity", "Person", %({"full_name": "ListA", "email": "lista@test.com", "date_of_birth": "1990-01-01"}))
      create_document_http("identity", "Person", %({"full_name": "ListB", "email": "listb@test.com", "date_of_birth": "1990-01-01"}))

      resp = list_documents_http("identity", "Person")
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"].as_a.size.should be >= 2
      body["meta"]["count"].as_i.should be >= 2
    end
  end

  # ── PATCH ─────────────────────────────────────────────────────────────

  describe "PATCH /Api/:domain/:doctype/:id (update)" do
    it "partially updates a document" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "PatchTest", "email": "patch@test.com", "date_of_birth": "1990-01-01"}))

      resp = patch_document_http("identity", "Person", doc_id, %({"full_name": "Patched"}))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["full_name"].as_s.should eq("Patched")
    end

    it "returns 404 for non-existent document" do
      resp = patch_document_http("identity", "Person", "nonexistent", %({"full_name": "Nope"}))
      assert_http_status(resp, 404)
    end

    it "returns 422 for invalid body" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "ValidPatch", "email": "validpatch@test.com", "date_of_birth": "1990-01-01"}))

      resp = patch_document_http("identity", "Person", doc_id, "not json")
      assert_http_status(resp, 422)
    end

    it "returns 200 with same mid when patching with identical values (no-op)" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "SameName", "email": "same@test.com", "date_of_birth": "1990-01-01"}))

      # Capture the mid from the create response
      get_resp = get_document_http("identity", "Person", doc_id)
      assert_http_status(get_resp, 200)
      original_mid = JSON.parse(get_resp.body)["meta"]["mid"].as_s

      # PATCH with the exact same full_name
      resp = patch_document_http("identity", "Person", doc_id, %({"full_name": "SameName"}))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)

      # The mid should be unchanged — no new mutation was created
      body["meta"]["mid"].as_s.should eq(original_mid)
      body["data"]["full_name"].as_s.should eq("SameName")
    end

    it "returns 200 with same mid when patching with empty object {}" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "EmptyBody", "email": "empty@test.com", "date_of_birth": "1990-01-01"}))

      get_resp = get_document_http("identity", "Person", doc_id)
      assert_http_status(get_resp, 200)
      original_mid = JSON.parse(get_resp.body)["meta"]["mid"].as_s

      # PATCH with empty object
      resp = patch_document_http("identity", "Person", doc_id, %({}))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)

      body["meta"]["mid"].as_s.should eq(original_mid)
      body["data"]["full_name"].as_s.should eq("EmptyBody")
    end
  end

  # ── DELETE ────────────────────────────────────────────────────────────

  describe "DELETE /Api/:domain/:doctype/:id (delete)" do
    it "soft-deletes a document" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "DeleteTest", "email": "delete@test.com", "date_of_birth": "1990-01-01"}))

      resp = delete_document_http("identity", "Person", doc_id)
      assert_http_status(resp, 204)
    end

    it "returns 404 for non-existent document" do
      resp = delete_document_http("identity", "Person", "nonexistent")
      assert_http_status(resp, 404)
    end
  end

  # ── Nested children ──────────────────────────────────────────────────

  describe "nested child routes" do
    # The Employee documents below reference this person row; the value
    # must pass the authoring-time reference existence check.
    before_each do
      with_db do |db|
        result = Facet::Document::Create.call(
          db, "identity", "Person",
          %({"full_name": "Ref Target", "email": "ref-target@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}),
          Facet::RBAC::AuthContext.system,
          doc_id: "some-person-id",
        )
        expect_create_success(result)
      end
    end

    it "returns 200 for listing children via rest path" do
      emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "E", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": "some-person-id"}))

      resp = list_nested_http("hr", "Employee", emp_id, "career_events")
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"].as_a.size.should eq(0)
    end

    it "returns 404 for unknown child relationship" do
      emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "E", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": "some-person-id"}))

      resp = list_nested_http("hr", "Employee", emp_id, "unknown_children")
      assert_http_status(resp, 404)
    end
  end

  # ── Qualified reference-token ids ────────────────────────────────────

  # Reference values are stored fully qualified ("identity.Person.<id>")
  # and clients send such tokens back as the `:id` path segment. The stored
  # row id is the bare opaque id for documents created through the write
  # path, and the qualified form itself for seed bundles — the routes must
  # resolve both shapes to the same row.
  describe "document routes with a fully qualified reference-token id" do
    it "reads a document addressed by its reference token" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Token Read", "email": "token-read@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}))

      resp = get_document_http("identity", "Person", "identity.Person.#{doc_id}")
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["full_name"].as_s.should eq("Token Read")
      body["meta"]["id"].as_s.should eq(doc_id)
    end

    it "reads a qualified-shaped row id exactly (seed bundle shape)" do
      with_db do |db|
        result = Facet::Document::Create.call(
          db, "identity", "Person",
          %({"full_name": "Seed Shape", "email": "seed-shape@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}),
          Facet::RBAC::AuthContext.system,
          doc_id: "identity.Person.1",
        )
        expect_create_success(result)
      end

      resp = get_document_http("identity", "Person", "identity.Person.1")
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["meta"]["id"].as_s.should eq("identity.Person.1")
    end

    it "patches a document addressed by its reference token" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Token Patch", "email": "token-patch@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}))

      resp = patch_document_http("identity", "Person", "identity.Person.#{doc_id}", %({"full_name": "Token Patched"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["full_name"].as_s.should eq("Token Patched")
    end

    it "deletes a document addressed by its reference token" do
      doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Token Delete", "email": "token-delete@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}))

      resp = delete_document_http("identity", "Person", "identity.Person.#{doc_id}")
      assert_http_status(resp, 204)

      # The tombstone still resolves through the token — the read surfaces
      # its 410 lifecycle error, not a token-shape 404.
      token_resp = get_document_http("identity", "Person", "identity.Person.#{doc_id}")
      assert_http_status(token_resp, 410)
      token_resp.headers["X-Document-Deleted"]?.should eq("true")
    end

    it "returns 404 for a reference token with no matching row" do
      missing = Facet::Util::ScriptHelpers.ulid
      resp = get_document_http("identity", "Person", "identity.Person.#{missing}")
      assert_http_status(resp, 404)
    end
  end

  describe "nested routes with a fully qualified reference-token root id" do
    before_each do
      with_db do |db|
        result = Facet::Document::Create.call(
          db, "identity", "Person",
          %({"full_name": "Token Ref Target", "email": "token-ref-target@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}),
          Facet::RBAC::AuthContext.system,
          doc_id: "tok-ref-person",
        )
        expect_create_success(result)
      end
    end

    it "lists children for a root addressed by its reference token" do
      emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "E", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": "tok-ref-person"}))

      resp = list_nested_http("hr", "Employee", "hr.Employee.#{emp_id}", "career_events")
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"].as_a.size.should eq(0)
    end

    it "runs an action for a root addressed by its reference token" do
      emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "Junior Engineer", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": "tok-ref-person"}))

      resp = execute_action_http("hr", "Employee", "hr.Employee.#{emp_id}", "promote", %({"new_title": "Senior Engineer"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["job_title"].as_s.should eq("Senior Engineer")
    end
  end

  # ── Sidecar doctypes (flat routes) ──────────────────────────────────

  describe "sidecar doctypes on flat routes" do
    it "blocks POST on the flat route with 422" do
      resp = create_document_http("core", "Comment", %({"target": "iam.Account.01SOMEID", "body": "hello"}))
      assert_http_status(resp, 422)
      body = JSON.parse(resp.body)
      body["error"].as_s.should contain("Sidecar doctypes cannot be created through the flat route")
    end

    it "reads a sidecar record through the flat GET route" do
      comment_id = seed_sidecar_comment("core", "iam.Account.01OWNERID", "read me")

      resp = get_document_http("core", "Comment", comment_id)
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["body"].as_s.should eq("read me")
    end

    it "updates a sidecar record through the flat PATCH route" do
      comment_id = seed_sidecar_comment("core", "iam.Account.01OWNERID", "before")

      resp = patch_document_http("core", "Comment", comment_id, %({"body": "after"}))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["body"].as_s.should eq("after")
    end

    it "soft-deletes a sidecar record through the flat DELETE route" do
      comment_id = seed_sidecar_comment("core", "iam.Account.01OWNERID", "gone soon")

      resp = delete_document_http("core", "Comment", comment_id)
      assert_http_status(resp, 204)
    end
  end
end

# ── Sidecar author-scoped RBAC (editor role) ────────────────────────

# Builds an authenticated context for an account holding the seeded
# `iam.Roles.comment_author` role (author-scoped read/update/delete on
# core.Comment, no wildcard permissions).
def editor_ctx(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.comment_author").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Seeds a comment authored by the given account id (bare form, as the
# Lua hook writes it before Normalize qualifies it).
def seed_authored_comment(author : String, body : String) : String
  doc_id = Facet::Util::ScriptHelpers.ulid
  with_db do |db|
    Facet::Mutation::Client.create(
      db, "core", "Comment",
      doc_id: doc_id,
      content: %({"target": "iam.Account.01HOSTID", "author": "iam.Account.#{author}", "body": #{body.to_json}}),
      actioner_id: "system",
    )
  end
  doc_id
end

describe "sidecar author-scoped RBAC" do
  before_each do
    seed_test_doctypes
    seed_test_roles(with_db { |db| db })
  end

  it "lists only the caller's own comments via the author-scoped read grant" do
    mine_id = seed_authored_comment("alice", "mine")
    seed_authored_comment("bob", "theirs")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = list_documents_http("core", "Comment")
    assert_http_status(resp, 200)
    ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
    ids.should contain(mine_id)
    ids.size.should eq(1)
  end

  it "reads the caller's own comment" do
    comment_id = seed_authored_comment("alice", "hello")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = get_document_http("core", "Comment", comment_id)
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"]["body"].as_s.should eq("hello")
  end

  it "updates the caller's own comment" do
    comment_id = seed_authored_comment("alice", "before")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = patch_document_http("core", "Comment", comment_id, %({"body": "after"}))
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"]["body"].as_s.should eq("after")
  end

  it "denies updating another user's comment with 404 (non-disclosing)" do
    comment_id = seed_authored_comment("bob", "not yours")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = patch_document_http("core", "Comment", comment_id, %({"body": "hijack"}))
    # The author-scoped grant passes the class gate, but bob's row fails
    # the scope check — the write side answers the non-disclosing 404,
    # same as the read side for a row the caller cannot see.
    assert_http_status(resp, 404)
  end

  it "denies reading another user's comment with 404 (non-disclosing)" do
    comment_id = seed_authored_comment("bob", "secret")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = get_document_http("core", "Comment", comment_id)
    assert_http_status(resp, 404)
  end

  it "deletes the caller's own comment" do
    comment_id = seed_authored_comment("alice", "bye")

    Fiber.current.auth_context = with_db { |db| editor_ctx(db, "alice") }
    resp = delete_document_http("core", "Comment", comment_id)
    assert_http_status(resp, 204)
  end
end
