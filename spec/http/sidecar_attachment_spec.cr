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
require "../../src/artifact/store"

# Initialize the HTTP handler chain once (idempotent across spec files).
HTTPTest.init

# ── Helpers ──────────────────────────────────────────────────────────────

# Registers the sidecar `core.Attachment` doctype from the production seed
# directory, so the nested-route specs exercise the real definition (with the
# `uploaded_by` reference anchor, the `mine` scope, and the Lua `create` hook
# that forces uploadership). Mirrors `Doctype::Seed#seed_directory`'s
# script-injection step so the stored definition carries the Lua hook.
def seed_sidecar_attachment_doctype : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "data", "seeds", "core.Attachment")
    content = attachment_seed_definition_with_script(dir)
    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", content, Facet::RBAC::AuthContext.system)
    raise "attachment sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

# Parses a seed directory's `definition.yml` and, if a co-located
# `script.lua` exists, injects it as the definition's `script` field.
# Distinct from the `core.Comment` twin so both spec files can compile
# together without redefining a shared helper.
def attachment_seed_definition_with_script(dir : String) : String
  definition_path = File.join(dir, "definition.yml")
  yaml = YAML.parse(File.read(definition_path))
  parsed = Facet::Doctype::YamlHelper.to_json_any(yaml)

  script_path = File.join(dir, "script.lua")
  if File.exists?(script_path)
    parsed.as_h["script"] = JSON::Any.new(File.read(script_path))
  end
  parsed.to_json
end

# Registers an aggregate-root host doctype in `host_domain` that declares a
# single `sidecars` entry named `attachments`, pointing at `core.Attachment`
# via the `target` reference column.
def create_host_doctype_with_attachments_sidecar!(host_domain : String, host_doctype : String) : Nil
  create_domain_http(host_domain)
  body = %({
    "doctype": "#{host_doctype}",
    "domain": "#{host_domain}",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": { "type": "string" }
    },
    "sidecars": {
      "attachments": { "doctype": "core.Attachment", "column": "target" }
    }
  })
  resp = create_doctype_http(body)
  if resp.status_code != 201
    raise "host doctype create failed (#{resp.status_code}): #{resp.body}"
  end
end

def create_host_document_for_attachments!(host_domain : String, host_doctype : String, name : String) : String
  create_doc_id_http(host_domain, host_doctype, %({"name": #{name.to_json}}))
end

# Builds an authenticated `attachment_owner` context (uploader-scoped
# read/update/delete on `core.Attachment` via `$mine`, NO wildcard).
def attachment_owner_ctx(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.attachment_owner").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def editor_ctx_for_attachments(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def viewer_ctx_for_attachments(db : DB::Connection, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Uploads an artifact with unique bytes and returns its id. The owner row is
# bound to the host document (system context), so the artifact is readable
# when the nested create appends its own owner row against the attachment.
def upload_test_artifact(db : DB::Connection, host_domain : String, host_doctype : String, host_id : String) : String
  bytes = "attachment payload #{Random::Secure.hex(16)}"
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(bytes), "test.bin",
    Facet::RBAC::AuthContext.system,
    host_domain, host_doctype, host_id, "file", nil,
  )
  raise "artifact upload failed: #{result}" unless result.is_a?(Facet::Artifact::Uploader::Result)
  result.artifact_id
end

def assert_error_contains_attachment(resp, text)
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

# Request helpers for the 2-segment nested per-document attachment paths.
# Distinct names from the `core.Comment` twin so both spec files compile
# together.
def get_nested_attachment_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}")
  call_api(request)
end

def patch_nested_attachment_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String, json_body : String) : HTTP::Client::Response
  request = HTTP::Request.new("PATCH", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}", body: json_body)
  call_api(request)
end

def delete_nested_attachment_http(domain : String, doctype : String, id : String, segment : String, sidecar_id : String) : HTTP::Client::Response
  request = HTTP::Request.new("DELETE", "/Api/#{domain}/#{doctype}/#{id}/#{segment}/#{sidecar_id}")
  call_api(request)
end

# ── Tests ─────────────────────────────────────────────────────────────

describe "Attachment sidecar (core.Attachment)" do
  before_each do
    seed_sidecar_attachment_doctype
    seed_test_roles(with_db { |db| db })
    # Default to system bypass for non-RBAC specs. RBAC specs override
    # `Fiber.current.auth_context` in their own blocks.
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  describe "POST nested create (happy path)" do
    it "creates an attachment with target from the path and forced uploaded_by" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      Fiber.current.auth_context = with_db { |db| editor_ctx_for_attachments(db, "01UPLOADER") }
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"name": "Contract.pdf", "file": "#{artifact_id}"}))
      assert_http_status(resp, 201)
      body = JSON.parse(resp.body)
      body["data"]["target"].as_s.should eq("hr.Employee.#{host_id}")
      body["data"]["name"].as_s.should eq("Contract.pdf")
      body["data"]["file"].as_s.should eq(artifact_id)
      body["data"]["uploaded_by"].as_s.should eq("iam.Account.01UPLOADER")
    end

    it "leaves uploaded_by null on a system-context create" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      # before_each set the system context; do not override it.
      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"name": "System file", "file": "#{artifact_id}"}))
      assert_http_status(resp, 201)
      # Null fields are omitted from the response payload — `uploaded_by`
      # must be absent, not spoofed.
      JSON.parse(resp.body)["data"]?.try(&.["uploaded_by"]?).should be_nil
    end

    it "appends an artifact owner row against the attachment document" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Owned file", "file": "#{artifact_id}"}))

      with_db do |db|
        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.any? { |o| o.doc_id == attachment_id }.should be_true
      end
    end
  end

  describe "POST sad paths" do
    it "rejects a body that supplies `target` with 400 (route owns target)" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"target": "hr.Employee.somebody_else", "name": "spoof", "file": "01HX8W3VJN8Q7M2PKF5CDRB9AE"}))
      assert_http_status(resp, 400)
      assert_error_contains_attachment(resp, "target")
    end

    it "rejects a missing `file` field with 422" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"name": "No file"}))
      assert_http_status(resp, 422)
      assert_error_contains_attachment(resp, "file")
    end

    it "rejects a `file` value that is not a ULID with 422" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"name": "Bad id", "file": "not-a-ulid"}))
      assert_http_status(resp, 422)
      assert_error_contains_attachment(resp, "file")
    end

    it "rejects a missing `name` field with 422" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"file": "01HX8W3VJN8Q7M2PKF5CDRB9AE"}))
      assert_http_status(resp, 422)
      assert_error_contains_attachment(resp, "name")
    end

    it "blocks the flat create route with 422" do
      resp = create_document_http("core", "Attachment",
        %({"name": "Flat", "file": "01HX8W3VJN8Q7M2PKF5CDRB9AE"}))
      assert_http_status(resp, 422)
      assert_error_contains_attachment(resp, "nested")
    end
  end

  describe "GET nested list and read" do
    it "lists only the attachments of that host and reads one back" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_a = create_host_document_for_attachments!("hr", "Employee", "Alice")
      host_b = create_host_document_for_attachments!("hr", "Employee", "Bob")

      artifact_a = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_a) }
      a1 = create_child_doc_id_http("hr", "Employee", host_a, "attachments",
        %({"name": "On A", "file": "#{artifact_a}"}))
      _a2 = create_child_doc_id_http("hr", "Employee", host_a, "attachments",
        %({"name": "On A again", "file": "#{artifact_a}"}))
      artifact_b = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_b) }
      _b1 = create_child_doc_id_http("hr", "Employee", host_b, "attachments",
        %({"name": "On B", "file": "#{artifact_b}"}))

      resp = list_nested_http("hr", "Employee", host_a, "attachments")
      assert_http_status(resp, 200)
      names = JSON.parse(resp.body)["data"].as_a.map(&.["data"]["name"].as_s)
      names.size.should eq(2)
      names.should contain("On A")
      names.should contain("On A again")

      read_resp = get_nested_attachment_http("hr", "Employee", host_a, "attachments", a1)
      assert_http_status(read_resp, 200)
      JSON.parse(read_resp.body)["data"]["name"].as_s.should eq("On A")
    end

    it "returns 404 for an unknown attachment id" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      resp = get_nested_attachment_http("hr", "Employee", host_id, "attachments", "01NOPE0000000000000000000")
      assert_http_status(resp, 404)
    end
  end

  describe "PATCH and DELETE through the nested route" do
    it "renames an attachment and keeps uploaded_by intact" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      Fiber.current.auth_context = with_db { |db| editor_ctx_for_attachments(db, "01EDITOR") }
      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Before", "file": "#{artifact_id}"}))

      resp = patch_nested_attachment_http("hr", "Employee", host_id, "attachments", attachment_id,
        %({"name": "After"}))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"]["name"].as_s.should eq("After")
      body["data"]["uploaded_by"].as_s.should eq("iam.Account.01EDITOR")
    end

    it "replaces the file with a new artifact id" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_1 = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }
      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Replace me", "file": "#{artifact_1}"}))

      artifact_2 = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }
      resp = patch_nested_attachment_http("hr", "Employee", host_id, "attachments", attachment_id,
        %({"file": "#{artifact_2}"}))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["file"].as_s.should eq(artifact_2)

      # The replacement appends an owner row for the new artifact against
      # the attachment document.
      with_db do |db|
        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_2)
        owners.any? { |o| o.doc_id == attachment_id }.should be_true
      end
    end

    it "tombstones an attachment through the nested delete route" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }
      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Doomed", "file": "#{artifact_id}"}))

      resp = delete_nested_attachment_http("hr", "Employee", host_id, "attachments", attachment_id)
      assert_http_status(resp, 204)

      list_resp = list_nested_http("hr", "Employee", host_id, "attachments")
      assert_http_status(list_resp, 200)
      JSON.parse(list_resp.body)["data"].as_a.size.should eq(0)
    end
  end

  describe "RBAC" do
    it "denies a nested create to a caller with read-only access (403)" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")

      # `viewer` has wildcard `read *.*` (host read gate passes) but no
      # `create` permission — the nested create grant is absent.
      Fiber.current.auth_context = with_db { |db| viewer_ctx_for_attachments(db, "01VIEWER") }
      resp = create_child_document_http("hr", "Employee", host_id, "attachments",
        %({"name": "No", "file": "01HX8W3VJN8Q7M2PKF5CDRB9AE"}))
      assert_http_status(resp, 403)
    end

    it "returns a non-disclosing 404 when the host does not exist" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")

      # A `viewer` exercises the RBAC existence path of gate 1; the system
      # principal is covered by the same lock in `SidecarHandler.create` —
      # it answers the 404 for every principal (B-344).
      Fiber.current.auth_context = with_db { |db| viewer_ctx_for_attachments(db, "01VIEWER") }
      resp = create_child_document_http("hr", "Employee", "01NONEXISTENTHOST", "attachments",
        %({"name": "Ghost", "file": "01HX8W3VJN8Q7M2PKF5CDRB9AE"}))
      assert_http_status(resp, 404)
    end

    it "lets an attachment_owner read and rename their own attachment via the flat route" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      account_id = "01OWNER"
      Fiber.current.auth_context = with_db { |db| editor_ctx_for_attachments(db, account_id) }
      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Mine", "file": "#{artifact_id}"}))

      # Switch to the attachment_owner role (read/update/delete with $mine
      # on core.Attachment, no wildcard) and read + rename the attachment.
      Fiber.current.auth_context = with_db { |db| attachment_owner_ctx(db, account_id) }
      read_resp = get_document_http("core", "Attachment", attachment_id)
      assert_http_status(read_resp, 200)
      JSON.parse(read_resp.body)["data"]["name"].as_s.should eq("Mine")

      patch_resp = patch_document_http("core", "Attachment", attachment_id, %({"name": "Renamed"}))
      assert_http_status(patch_resp, 200)
      JSON.parse(patch_resp.body)["data"]["name"].as_s.should eq("Renamed")
    end

    it "hides another uploader's attachment from an attachment_owner (404)" do
      create_host_doctype_with_attachments_sidecar!("hr", "Employee")
      host_id = create_host_document_for_attachments!("hr", "Employee", "Alice")
      artifact_id = with_db { |db| upload_test_artifact(db, "hr", "Employee", host_id) }

      Fiber.current.auth_context = with_db { |db| editor_ctx_for_attachments(db, "01OWNER") }
      attachment_id = create_child_doc_id_http("hr", "Employee", host_id, "attachments",
        %({"name": "Secret", "file": "#{artifact_id}"}))

      Fiber.current.auth_context = with_db { |db| attachment_owner_ctx(db, "01INTRUDER") }
      resp = get_document_http("core", "Attachment", attachment_id)
      assert_http_status(resp, 404)
    end
  end
end
