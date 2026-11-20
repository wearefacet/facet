# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/util/script_helpers"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/artifact/grants"
require "../../src/artifact/admin"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Specs for the artifact admin surface:
#
# - `Artifact::Admin` — the read-only operator listing (`read *.*` gate).
# - `GET /Api/Artifacts` / `GET /Api/Artifacts/:id/grants` /
#   `GET /Api/Artifacts/:id/references` — the operator routes.
#
# Fixtures insert straight into the artifact tables (the service is a pure
# reader — driving the uploader would only exercise its own specs again).
# Every fixture filename carries the `adminspec-` prefix so `before_each`
# can sweep exactly those rows; the artifact child tables cascade.
ART_DOMAIN = "artspecdom"

private def adm_truncate
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Inserts one `artifacts` row. Returns the id.
private def adm_insert_artifact(db, filename : String, mime : String = "image/png", size : Int64 = 10) : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) " \
    "VALUES ($1, $2, $3, $4, $5, $6)",
    id, filename, mime, size, "sha-#{id}", "path/#{id}",
  )
  id
end

# Inserts one `artifact_owners` row. Returns the owner id.
private def adm_insert_owner(db, artifact_id : String, doc_id : String = Facet::Util::ScriptHelpers.ulid,
                             created_by : String = "system") : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by) " \
    "VALUES ($1, $2, $3, $4, $5, $6, $7)",
    id, artifact_id, ART_DOMAIN, "Asset", doc_id, "file", created_by,
  )
  id
end

# Inserts one `artifact_grants` row. Returns the grant id.
private def adm_insert_grant(db, artifact_id : String, owner_id : String, kind : String,
                             expires_at : Time? = nil, created_by : String = "system") : String
  id = Facet::Util::ScriptHelpers.ulid
  db.exec(
    "INSERT INTO artifact_grants (id, artifact_id, owner_id, kind, expires_at, created_by) " \
    "VALUES ($1, $2, $3, $4, $5, $6)",
    id, artifact_id, owner_id, kind, expires_at, created_by,
  )
  id
end

# Inserts one `artifact_references` row (optional projection row included).
private def adm_insert_reference(db, artifact_id : String, domain : String, resource_id : String,
                                 field : String, with_projection = true,
                                 display_name : String? = nil) : Nil
  db.exec(
    "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field) " \
    "VALUES ($1, $2, $3, $4)",
    artifact_id, domain, resource_id, field,
  )
  return unless with_projection
  db.exec(
    "INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, display_name, updated_at, created_at) " \
    "VALUES ($1, $2, $3, '{}', 1, '[]', '{}', 'state', $4, now(), now())",
    domain, "Asset", resource_id, display_name,
  )
end

# Builds an authenticated context for a freshly-seeded role with the given
# permissions.
private def adm_auth(db, account_id : String, role_id : String, perms : Array(JSON::Any)) : Facet::RBAC::AuthContext
  create_role_projection(db, role_id, perms)
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe Facet::Artifact::Admin do
  before_each { adm_truncate }

  it "lists live artifacts with their child-table counts" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-a.png")
      owner = adm_insert_owner(db, art)
      adm_insert_grant(db, art, owner, "permanent")
      adm_insert_grant(db, art, owner, "ephemeral", expires_at: 1.minute.from_now)
      adm_insert_grant(db, art, owner, "ephemeral", expires_at: 1.minute.ago)
      adm_insert_reference(db, art, ART_DOMAIN, Facet::Util::ScriptHelpers.ulid, "file")

      result = Facet::Artifact::Admin.list(db, auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Artifact::Admin::Result)
      list = result.as(Facet::Artifact::Admin::Result)
      list.total.should eq(1)

      row = list.items.first
      row.id.should eq(art)
      row.filename.should eq("adminspec-a.png")
      row.uploaded_by.should eq("system")
      row.owner_count.should eq(1)
      row.grant_count.should eq(2) # live only: permanent + unexpired ephemeral
      row.reference_count.should eq(1)
    end
  end

  it "names the earliest owner row as the uploader" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-uploader.png")
      # The later append (copy / re-attach) is inserted first; pinning the
      # original row older proves the choice reads `created_at`, not
      # insertion order.
      adm_insert_owner(db, art, created_by: "second")
      first = adm_insert_owner(db, art, created_by: "first")
      db.exec("UPDATE artifact_owners SET created_at = now() - interval '1 hour' WHERE id = $1", first)

      row = Facet::Artifact::Admin.list(db, auth_context: Facet::RBAC::AuthContext.system)
        .as(Facet::Artifact::Admin::Result).items.first
      row.uploaded_by.should eq("first")
    end
  end

  it "leaves uploaded_by nil when the artifact has no owner rows" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-ownerless.png")

      row = Facet::Artifact::Admin.list(db, auth_context: Facet::RBAC::AuthContext.system)
        .as(Facet::Artifact::Admin::Result).items.first
      row.uploaded_by.should be_nil
    end
  end

  it "excludes tombstones by default and lists them on deleted__eq=true" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-live.png")
      tomb = adm_insert_artifact(db, "adminspec-dead.png")
      db.exec("UPDATE artifacts SET deleted_at = now() WHERE id = $1", tomb)

      result = Facet::Artifact::Admin.list(db, auth_context: Facet::RBAC::AuthContext.system)
      result.as(Facet::Artifact::Admin::Result).total.should eq(1)
      result.as(Facet::Artifact::Admin::Result).items.first.filename.should eq("adminspec-live.png")

      deleted = Facet::Artifact::Admin.list(
        db,
        filters: {"deleted__eq" => JSON::Any.new("true")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      deleted.as(Facet::Artifact::Admin::Result).items.first.filename.should eq("adminspec-dead.png")

      all = Facet::Artifact::Admin.list(
        db,
        filters: {"deleted__eq" => JSON::Any.new(false)},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      all.as(Facet::Artifact::Admin::Result).total.should eq(1)
      all.as(Facet::Artifact::Admin::Result).items.first.filename.should eq("adminspec-live.png")
    end
  end

  it "filters by id, filename match, and mime_type eq" do
    with_db do |db|
      target = adm_insert_artifact(db, "adminspec-report.pdf", mime: "application/pdf")
      adm_insert_artifact(db, "adminspec-photo.png", mime: "image/png")

      by_id = Facet::Artifact::Admin.list(
        db,
        filters: {"id__match" => JSON::Any.new(target[-8..])},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      items = by_id.as(Facet::Artifact::Admin::Result).items
      items.size.should eq(1)
      items.first.id.should eq(target)

      by_name = Facet::Artifact::Admin.list(
        db,
        filters: {"filename__match" => JSON::Any.new("report")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      items = by_name.as(Facet::Artifact::Admin::Result).items
      items.size.should eq(1)
      items.first.mime_type.should eq("application/pdf")

      by_mime = Facet::Artifact::Admin.list(
        db,
        filters: {"mime_type__eq" => JSON::Any.new("image/png")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      items = by_mime.as(Facet::Artifact::Admin::Result).items
      items.size.should eq(1)
      items.first.filename.should eq("adminspec-photo.png")
    end
  end

  it "sorts by created_at descending by default and paginates" do
    with_db do |db|
      3.times { |i| adm_insert_artifact(db, "adminspec-p#{i}.png") }

      result = Facet::Artifact::Admin.list(
        db,
        page: 2,
        items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system,
      )
      list = result.as(Facet::Artifact::Admin::Result)
      # Offset-relative: one artifact remains from page 2's offset.
      list.total.should eq(1)
      list.items.size.should eq(1)

      sorted = Facet::Artifact::Admin.list(
        db,
        sort: ["filename"],
        auth_context: Facet::RBAC::AuthContext.system,
      )
      names = sorted.as(Facet::Artifact::Admin::Result).items.map(&.filename)
      names.should eq(names.sort)
    end
  end

  it "denies a caller without wildcard read" do
    with_db do |db|
      result = Facet::Artifact::Admin.list(db, auth_context: Facet::RBAC::AuthContext.denied)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "allows a scoped wildcard-read caller (Scoped passes like the global audit)" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-scoped.png")
      auth = adm_auth(db, "adm_acc_scoped", "adm_role_scoped", [permission_json("read", "*.*", ["$all"])])
      result = Facet::Artifact::Admin.list(db, auth_context: auth)
      result.should be_a(Facet::Artifact::Admin::Result)
    end
  end

  it "answers 404 for the sub-listings of an unknown artifact" do
    with_db do |db|
      missing = Facet::Util::ScriptHelpers.ulid
      Facet::Artifact::Admin.grants(db, Facet::RBAC::AuthContext.system, missing)
        .should be_a(Facet::ServiceError)
      Facet::Artifact::Admin.references(db, Facet::RBAC::AuthContext.system, missing)
        .should be_a(Facet::ServiceError)
    end
  end

  it "lists grants newest first and references with the projection join" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-detail.png")
      owner = adm_insert_owner(db, art)
      g1 = adm_insert_grant(db, art, owner, "permanent", created_by: "admin")
      g2 = adm_insert_grant(db, art, owner, "ephemeral", expires_at: 1.hour.from_now)
      db.exec("UPDATE artifact_grants SET created_at = now() - interval '1 hour' WHERE id = $1", g1)

      grants = Facet::Artifact::Admin.grants(db, Facet::RBAC::AuthContext.system, art)
        .as(Facet::Artifact::Admin::GrantsResult)
      grants.total.should eq(2)
      grants.items.map(&.id).should eq([g2, g1]) # newest first
      grants.items.last.kind.should eq("permanent")
      grants.items.last.expires_at.should be_nil

      resource = Facet::Util::ScriptHelpers.ulid
      adm_insert_reference(db, art, ART_DOMAIN, resource, "file", display_name: "The Report")

      refs = Facet::Artifact::Admin.references(db, Facet::RBAC::AuthContext.system, art)
        .as(Facet::Artifact::Admin::ReferencesResult)
      refs.total.should eq(1)
      row = refs.items.first
      row.domain.should eq(ART_DOMAIN)
      row.doc_type.should eq("Asset")
      row.resource_id.should eq(resource)
      row.display_name.should eq("The Report")
      row.resource_field.should eq("file")
    end
  end

  it "keeps reference rows resolvable when the projection is gone" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-orphan-ref.png")
      adm_insert_reference(db, art, ART_DOMAIN, Facet::Util::ScriptHelpers.ulid, "file", with_projection: false)

      refs = Facet::Artifact::Admin.references(db, Facet::RBAC::AuthContext.system, art)
        .as(Facet::Artifact::Admin::ReferencesResult)
      refs.items.size.should eq(1)
      refs.items.first.doc_type.should be_nil
      refs.items.first.display_name.should be_nil
    end
  end
end

describe "GET /Api/Artifacts" do
  before_each { adm_truncate }

  it "returns the listing in the { data, meta } shape" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-route.png", mime: "application/pdf", size: 42)
      adm_insert_owner(db, art)
      adm_insert_artifact(db, "adminspec-route-ownerless.png")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    row = body["data"].as_a.find! { |r| r["filename"].as_s == "adminspec-route.png" }
    row["mime_type"].as_s.should eq("application/pdf")
    row["size"].as_i.should eq(42)
    row["owner_count"].as_i.should eq(1)
    row["grant_count"].as_i.should eq(0)
    row["reference_count"].as_i.should eq(0)
    row["sha256"].as_s.should_not be_empty
    row["created_at"].as_s.should_not be_empty
    row["uploaded_by"].as_s.should eq("system")
    row["deleted_at"].as_nil.should be_nil
    body["meta"]["count"].as_i.should be > 0
    body["meta"]["more"].as_bool.should be_false
  end

  it "keeps meta.more false while the count stays under the cap" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-more-1.png")
      adm_insert_artifact(db, "adminspec-more-2.png")
    end

    # One row per page over a two-row fixture: the count never reaches the
    # cap, so `more` is false on both pages and `count` carries the real
    # number from each offset.
    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts?items=1&page=1"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["more"].as_bool.should be_false
    body["meta"]["count"].as_i.should eq(2)

    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts?items=1&page=2"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["more"].as_bool.should be_false
    body["meta"]["count"].as_i.should eq(1)
  end

  it "answers null uploaded_by for an artifact without owner rows" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-route-ownerless.png")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts"))
    assert_http_status(resp, 200)

    row = JSON.parse(resp.body)["data"].as_a.find! { |r| r["filename"].as_s == "adminspec-route-ownerless.png" }
    row["uploaded_by"].as_nil.should be_nil
  end

  it "passes the filename filter through the query string" do
    with_db do |db|
      adm_insert_artifact(db, "adminspec-one.png")
      adm_insert_artifact(db, "adminspec-two.png")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts?filters[filename__match]=two"))
    assert_http_status(resp, 200)

    rows = JSON.parse(resp.body)["data"].as_a
    rows.size.should eq(1)
    rows.first["filename"].as_s.should eq("adminspec-two.png")
  end

  it "answers 403 for a denied caller" do
    resp = call_api_as(HTTP::Request.new("GET", "/Api/Artifacts"), Facet::RBAC::AuthContext.denied)
    assert_http_status(resp, 403)
  end

  it "keeps the route outside the domain gate" do
    # /Api/Artifacts must not be read as /Api/:domain — a disabled or
    # unknown domain would otherwise answer 404 before the route runs.
    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts"))
    assert_http_status(resp, 200)
  end
end

describe "GET /Api/Artifacts/:id/grants and /references" do
  before_each { adm_truncate }

  it "returns the grants and references of one artifact" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-sub.png")
      owner = adm_insert_owner(db, art)
      adm_insert_grant(db, art, owner, "permanent", created_by: "op")
      resource = Facet::Util::ScriptHelpers.ulid
      adm_insert_reference(db, art, ART_DOMAIN, resource, "longtext", display_name: "Doc A")
    end

    with_db do |db|
      art = db.query_one("SELECT id FROM artifacts WHERE filename = 'adminspec-sub.png'", as: String)

      resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts/#{art}/grants"))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      grants = body["data"].as_a
      grants.size.should eq(1)
      grants.first["kind"].as_s.should eq("permanent")
      grants.first["created_by"].as_s.should eq("op")
      grants.first["expires_at"].as_nil.should be_nil

      resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts/#{art}/references"))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      refs = body["data"].as_a
      refs.size.should eq(1)
      refs.first["domain"].as_s.should eq(ART_DOMAIN)
      refs.first["doc_type"].as_s.should eq("Asset")
      refs.first["display_name"].as_s.should eq("Doc A")
      refs.first["resource_field"].as_s.should eq("longtext")
    end
  end

  it "answers 404 for an unknown artifact" do
    missing = Facet::Util::ScriptHelpers.ulid
    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts/#{missing}/grants"))
    assert_http_status(resp, 404)

    resp = call_api(HTTP::Request.new("GET", "/Api/Artifacts/#{missing}/references"))
    assert_http_status(resp, 404)
  end

  it "answers 403 for a denied caller" do
    missing = Facet::Util::ScriptHelpers.ulid
    resp = call_api_as(HTTP::Request.new("GET", "/Api/Artifacts/#{missing}/grants"), Facet::RBAC::AuthContext.denied)
    assert_http_status(resp, 403)
  end
end

describe "revoke *.* operator branch of Grants.revoke" do
  before_each { adm_truncate }

  it "lets a revoke-*.* holder delete a grant without publish_artifact" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-revoke.png")
      owner = adm_insert_owner(db, art)
      gid = adm_insert_grant(db, art, owner, "permanent")

      auth = adm_auth(db, "adm_acc_revoke", "adm_role_revoke", [permission_json("revoke", "*.*")])
      res = Facet::Artifact::Grants.revoke(db, auth, gid)
      res.should be_nil

      count = db.query_one("SELECT COUNT(*) FROM artifact_grants WHERE id = $1", gid, as: Int64)
      count.should eq(0)
    end
  end

  it "still denies a caller with only wildcard read" do
    with_db do |db|
      art = adm_insert_artifact(db, "adminspec-revoke-deny.png")
      owner = adm_insert_owner(db, art)
      gid = adm_insert_grant(db, art, owner, "permanent")

      auth = adm_auth(db, "adm_acc_read", "adm_role_read", [permission_json("read", "*.*")])
      res = Facet::Artifact::Grants.revoke(db, auth, gid)
      res.should be_a(Facet::Artifact::Grants::Error)
      res.as(Facet::Artifact::Grants::Error).status.should eq(403)

      count = db.query_one("SELECT COUNT(*) FROM artifact_grants WHERE id = $1", gid, as: Int64)
      count.should eq(1)
    end
  end
end
