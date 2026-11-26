# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "yaml"
require "../../src/http/server"
require "../../src/doctype/yaml_helper"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/iam_helper"
require "../../src/rbac"
require "../../src/iam"

# Initialize the HTTP handler chain once (idempotent across spec files).
HTTPTest.init

# ── Helpers ──────────────────────────────────────────────────────────────

# Registers an aggregate-root host doctype in `host_domain` that declares a
# single `sidecars` entry named `comments`, pointing at `core.Comment` via the
# `target` reference column. Returns nothing; the doctype is created through
# the HTTP layer so the cache and projection paths match production.
#
# The host has one optional `name` string field so the host document body is
# a valid object (only `target` on the sidecar is the attachment anchor).
def create_host_doctype_with_comments_sidecar!(host_domain : String, host_doctype : String) : Nil
  # `Doctype::Create` rejects a doctype whose domain has no `core.Domain`
  # projection. The per-test TRUNCATE wipes domains, so ensure it exists.
  create_domain_http(host_domain)
  body = %({
    "doctype": "#{host_doctype}",
    "domain": "#{host_domain}",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": { "type": "string" }
    },
    "sidecars": {
      "comments": { "doctype": "core.Comment", "column": "target" }
    }
  })
  resp = create_doctype_http(body)
  # The domain may already exist from a previous example in the same describe
  # block (create_domain_http returns 422 on duplicate id) — tolerate that.
  if resp.status_code != 201
    raise "host doctype create failed (#{resp.status_code}): #{resp.body}"
  end
end

# Builds an authenticated `comment_author` context (author-scoped
# read/update/delete on `core.Comment`, NO `create` grant, NO wildcard).
# Used for the negative RBAC path.
def comment_author_ctx(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.comment_author").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Builds an `editor` context (wildcard create/update/delete/read). Used for
# the happy-path nested-create, where the caller needs a `create` grant on
# `core.Comment`.
def editor_role_ctx(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Builds a `viewer` context (wildcard `read *.*`, NO create/update/delete).
# Used for the "no create grant → 403" path: the caller can read the host
# (so the host read gate passes), but cannot create `core.Comment`.
def viewer_role_ctx(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Creates a host document and returns its id.
def create_host_document!(host_domain : String, host_doctype : String, name : String) : String
  create_doc_id_http(host_domain, host_doctype, %({"name": #{name.to_json}}))
end

# Asserts the response body carries a structured validation/detail error whose
# combined text contains the given substring (case-insensitive).
private def assert_error_contains(resp, text)
  body = parse_body(resp)
  combined = body["error"].as_s
  if details = body["details"]?
    parts = details.as_a.map do |d|
      msg = d["message"]?.try(&.as_s).to_s
      field = d["field"]?
      field ? "#{field.as_s} #{msg}" : msg
    end
    combined += " " + parts.join(" ")
  end
  combined.downcase.should contain(text)
end

# ── Tests ─────────────────────────────────────────────────────────────

# Request helpers for the 2-segment nested per-document sidecar paths
# (`/Api/:domain/:doctype/:id/:segment/:sidecar_id`). The shared `*_http`
# helpers in `spec/support/http_helpers.cr` cover the flat route and the
# 1-segment collection path only.
def get_nested_doc_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}")
  call_api(request)
end

def patch_nested_doc_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String, json_body : String) : HTTP::Client::Response
  request = HTTP::Request.new("PATCH", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}", body: json_body)
  call_api(request)
end

def delete_nested_doc_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String) : HTTP::Client::Response
  request = HTTP::Request.new("DELETE", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}")
  call_api(request)
end

# Registers the sidecar `core.Comment` doctype from the production seed
# directory, so flat-route and nested-route specs exercise the real
# definition (with the `author` reference field, the `mine` scope, and the
# Lua `create` hook that forces authorship). `Doctype::Create` requires the
# definition's domain to exist as a `core.Domain` document, and the per-test
# TRUNCATE wipes it — so `ensure_domain("core")` runs first.
#
# The seed runner (`Doctype::Seed`) injects the co-located `script.lua` into
# the definition's `script` field before persisting. This helper mirrors that
# step so the doctype stored in `core.DocType` carries the Lua hook — without
# it, `definition.script?` is false and the `create` lifecycle hook never
# runs, so the `author` field is never forced.
def seed_sidecar_comment_doctype : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "data", "seeds", "core.Comment")
    content = parse_seed_definition_with_script(dir)
    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", content, Facet::RBAC::AuthContext.system)
    raise "sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

# Parses a seed directory's `definition.yml` and, if a co-located
# `script.lua` exists, injects it as the definition's `script` field — the
# same step the seed runner (`Doctype::Seed#seed_directory`) performs. Returns
# the JSON string to persist as the `core.DocType` content.
def parse_seed_definition_with_script(dir : String) : String
  definition_path = File.join(dir, "definition.yml")
  yaml = YAML.parse(File.read(definition_path))
  parsed = Facet::Doctype::YamlHelper.to_json_any(yaml)

  script_path = File.join(dir, "script.lua")
  if File.exists?(script_path)
    parsed.as_h["script"] = JSON::Any.new(File.read(script_path))
  end
  parsed.to_json
end

# Seeds a custom `iam.Roles` role carrying `read hr.Employee` PLUS a nested
# grant on the host-side path, with NO flat grant on `core.Comment`. `action`
# is either `"create"` (for the nested-create spec) or `"read"` (for the
# nested-list spec). Returns the qualified role id.
# Used by the cross-domain nested-grant specs.
def seed_nested_grant_role!(db, action : String) : String
  role_id = "iam.Roles.nested_#{action}_comment"
  content = {
    "name"         => "nested_#{action}_comment",
    "description"  => "Nested #{action} grant on hr.Employee.Comment (no flat core.Comment grant).",
    "visible_tags" => ["default"],
    "permissions"  => [
      {"action" => "read", "on" => "hr.Employee"},
      {"action" => action, "on" => "hr.Employee.Comment"},
    ],
  }.to_json
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: role_id,
    content: content,
    actioner_id: "system",
  )
  role_id
end

# Loads a role by its qualified role id from projection content into an
# `AuthContext`. Used by the cross-domain nested-grant specs.
def role_ctx_from_id(db, role_id : String, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "Sidecar nested routes" do
  before_each do
    seed_sidecar_comment_doctype
    seed_test_roles(with_db { |db| db })
    # Default to system bypass for non-RBAC specs. RBAC specs override
    # `Fiber.current.auth_context` in their own `before_each` or block.
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  # ──────────────────────────────────────────────────────────────────────
  # Happy paths
  # ──────────────────────────────────────────────────────────────────────

  describe "POST nested create (happy path)" do
    it "creates a sidecar attached to the host and sets target from the path" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))
      assert_http_status(resp, 201)
      body = JSON.parse(resp.body)
      comment_id = body["meta"]["id"].as_s
      # The route owns `target` — set from the host identity, not from the body.
      body["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
      body["data"]["body"].as_s.should eq("hi")

      # The created comment is readable on the flat GET route.
      get_resp = get_document_http("core", "Comment", comment_id)
      assert_http_status(get_resp, 200)
      JSON.parse(get_resp.body)["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
    end
  end

  describe "GET nested list (happy path)" do
    it "lists only the comments attached to that host" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")

      c1 = create_child_doc_id_http("hr", "Employee", host_a, "comments", %({"body": "on A"}))
      c2 = create_child_doc_id_http("hr", "Employee", host_a, "comments", %({"body": "on A again"}))
      _c3 = create_child_doc_id_http("hr", "Employee", host_b, "comments", %({"body": "on B"}))

      resp = list_nested_http("hr", "Employee", host_a, "comments")
      assert_http_status(resp, 200)
      ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
      ids.should contain(c1)
      ids.should contain(c2)
      ids.size.should eq(2)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Sad paths — handler-level rejection and routing
  # ──────────────────────────────────────────────────────────────────────

  describe "POST sad paths" do
    it "rejects a body that supplies `target` with 400 (route owns target)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"target": "hr.Employee.somebody_else", "body": "spoof"}))
      assert_http_status(resp, 400)
      assert_error_contains(resp, "target")
    end

    it "returns 404 when the host document does not exist" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")

      # A `viewer` (wildcard read, no create) exercises the RBAC existence
      # path of gate 1; the system principal is covered by the B-344 spec
      # below — the handler locks the host row for every principal.
      Fiber.current.auth_context = with_db { |db| viewer_role_ctx(db, "01VIEWER") }
      resp = create_child_document_http("hr", "Employee", "01NONEXISTENTHOST", "comments", %({"body": "hi"}))
      assert_http_status(resp, 404)
    end

    it "returns 404 when the host does not exist, even for the system principal (B-344)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")

      # Gate 1's system bypass answers true for any id, so the handler
      # locks the host row itself — a missing or tombstoned host answers
      # the same non-disclosing 404 for every principal.
      Fiber.current.auth_context = Facet::RBAC::AuthContext.system
      resp = create_child_document_http("hr", "Employee", "01NONEXISTENTHOST", "comments", %({"body": "hi"}))
      assert_http_status(resp, 404)
    end

    it "returns 403 when the caller holds no read grant on the host doctype" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # comment_author has NO read grant on hr.Employee — the host read
      # gate is a class-level denial, surfaced as 403 (the same answer the
      # write gates give). A grant holder that cannot see the host, or a
      # missing host, keeps the non-disclosing 404.
      Fiber.current.auth_context = with_db { |db| comment_author_ctx(db, "01NOREAD") }
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))
      assert_http_status(resp, 403)
    end

    it "returns 404 when the segment is not a sidecar, an action, or a child" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "unknown_segment", %({"body": "hi"}))
      assert_http_status(resp, 404)
    end
  end

  describe "GET sad paths" do
    it "returns 404 when the segment is not registered in sidecars" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = list_nested_http("hr", "Employee", host_id, "unknown_segment")
      assert_http_status(resp, 404)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Flat-route immutability contract (read_only on `target`)
  # ──────────────────────────────────────────────────────────────────────

  describe "PATCH target immutability" do
    it "rejects a PATCH that touches `target` with 422 read_only" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))

      resp = patch_document_http("core", "Comment", comment_id,
        %({"target": "hr.Employee.#{host_id}_tampered"}))
      assert_http_status(resp, 422)
      assert_error_contains(resp, "read-only")
    end

    it "allows a PATCH to `body` (non-target fields are mutable)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))

      resp = patch_document_http("core", "Comment", comment_id, %({"body": "edited"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["body"].as_s.should eq("edited")
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Thread rules (reply_to) and the edit marker (edited_at), both enforced
  # by the Lua create/update hooks in the production seed script.
  # ──────────────────────────────────────────────────────────────────────

  describe "reply_to thread rules" do
    it "creates a reply to a top-level comment on the same host" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      parent_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "top"}))

      resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"body": "reply", "reply_to": "#{parent_id}"}))
      assert_http_status(resp, 201)
      # The bare id supplied by the caller is qualified by Normalize.
      JSON.parse(resp.body)["data"]["reply_to"].as_s.should eq("core.Comment.#{parent_id}")
    end

    it "rejects a reply to a comment attached to a different host" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")
      parent_id = create_child_doc_id_http("hr", "Employee", host_a, "comments", %({"body": "on A"}))

      resp = create_child_document_http("hr", "Employee", host_b, "comments",
        %({"body": "cross host", "reply_to": "#{parent_id}"}))
      assert_http_status(resp, 422)
      assert_error_contains(resp, "same resource")
    end

    it "creates a reply to a reply (multi-level threading)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      parent_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "top"}))

      reply_resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"body": "reply", "reply_to": "#{parent_id}"}))
      assert_http_status(reply_resp, 201)
      reply_id = JSON.parse(reply_resp.body)["meta"]["id"].as_s

      resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"body": "nested", "reply_to": "#{reply_id}"}))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["reply_to"].as_s.should eq("core.Comment.#{reply_id}")
    end

    it "creates a three-level thread on the same host" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      a_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "one"}))
      b_id = create_child_doc_id_http("hr", "Employee", host_id, "comments",
        %({"body": "two", "reply_to": "#{a_id}"}))

      resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"body": "three", "reply_to": "#{b_id}"}))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["reply_to"].as_s.should eq("core.Comment.#{b_id}")
    end

    it "rejects a reply to a reply attached to a different host" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")
      parent_id = create_child_doc_id_http("hr", "Employee", host_a, "comments", %({"body": "on A"}))
      reply_id = create_child_doc_id_http("hr", "Employee", host_a, "comments",
        %({"body": "reply on A", "reply_to": "#{parent_id}"}))

      resp = create_child_document_http("hr", "Employee", host_b, "comments",
        %({"body": "cross host", "reply_to": "#{reply_id}"}))
      assert_http_status(resp, 422)
      assert_error_contains(resp, "same resource")
    end

    it "rejects a reply to a deleted comment" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      parent_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "doomed"}))

      del_resp = delete_nested_doc_http("hr", "Employee", host_id, "comments", parent_id)
      assert_http_status(del_resp, 204)

      resp = create_child_document_http("hr", "Employee", host_id, "comments",
        %({"body": "too late", "reply_to": "#{parent_id}"}))
      assert_http_status(resp, 422)
      assert_error_contains(resp, "does not exist")
    end

    it "rejects changing reply_to after creation and rejects clearing it" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      parent_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "top"}))
      other_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "other top"}))
      reply_id = create_child_doc_id_http("hr", "Employee", host_id, "comments",
        %({"body": "reply", "reply_to": "#{parent_id}"}))

      change_resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", reply_id,
        %({"reply_to": "#{other_id}"}))
      assert_http_status(change_resp, 422)
      assert_error_contains(change_resp, "cannot be changed")

      clear_resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", reply_id,
        %({"reply_to": null}))
      assert_http_status(clear_resp, 422)
      assert_error_contains(clear_resp, "cannot be cleared")
    end
  end

  describe "edited_at edit marker" do
    it "stays unset at create time and is stamped when the body changes" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))

      created = get_nested_doc_http("hr", "Employee", host_id, "comments", comment_id)
      assert_http_status(created, 200)
      JSON.parse(created.body)["data"]["edited_at"]?.try(&.raw).should be_nil

      resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", comment_id, %({"body": "edited"}))
      assert_http_status(resp, 200)
      edited_at = JSON.parse(resp.body)["data"]["edited_at"].as_s
      edited_at.ends_with?("Z").should be_true
    end

    it "does not stamp edited_at when the patch resubmits the same body" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))

      resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", comment_id, %({"body": "hi"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["edited_at"]?.try(&.raw).should be_nil
    end

    it "allows PATCHing reply_to with its current value without stamping edited_at" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      parent_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "top"}))
      reply_id = create_child_doc_id_http("hr", "Employee", host_id, "comments",
        %({"body": "reply", "reply_to": "#{parent_id}"}))

      resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", reply_id,
        %({"reply_to": "core.Comment.#{parent_id}"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["edited_at"]?.try(&.raw).should be_nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # RBAC — the nested grant on the host-scoped path is the sidecar gate.
  # Flat grants on `core.Comment` serve the flat endpoint only and do NOT
  # authorise the nested route.
  # ──────────────────────────────────────────────────────────────────────

  describe "nested sidecar grant gate" do
    it "allows the nested POST for a wildcard writer (editor)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # `editor` holds wildcard create on `*.*`, which covers the nested
      # path `hr.Employee.Comment`.
      Fiber.current.auth_context = with_db { |db| editor_role_ctx(db, "01EDITOR") }
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
    end

    it "denies the nested POST with 403 when the caller has no create grant" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # `viewer` has wildcard `read *.*` (so the host read gate passes) but
      # no `create` permission — the nested create grant is absent.
      Fiber.current.auth_context = with_db { |db| viewer_role_ctx(db, "01VIEWER") }
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))
      assert_http_status(resp, 403)
    end

    it "denies the nested POST with 403 when the caller holds only a flat create grant" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # Flat grants on `core.Comment` serve the flat endpoint only. This
      # caller can read the host (host read gate passes) but holds no
      # nested create grant — the flat `create core.Comment` line must NOT
      # authorise the nested route.
      Fiber.current.auth_context = with_db do |db|
        role_content = {
          "name"         => "flat_commenter",
          "description"  => "read hr.Employee + flat create core.Comment, no nested grant",
          "visible_tags" => ["default"],
          "permissions"  => [
            {"action" => "read", "on" => "hr.Employee"},
            {"action" => "create", "on" => "core.Comment"},
          ],
        }.to_json
        Facet::Mutation::Client.create(
          db, "iam", "Roles",
          doc_id: "iam.Roles.flat_commenter",
          content: role_content,
          actioner_id: "system",
        )
        role_ctx_from_id(db, "iam.Roles.flat_commenter", "01FLATCOMMENT")
      end
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "hi"}))
      assert_http_status(resp, 403)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Author-scoped end-to-end: the Lua create hook → Normalize qualify →
  # $self match — the write path runs through the hook and the re-normalize
  # pass instead of a pre-qualified `author`.
  # ──────────────────────────────────────────────────────────────────────

  describe "author ownership end-to-end" do
    it "stores the caller's qualified account id in `author` via the Lua create hook" do
      # The editor role has wildcard create, so the nested POST succeeds; the
      # Lua create hook then sets author = ctx.actor.id (bare), and the
      # post-hook Normalize qualifies it to iam.Account.<id>.
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      account_id = "01AUTHORHOOK"
      Fiber.current.auth_context = with_db { |db| editor_role_ctx(db, account_id) }
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "by me"}))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["author"].as_s.should eq("iam.Account.#{account_id}")
    end

    it "lets the author read their own nested-created comment via the $mine scope" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      account_id = "01OWNREAD"
      Fiber.current.auth_context = with_db { |db| editor_role_ctx(db, account_id) }
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "mine"}))

      # Switch to the comment_author role (read/update/delete with $mine on
      # core.Comment, no wildcard) and read the comment back.
      Fiber.current.auth_context = with_db { |db| comment_author_ctx(db, account_id) }
      resp = get_document_http("core", "Comment", comment_id)
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["author"].as_s.should eq("iam.Account.#{account_id}")
    end

    it "denies another user from reading the comment with 404 (non-disclosing)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      author_id = "01OWNER"
      other_id = "01INTRUDER"
      Fiber.current.auth_context = with_db { |db| editor_role_ctx(db, author_id) }
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "secret"}))

      Fiber.current.auth_context = with_db { |db| comment_author_ctx(db, other_id) }
      resp = get_document_http("core", "Comment", comment_id)
      assert_http_status(resp, 404)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Cross-domain nested grant: `create hr.Employee.Comment` /
  # `read hr.Employee.Comment` authorise the nested sidecar routes WITHOUT
  # a flat grant on `core.Comment`. The host read grant (`read hr.Employee`)
  # is supplied separately so the host read gate passes.
  # ──────────────────────────────────────────────────────────────────────

  describe "cross-domain nested grant" do
    # The nested create/read grant enforcers
    # (`WriteEnforcer.authorize_sidecar_create`,
    # `ReadEnforcer.sidecar_authorized?`) are wired into `SidecarHandler`,
    # and the handler passes `skip_authorization: true` to `Document::Create`
    # / `Document::List` so the service-layer flat gate on `core.Comment` does
    # not double-deny a nested-grant-only caller. The route gate
    # (host read + nested sidecar grant) is the authoritative gate;
    # the `target` reference filter plus the host read gate restrict the rows.
    it "allows the nested POST with only a nested create grant (no flat core.Comment)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      Fiber.current.auth_context = with_db do |db|
        role_id = seed_nested_grant_role!(db, "create")
        role_ctx_from_id(db, role_id, "01NESTEDCREATE")
      end

      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "via nested grant"}))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
    end

    it "allows the nested GET with only a nested read grant (no flat core.Comment)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # Seed a comment under the host first (system bypass), then verify the
      # nested-read-only caller can list it.
      _comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "seeded"}))

      Fiber.current.auth_context = with_db do |db|
        role_id = seed_nested_grant_role!(db, "read")
        role_ctx_from_id(db, role_id, "01NESTEDREAD")
      end

      resp = list_nested_http("hr", "Employee", host_id, "comments")
      assert_http_status(resp, 200)
      ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
      ids.should contain(_comment_id)
    end

    it "denies the nested POST with 403 when neither grant is present" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      # `viewer` has wildcard `read *.*` (host read gate passes) but no
      # `create` permission anywhere — the nested create grant is absent.
      Fiber.current.auth_context = with_db { |db| viewer_role_ctx(db, "01NOGRANT") }
      resp = create_child_document_http("hr", "Employee", host_id, "comments", %({"body": "no"}))
      assert_http_status(resp, 403)
    end

    it "authorises the nested GET for a host reader via prefix match" do
      # Semantic note: `read hr.Employee` prefix-matches `hr.Employee.Comment`
      # (Permission#matches_path? is prefix-based), so a caller who can read the
      # host inherently holds the nested sidecar read at the route gate
      # (`sidecar_authorized?` returns true). The handler passes
      # `skip_authorization: true` to `Document::List`, so the inner flat scope
      # clause does NOT collapse the result set to `1=0` — the `target`
      # reference filter returns the matching sidecar rows.
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      _comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "seeded"}))

      Fiber.current.auth_context = with_db do |db|
        role_content = {
          "name"         => "host_read_only",
          "description"  => "read hr.Employee only",
          "visible_tags" => ["default"],
          "permissions"  => [{"action" => "read", "on" => "hr.Employee"}],
        }.to_json
        Facet::Mutation::Client.create(
          db, "iam", "Roles",
          doc_id: "iam.Roles.host_read_only",
          content: role_content,
          actioner_id: "system",
        )
        role_ctx_from_id(db, "iam.Roles.host_read_only", "01HOSTREADONLY")
      end

      resp = list_nested_http("hr", "Employee", host_id, "comments")
      assert_http_status(resp, 200)
      ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
      ids.should contain(_comment_id)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Per-document nested sidecar operations (read / update / delete at
  # /Api/:domain/:doctype/:id/:segment/:sidecar_id)
  # ──────────────────────────────────────────────────────────────────

  describe "per-document nested sidecar routes" do
    it "reads a single sidecar document through the nested path" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "read me"}))

      resp = get_nested_doc_http("hr", "Employee", host_id, "comments", comment_id)
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["body"].as_s.should eq("read me")
      body["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
    end

    it "returns 404 for an unknown sidecar document id" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = get_nested_doc_http("hr", "Employee", host_id, "comments", "01NOEXIST")
      assert_http_status(resp, 404)
    end

    it "updates a sidecar document through the nested PATCH path" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "before"}))

      resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", comment_id, %({"body": "after"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["body"].as_s.should eq("after")

      # The change is visible on the flat route too (same projection).
      flat = get_document_http("core", "Comment", comment_id)
      assert_http_status(flat, 200)
      JSON.parse(flat.body)["data"]["body"].as_s.should eq("after")
    end

    it "deletes a sidecar document through the nested DELETE path" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "bye"}))

      resp = delete_nested_doc_http("hr", "Employee", host_id, "comments", comment_id)
      assert_http_status(resp, 204)

      # Tombstoned — the flat read surfaces the tombstone (410 Gone), and
      # the nested collection no longer lists it.
      flat = get_document_http("core", "Comment", comment_id)
      assert_http_status(flat, 410)
      list_resp = list_nested_http("hr", "Employee", host_id, "comments")
      assert_http_status(list_resp, 200)
      ids = JSON.parse(list_resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
      ids.should_not contain(comment_id)
    end

    it "returns 404 when the segment is not a sidecar key" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")

      resp = get_nested_doc_http("hr", "Employee", host_id, "unknown_segment", "01ANY")
      assert_http_status(resp, 404)
    end

    # ── Host binding (S5) ─────────────────────────────────────────────
    #
    # The nested per-document route must bind the sidecar row to the host
    # record of the URL, the same way the collection path binds it with a
    # `target__eq` filter. Without the binding a caller who can read one
    # host record reaches any sidecar by id. A mismatch answers the same
    # non-disclosing 404 as the host read gate.

    it "returns 404 when reading a sidecar attached to another host record (S5)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")
      comment_on_b = create_child_doc_id_http("hr", "Employee", host_b, "comments", %({"body": "on B"}))

      resp = get_nested_doc_http("hr", "Employee", host_a, "comments", comment_on_b)
      assert_http_status(resp, 404)
      resp.body.should_not contain("on B")

      # The same id through its own host still answers.
      own = get_nested_doc_http("hr", "Employee", host_b, "comments", comment_on_b)
      assert_http_status(own, 200)
      JSON.parse(own.body)["data"]["body"].as_s.should eq("on B")
    end

    it "returns 404 when updating a sidecar attached to another host record (S5)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")
      comment_on_b = create_child_doc_id_http("hr", "Employee", host_b, "comments", %({"body": "untouched"}))

      resp = patch_nested_doc_http("hr", "Employee", host_a, "comments", comment_on_b, %({"body": "hijacked"}))
      assert_http_status(resp, 404)

      own = get_nested_doc_http("hr", "Employee", host_b, "comments", comment_on_b)
      assert_http_status(own, 200)
      JSON.parse(own.body)["data"]["body"].as_s.should eq("untouched")
    end

    it "returns 404 when deleting a sidecar attached to another host record (S5)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_a = create_host_document!("hr", "Employee", "Alice")
      host_b = create_host_document!("hr", "Employee", "Bob")
      comment_on_b = create_child_doc_id_http("hr", "Employee", host_b, "comments", %({"body": "survives"}))

      resp = delete_nested_doc_http("hr", "Employee", host_a, "comments", comment_on_b)
      assert_http_status(resp, 404)

      own = get_nested_doc_http("hr", "Employee", host_b, "comments", comment_on_b)
      assert_http_status(own, 200)
      JSON.parse(own.body)["data"]["body"].as_s.should eq("survives")
    end

    it "returns 404 for a cross-record id even when the host id does not exist (S5)" do
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_b = create_host_document!("hr", "Employee", "Bob")
      comment_on_b = create_child_doc_id_http("hr", "Employee", host_b, "comments", %({"body": "private"}))

      resp = get_nested_doc_http("hr", "Employee", "01MISSINGHOST", "comments", comment_on_b)
      assert_http_status(resp, 404)
      resp.body.should_not contain("private")
    end

    it "denies the nested read with 403 when the caller holds no read grant on the host doctype" do
      # `comment_author` holds $mine-scoped grants on core.Comment only — no
      # read on the host doctype, so the host read gate is a class-level
      # denial (403). A grant holder that cannot see the host keeps the
      # non-disclosing 404.
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "hidden"}))

      Fiber.current.auth_context = with_db { |db| comment_author_ctx(db, "01AUTHORONLY") }
      resp = get_nested_doc_http("hr", "Employee", host_id, "comments", comment_id)
      assert_http_status(resp, 403)
    end

    it "serves the nested paths with a nested-grant-only caller and denies the flat route" do
      # Isolation contract: the two paths carry independent RBAC. A caller
      # with host-scoped nested grants (but no flat core.Comment grants)
      # works through the nested per-document route and is denied on the
      # flat route.
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "seeded"}))

      Fiber.current.auth_context = with_db do |db|
        role_id = "iam.Roles.nested_write_comment"
        content = {
          "name"         => "nested_write_comment",
          "description"  => "Host read + nested update/delete, no flat core.Comment grants.",
          "visible_tags" => ["default"],
          "permissions"  => [
            {"action" => "read", "on" => "hr.Employee"},
            {"action" => "update", "on" => "hr.Employee.Comment"},
            {"action" => "delete", "on" => "hr.Employee.Comment"},
          ],
        }.to_json
        Facet::Mutation::Client.create(
          db, "iam", "Roles",
          doc_id: role_id,
          content: content,
          actioner_id: "system",
        )
        role_ctx_from_id(db, role_id, "01NESTEDWRITE")
      end

      # Nested read + update work.
      read_resp = get_nested_doc_http("hr", "Employee", host_id, "comments", comment_id)
      assert_http_status(read_resp, 200)
      patch_resp = patch_nested_doc_http("hr", "Employee", host_id, "comments", comment_id, %({"body": "via nested"}))
      assert_http_status(patch_resp, 200)

      # The flat route is denied — flat grants are independent.
      flat_patch = patch_document_http("core", "Comment", comment_id, %({"body": "via flat"}))
      assert_http_status(flat_patch, 403)
    end

    it "keeps the flat route working for a moderator (independent grants)" do
      # The flat route stays the admin path: an `editor` (wildcard) can
      # update a comment through it, without touching the host's nested path.
      create_host_doctype_with_comments_sidecar!("hr", "Employee")
      host_id = create_host_document!("hr", "Employee", "Alice")
      comment_id = create_child_doc_id_http("hr", "Employee", host_id, "comments", %({"body": "before"}))

      Fiber.current.auth_context = with_db { |db| editor_role_ctx(db, "01MODERATOR") }
      resp = patch_document_http("core", "Comment", comment_id, %({"body": "moderated"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["body"].as_s.should eq("moderated")
    end
  end
end
