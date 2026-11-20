# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Specs for the deletion / restore UX HTTP surface:
#
# - `POST /Api/:domain/:doctype/:id/restore` — resolves the pre-delete
#   mutation internally and delegates to `Audit::Rollback`.
# - `GET /Api/:domain/:doctype?deleted=true` — the trash listing.
def restore_http_create_doctype(db, doctype : String, scopes_json = "{}") : Nil
  ensure_domain(db, "trash")
  defn_json = %({
    "doctype": "#{doctype}",
    "domain": "trash",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string"},
      "department": {"type": "string"}
    },
    "scopes": #{scopes_json}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

def restore_http_role(db, role_id : String, permissions_json : String) : Facet::RBAC::AuthContext
  content = %({"name": "#{role_id}", "visible_tags": ["default"], "permissions": [#{permissions_json}]})
  Facet::Mutation::Client.create(db, "iam", "Role", doc_id: role_id, content: content, actioner_id: "system")
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(role_id, role)
end

def restore_http_post_restore(domain : String, doctype : String, doc_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/#{doc_id}/restore"))
end

describe "Document restore HTTP endpoint" do
  before_each do
    with_db do |db|
      restore_http_create_doctype(db, "Task")
    end
  end

  it "restores a tombstone with prior history and the document is live again" do
    doc_id = create_doc_id_http("trash", "Task", %({"name": "created", "department": "eng"}))
    patch_document_http("trash", "Task", doc_id, %({"name": "updated"}))
    delete_document_http("trash", "Task", doc_id)

    # Tombstoned: the single-doc read is 410 Gone.
    gone = get_document_http("trash", "Task", doc_id)
    assert_http_status(gone, 410)

    resp = restore_http_post_restore("trash", "Task", doc_id)
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["meta"]["id"].as_s.should eq(doc_id)
    body["data"]["name"].as_s.should eq("updated")

    # Live again, with the pre-delete content.
    read = get_document_http("trash", "Task", doc_id)
    assert_http_status(read, 200)
    JSON.parse(read.body)["data"]["name"].as_s.should eq("updated")
  end

  it "restores a create→delete tombstone to the create content" do
    doc_id = create_doc_id_http("trash", "Task", %({"name": "created", "department": "eng"}))
    delete_document_http("trash", "Task", doc_id)

    resp = restore_http_post_restore("trash", "Task", doc_id)
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"]["name"].as_s.should eq("created")
  end

  it "returns 409 when the document is not deleted" do
    doc_id = create_doc_id_http("trash", "Task", %({"name": "live", "department": "eng"}))

    resp = restore_http_post_restore("trash", "Task", doc_id)
    assert_http_status(resp, 409)
    JSON.parse(resp.body)["error"].as_s.should eq("Document is not deleted")
  end

  it "returns 404 when the document has no mutation history" do
    resp = restore_http_post_restore("trash", "Task", "01NOSUCHDOCUMENTID000")
    assert_http_status(resp, 404)
  end

  it "returns 403 when the caller may not update the document" do
    auth = nil
    doc_id = nil
    with_db do |db|
      auth = restore_http_role(db, "restore_viewer_role", %({"action": "read", "on": "trash.Task"}))

      doc_id = create_doc_id_http("trash", "Task", %({"name": "owned", "department": "eng"}))
      delete_document_http("trash", "Task", doc_id)
    end

    request = HTTP::Request.new("POST", "/Api/trash/Task/#{doc_id}/restore")
    resp = call_api_as(request, auth)
    assert_http_status(resp, 403)

    # Still tombstoned — the denial did not resurrect the document.
    gone = get_document_http("trash", "Task", doc_id.not_nil!)
    assert_http_status(gone, 410)
  end
end

describe "Trash listing (?deleted=true)" do
  before_each do
    with_db do |db|
      restore_http_create_doctype(
        db, "Project",
        scopes_json: %({"engineering": {"where": {"department": "engineering"}}}),
      )
    end
  end

  it "returns tombstones instead of live rows" do
    eng = create_doc_id_http("trash", "Project", %({"name": "eng doc", "department": "engineering"}))
    mkt = create_doc_id_http("trash", "Project", %({"name": "mkt doc", "department": "marketing"}))
    delete_document_http("trash", "Project", eng)
    delete_document_http("trash", "Project", mkt)

    # Live listing: empty. Trash listing: both tombstones.
    live = list_documents_http("trash", "Project")
    assert_http_status(live, 200)
    JSON.parse(live.body)["data"].as_a.size.should eq(0)

    trash = list_documents_http("trash", "Project", "deleted=true")
    assert_http_status(trash, 200)
    body = JSON.parse(trash.body)
    body["data"].as_a.size.should eq(2)
    names = body["data"].as_a.map(&.["data"].["name"].as_s)
    names.should contain("eng doc")
    names.should contain("mkt doc")
  end

  it "applies RBAC row scoping to tombstones" do
    eng = create_doc_id_http("trash", "Project", %({"name": "eng doc", "department": "engineering"}))
    mkt = create_doc_id_http("trash", "Project", %({"name": "mkt doc", "department": "marketing"}))
    delete_document_http("trash", "Project", eng)
    delete_document_http("trash", "Project", mkt)

    auth = nil
    with_db do |db|
      auth = restore_http_role(
        db, "scoped_reader_role",
        %({"action": "read", "on": "trash.Project", "scope": "$engineering"}),
      )
    end

    request = HTTP::Request.new("GET", "/Api/trash/Project?deleted=true")
    resp = call_api_as(request, auth)
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["data"].as_a.size.should eq(1)
    body["data"][0]["data"]["name"].as_s.should eq("eng doc")
  end

  it "produces a distinct ETag from the live listing" do
    doc_id = create_doc_id_http("trash", "Project", %({"name": "eng doc", "department": "engineering"}))
    delete_document_http("trash", "Project", doc_id)

    live = list_documents_http("trash", "Project")
    trash = list_documents_http("trash", "Project", "deleted=true")
    live_etag = live.headers["ETag"]?
    trash_etag = trash.headers["ETag"]?
    live_etag.should_not be_nil
    trash_etag.should_not be_nil
    live_etag.should_not eq(trash_etag)
  end

  it "supports deleted_at range filters with UTC normalization" do
    doc_id = create_doc_id_http("trash", "Project", %({"name": "eng doc", "department": "engineering"}))
    delete_document_http("trash", "Project", doc_id)

    resp = list_documents_http("trash", "Project", "deleted=true&filters[deleted_at__gte]=2000-01-01T00:00:00%2B02:00")
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"].as_a.size.should eq(1)

    resp = list_documents_http("trash", "Project", "deleted=true&filters[deleted_at__lte]=2000-01-01T00:00:00Z")
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"].as_a.size.should eq(0)
  end
end
