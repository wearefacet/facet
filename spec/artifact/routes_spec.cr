# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/grants"
require "../../src/artifact/prune"
require "../../src/artifact/purge"
require "../../src/artifact/routes"
require "../../src/doctype"
require "../../src/doctype/update"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/http/server"
require "../support/http_helper"
require "../support/app_helper"
require "../support/oauth_helper"
require "digest/sha256"
require "json"

# HTTP surface of the artifact system.
#
# Files covered:
#   - src/artifact/routes.cr — the API metadata/grant routes and the
#     bearer serve route (`GET /A/:gid`).
#   - src/artifact/serve.cr — the byte streaming and range serving
#     behind the serve route.
#
# The service layer (uploader, store, access, grants) is exercised directly
# in the sibling specs; here we drive the full Kemal chain so the response
# hardening (Content-Disposition, nosniff, CSP) and range streaming are
# observable end-to-end.
#
# Specs walk every documented rule:
#   1. `POST /Api/core/artifacts` uploads a standalone artifact bound to the
#      uploading account, returning the artifact id. Rejects system uploads,
#      non-multipart requests, and bodies without a `file` part.
#   2. `GET /Api/core/artifacts/:id` returns metadata + a fresh grant URL.
#   3. `POST /Api/core/artifacts/:id/grant` mints an ephemeral grant.
#   4. `POST /Api/core/artifacts/:id/publish` mints a permanent grant.
#   5. `DELETE /Api/core/artifacts/grants/:gid` revokes.
#   6. `GET /A/:gid` streams bytes with the hardening header set.
#   7. range request served (`Content-Range` header on `206`).
#   8. SVG and unknown types served as attachments.
#   9. A standalone upload is readable by the uploading account and not by
#      any other account.

HTTPTest.init

DOMAIN_ROUTES = "artroutes"

def truncate_routes_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Inline Lua script so the doctype declares `publish_artifact`.
ROUTES_PUBLISH_SCRIPT = <<-LUA
  local export = {}
  function export.publish_artifact(ctx, args)
    return ctx.root
  end
  return export
LUA

def setup_routes_doctype(db, doctype = "Asset", with_publish = true)
  ensure_domain(db, DOMAIN_ROUTES)
  file_type = Facet::Doctype::FieldType.parse("file")
  actions = {} of String => Facet::Doctype::ActionDefinition
  actions["publish_artifact"] = Facet::Doctype::ActionDefinition.new if with_publish
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_ROUTES,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
    actions: actions,
    script: with_publish ? ROUTES_PUBLISH_SCRIPT : nil,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  doc_id = Facet::Document::Create.call(
    db, DOMAIN_ROUTES, doctype, %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
  {doctype, doc_id}
end

def routes_auth(db, account_id, role_id, doctype, with_publish = false)
  perms = [permission_json("read", "#{DOMAIN_ROUTES}.#{doctype}")]
  perms << permission_json("publish_artifact", "#{DOMAIN_ROUTES}.#{doctype}") if with_publish
  create_role_projection(db, role_id, perms)
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def routes_png_bytes : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")
end

# Builds a `multipart/form-data` body with a single `file` part carrying the
# given bytes. The boundary is the literal `facet` — the request headers in
# the tests pair this with `Content-Type: multipart/form-data; boundary=facet`.
def multipart_with_file(name : String, filename : String, bytes : Bytes) : String
  String.build do |io|
    io << "--facet\r\n"
    io << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n"
    io << "Content-Type: application/octet-stream\r\n\r\n"
    io.write(bytes)
    io << "\r\n--facet--\r\n"
  end
end

def upload_routes_fixture(db, doctype, doc_id, bytes : Bytes = routes_png_bytes)
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(bytes), "asset.png",
    Facet::RBAC::AuthContext.system,
    DOMAIN_ROUTES, doctype, doc_id, "file", nil,
  )
  result.should be_a(Facet::Artifact::Uploader::Result)
  res = result.as(Facet::Artifact::Uploader::Result)
  owner_id = Facet::Artifact::Store.find_owner_rows(db, res.artifact_id).first.id
  {res.artifact_id, owner_id}
end

# Builds a signed URL for an artifact and returns `{grant_id, url}`.
def mint_url(db, auth, artifact_id)
  signed = Facet::Artifact::Grants.mint_ephemeral(db, auth, artifact_id)
    .as(Facet::Artifact::Grants::SignedURL)
  {signed.grant_id, signed.url}
end

# Builds a caller holding `read *.*` plus (optionally) the `purge *.*`
# operator action — the role shape that operates the force-delete route.
def routes_operator_context(db, with_purge)
  perms = [permission_json("read", "*.*")]
  perms << permission_json("purge", "*.*") if with_purge
  create_role_projection(db, "purge_admin_role", perms)
  create_account_projection(db, "purge_admin", ["purge_admin_role"])
  Facet::RBAC::AuthContext.authenticated(
    "purge_admin",
    Facet::RBAC::ActiveRole.from_projection_content(
      Facet::Mutation::Client.fetch_content(db, "iam", "Role", "purge_admin_role"),
    ),
  )
end

describe "Artifact HTTP routes" do
  before_each { truncate_routes_tables }

  it "POST /Api/core/artifacts rejects system uploads with 403" do
    body = multipart_with_file("file", "upload.png", routes_png_bytes)
    request = HTTP::Request.new("POST", "/Api/core/artifacts",
      headers: HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=facet"},
      body: body)
    response = call_api(request)
    assert_http_status(response, 403)
  end

  it "POST /Api/core/artifacts rejects non-multipart requests with 415" do
    auth = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      auth = routes_auth(db, "alice", "alice_role", doctype)
    end

    request = HTTP::Request.new("POST", "/Api/core/artifacts",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({}))
    response = call_api_as(request, auth)
    assert_http_status(response, 415)
    JSON.parse(response.body)["error"].to_s.should contain("multipart/form-data")
  end

  it "POST /Api/core/artifacts uploads standalone and returns the id" do
    auth = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      auth = routes_auth(db, "alice", "alice_role", doctype)
    end

    body = multipart_with_file("file", "upload.png", routes_png_bytes)
    request = HTTP::Request.new("POST", "/Api/core/artifacts",
      headers: HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=facet"},
      body: body)
    response = call_api_as(request, auth)
    assert_http_status(response, 201)
    json = JSON.parse(response.body)
    artifact_id = json["id"].to_s
    artifact_id.size.should eq(26)
    json["mime_type"].to_s.should eq("image/png")
    json["filename"].to_s.should eq("upload.png")

    # The owner row is bound to the account, not to any document.
    with_db do |db|
      owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
      owners.size.should eq(1)
      owner = owners.first
      owner.doc_type.should eq(Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE)
      owner.doc_id.should eq("alice")
      owner.field_path.should eq(Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH)
    end
  end

  it "POST /Api/core/artifacts re-uploading the same bytes from the same account is idempotent" do
    # The dedup path reuses the existing artifact row, so the owner-row
    # insert collides on `(core, _account, <account_id>, upload)` — the
    # same composite key as the first upload. The insert must collapse to
    # a no-op via `ON CONFLICT DO NOTHING` (invariant #2).
    auth = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      auth = routes_auth(db, "alice", "alice_role", doctype)
    end

    body = multipart_with_file("file", "upload.png", routes_png_bytes)
    first = call_api_as(
      HTTP::Request.new("POST", "/Api/core/artifacts",
        headers: HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=facet"},
        body: body),
      auth,
    )
    assert_http_status(first, 201)
    first_id = JSON.parse(first.body)["id"].to_s

    second = call_api_as(
      HTTP::Request.new("POST", "/Api/core/artifacts",
        headers: HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=facet"},
        body: multipart_with_file("file", "upload.png", routes_png_bytes)),
      auth,
    )
    assert_http_status(second, 201)
    second_id = JSON.parse(second.body)["id"].to_s

    # Same artifact reused (dedup on signature_sha256), one owner row total.
    second_id.should eq(first_id)
    with_db do |db|
      Facet::Artifact::Store.find_owner_rows(db, first_id).size.should eq(1)
    end
  end

  it "POST /Api/core/artifacts rejects a request without a 'file' part" do
    auth = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      auth = routes_auth(db, "alice", "alice_role", doctype)
    end

    body = "--facet\r\nContent-Disposition: form-data; name=\"label\"\r\n\r\nstuff\r\n--facet--\r\n"
    request = HTTP::Request.new("POST", "/Api/core/artifacts",
      headers: HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=facet"},
      body: body)
    response = call_api_as(request, auth)
    assert_http_status(response, 422)
    JSON.parse(response.body)["error"].to_s.should contain("'file'")
  end

  it "a standalone upload is readable by the uploading account" do
    auth = nil
    artifact_id = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      auth = routes_auth(db, "alice", "alice_role", doctype)
      result = Facet::Artifact::Uploader.upload(
        db, IO::Memory.new(routes_png_bytes), "upload.png", auth,
        domain: Facet::Artifact::Store::ACCOUNT_OWNER_DOMAIN,
        doc_type: Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE,
        doc_id: auth.account_id,
        field_path: Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH,
        view_tag: nil,
      )
      result.should be_a(Facet::Artifact::Uploader::Result)
      artifact_id = result.as(Facet::Artifact::Uploader::Result).artifact_id
    end

    request = HTTP::Request.new("GET", "/Api/core/artifacts/#{artifact_id}")
    response = call_api_as(request, auth)
    assert_http_status(response, 200)
    JSON.parse(response.body)["id"].to_s.should eq(artifact_id)
  end

  it "a standalone upload is not readable by another account" do
    alice = nil
    bob = nil
    artifact_id = nil
    with_db do |db|
      doctype, _doc_id = setup_routes_doctype(db)
      alice = routes_auth(db, "alice", "alice_role", doctype)
      bob = routes_auth(db, "bob", "bob_role", doctype)
      result = Facet::Artifact::Uploader.upload(
        db, IO::Memory.new(routes_png_bytes), "upload.png", alice,
        domain: Facet::Artifact::Store::ACCOUNT_OWNER_DOMAIN,
        doc_type: Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE,
        doc_id: alice.account_id,
        field_path: Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH,
        view_tag: nil,
      )
      artifact_id = result.as(Facet::Artifact::Uploader::Result).artifact_id
    end

    request = HTTP::Request.new("GET", "/Api/core/artifacts/#{artifact_id}")
    response = call_api_as(request, bob)
    assert_http_status(response, 403)
  end

  it "GET /Api/core/artifacts/:id returns metadata + a fresh grant URL" do
    art_id = nil
    with_db do |db|
      doctype, doc_id = setup_routes_doctype(db)
      art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
    end

    request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id.as(String)}")
    response = call_api(request)
    assert_http_status(response, 200)
    json = JSON.parse(response.body)
    json["id"].to_s.should eq(art_id)
    json["mime_type"].to_s.should eq("image/png")
    json["url"].to_s.should contain("/A/")
  end

  it "GET /Api/core/artifacts/:id returns 404 for an unknown artifact" do
    request = HTTP::Request.new("GET", "/Api/core/artifacts/01UNKNOWNARTIFACT0000000")
    response = call_api(request)
    assert_http_status(response, 404)
  end

  it "POST /Api/core/artifacts/:id/grant mints an ephemeral grant" do
    art_id = nil
    with_db do |db|
      doctype, doc_id = setup_routes_doctype(db)
      art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
    end

    request = HTTP::Request.new("POST", "/Api/core/artifacts/#{art_id.as(String)}/grant")
    response = call_api(request)
    assert_http_status(response, 201)
    json = JSON.parse(response.body)
    json["grant_id"].to_s.should_not be_empty
    json["url"].to_s.should contain("/A/")
  end

  it "POST /Api/core/artifacts/:id/publish mints a permanent grant" do
    art_id = nil
    owner_id = nil
    with_db do |db|
      doctype, doc_id = setup_routes_doctype(db)
      art_id, owner_id = upload_routes_fixture(db, doctype, doc_id)
    end

    body = %({"owner_id": "#{owner_id.as(String)}"})
    request = HTTP::Request.new("POST", "/Api/core/artifacts/#{art_id.as(String)}/publish",
      headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
    response = call_api(request)
    assert_http_status(response, 201)
    json = JSON.parse(response.body)
    json["permanent"].as_bool.should be_true
  end

  it "DELETE /Api/core/artifacts/grants/:gid revokes a grant" do
    grant_id = nil
    with_db do |db|
      doctype, doc_id = setup_routes_doctype(db)
      art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
      auth = routes_auth(db, "alice", "alice_role", doctype)
      grant_id, _url = mint_url(db, auth, art_id)
    end

    request = HTTP::Request.new("DELETE", "/Api/core/artifacts/grants/#{grant_id.as(String)}")
    response = call_api(request)
    assert_http_status(response, 204)
  end

  describe "GET /A/:gid (serve route)" do
    it "streams bytes with the hardening header set" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)
        _grant_id, url = mint_url(db, auth, art_id)

        # The URL is absolute (artifact_base_url); the serve route is
        # registered on the same router, so hit the path + query directly.
        path = URI.parse(url).request_target
        request = HTTP::Request.new("GET", path)
        response = call_api(request)
        assert_http_status(response, 200)
        response.headers["X-Content-Type-Options"].should eq("nosniff")
        response.headers["Content-Security-Policy"].should contain("default-src 'none'")
        response.headers["Content-Disposition"].should contain("inline")
        response.headers["Content-Type"].should eq("image/png")
        response.body.bytesize.should eq(routes_png_bytes.size)
      end
    end

    it "serves a range request with Content-Range on 206" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)
        _grant_id, url = mint_url(db, auth, art_id)

        path = URI.parse(url).request_target
        headers = HTTP::Headers{"Range" => "bytes=0-3"}
        request = HTTP::Request.new("GET", path, headers: headers)
        response = call_api(request)
        assert_http_status(response, 206)
        response.headers["Content-Range"].should eq("bytes 0-3/#{routes_png_bytes.size}")
        response.body.bytesize.should eq(4)
      end
    end

    it "serves SVG as an attachment" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        svg = %(<svg xmlns="http://www.w3.org/2000/svg"></svg>).to_slice
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id, bytes: svg)
        auth = routes_auth(db, "alice", "alice_role", doctype)
        _grant_id, url = mint_url(db, auth, art_id)

        path = URI.parse(url).request_target
        request = HTTP::Request.new("GET", path)
        response = call_api(request)
        assert_http_status(response, 200)
        response.headers["Content-Type"].should eq("image/svg+xml")
        response.headers["Content-Disposition"].should contain("attachment")
      end
    end

    it "returns 403 for a tampered signature" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)
        _grant_id, url = mint_url(db, auth, art_id)

        uri = URI.parse(url)
        sig = uri.query_params["sig"]
        tampered = (sig[0] == 'A' ? 'B' : 'A') + sig[1..]
        # Rebuild the query string explicitly — mutating `query_params` does
        # not write back to `@query`, so `request_target` would carry the
        # original signature.
        path = "#{uri.path}?exp=#{uri.query_params["exp"]}&sig=#{tampered}"
        request = HTTP::Request.new("GET", path)
        response = call_api(request)
        assert_http_status(response, 403)
      end
    end
  end

  # ── Gateway route ───────────────────────────────────────────────────────────
  #
  # `GET /Api/core/artifacts/:id/download` is the server-side mint-and-redirect
  # gateway route (`doc/backend/artifact.md` → Download gateway). Cookie/bearer auth for
  # browser sessions; anonymous app-origin path (`?app=` + matching `Origin`)
  # for embedded assets. The serve route (`GET /A/:gid`) is unchanged.
  describe "GET /Api/core/artifacts/:id/download (gateway)" do
    # The gateway path occasionally sets `Fiber.current.auth_context = nil` to
    # simulate an anonymous app-origin request. Restore the system default so
    # the next example starts from a known state.
    before_each { truncate_routes_tables; Fiber.current.auth_context = nil }
    after_each { Fiber.current.auth_context = nil }
    # Phase A: cookie / bearer path.
    it "returns 302 with a signed serve URL for a reader" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, auth)
        assert_http_status(response, 302)
        response.headers["Location"]?.should_not be_nil
        response.headers["Location"].to_s.should contain("/A/")
        response.headers["Cache-Control"]?.should eq("no-store")
      end
    end

    it "returns 403 for a non-reader account" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        # Bob has a role with NO permissions on the doctype → `can_read?`
        # denies, non-disclosing 403.
        create_role_projection(db, "bob_role_empty", [] of JSON::Any)
        create_account_projection(db, "bob", ["bob_role_empty"])
        bob = Facet::RBAC::AuthContext.authenticated(
          "bob",
          Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "bob_role_empty"),
          ),
        )

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, bob)
        assert_http_status(response, 403)
      end
    end

    it "returns 401 when no credential is presented (AuthHandler enabled)" do
      # Enable the real AuthHandler so an unauthenticated request is rejected
      # with 401 before reaching the route body. Per spec_helper.cr's
      # `Spec.after_each`, this is reset to `false` after every example.
      Facet::HTTP::AuthHandler.enabled = true
      # No token cookie, no Authorization header.
      request = HTTP::Request.new("GET", "/Api/core/artifacts/01UNKNOWN00000000000000/download")
      response = call_api(request)
      assert_http_status(response, 401)
    end

    it "returns 403 for an unknown artifact (non-disclosing)" do
      with_db do |db|
        doctype, _doc_id = setup_routes_doctype(db)
        auth = routes_auth(db, "alice", "alice_role", doctype)

        request = HTTP::Request.new("GET", "/Api/core/artifacts/01UNKNOWNARTIFACTID0000/download")
        response = call_api_as(request, auth)
        assert_http_status(response, 403)
      end
    end

    it "follows the 302 to the serve route and streams the bytes" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)

        g_request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        g_response = call_api_as(g_request, auth)
        assert_http_status(g_response, 302)
        location = g_response.headers["Location"]

        # Hit the signed serve URL on the same router.
        path = URI.parse(location).request_target
        s_request = HTTP::Request.new("GET", path)
        s_response = call_api(s_request)
        assert_http_status(s_response, 200)
        s_response.body.bytesize.should eq(routes_png_bytes.size)
      end
    end

    # Phase B: anonymous app-origin path (`?app=` + `Origin`).
    #
    # The app's `allowed_origins` is `"https://portal.test.local"`, so each
    # request pairs `?app=APP_ID` with `Origin: https://portal.test.local`.
    # `create_test_app` from `oauth_helper.cr` runs the app.App create hook,
    # so the projection is materialised the same way production paths do it.
    it "returns 302 for an app-origin request with a matching origin" do
      art_id = nil
      app_id = nil
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        app_id, _client_id = create_test_app(
          db, "dl-app",
          allowed_origins: ["https://portal.test.local"],
          status: "active",
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        Facet::OAuth::OriginCache.reset
      end

      request = HTTP::Request.new(
        "GET",
        "/Api/core/artifacts/#{art_id}/download?app=#{app_id}",
        headers: HTTP::Headers{"Origin" => "https://portal.test.local"},
      )
      # No auth context pinned — this is an anonymous app-origin request.
      Fiber.current.auth_context = nil
      response = call_api(request)
      assert_http_status(response, 302)
      response.headers["Location"]?.should_not be_nil
      response.headers["Location"].to_s.should contain("/A/")
    end

    it "returns 403 when the origin is not registered for any app" do
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        app_id, _client_id = create_test_app(
          db, "dl-app-origin",
          allowed_origins: ["https://portal.test.local"],
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        Facet::OAuth::OriginCache.reset

        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=#{app_id}",
          headers: HTTP::Headers{"Origin" => "https://evil.example"},
        )
        Fiber.current.auth_context = nil
        response = call_api(request)
        assert_http_status(response, 403)
      end
    end

    it "returns 403 when `?app=` names a different app than owns the origin" do
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        # app_A owns the origin used in the request (so the origin is
        # mapped to app_A by `OriginCache.app_for_origin`).
        _app_a_id, _ = create_test_app(
          db, "dl-app-a",
          allowed_origins: ["https://portal.test.local"],
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        # app_B is a different app — the request will claim this app id while
        # the origin belongs to app_A, exercising the cross-app impersonation
        # guard.
        app_b_id, _ = create_test_app(
          db, "dl-app-b",
          allowed_origins: ["https://other.example"],
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        Facet::OAuth::OriginCache.reset

        # Origin belongs to app_A but the request claims app_B.
        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=#{app_b_id}",
          headers: HTTP::Headers{"Origin" => "https://portal.test.local"},
        )
        Fiber.current.auth_context = nil
        response = call_api(request)
        assert_http_status(response, 403)
      end
    end

    it "returns 403 when the app has no grant on the artifact's doctype" do
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        # App is active but its grant is on a doctype the artifact does not
        # belong to.
        app_id, _ = create_test_app(
          db, "dl-app-nogrant",
          allowed_origins: ["https://portal.test.local"],
          grants: [oauth_grant("other.Other", [oauth_action("read", required: true)])],
        )
        Facet::OAuth::OriginCache.reset

        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=#{app_id}",
          headers: HTTP::Headers{"Origin" => "https://portal.test.local"},
        )
        Fiber.current.auth_context = nil
        response = call_api(request)
        assert_http_status(response, 403)
      end
    end

    it "returns 403 for a disabled app" do
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        app_id, _ = create_test_app(
          db, "dl-app-disabled",
          allowed_origins: ["https://portal.test.local"],
          status: "disabled",
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        # `Status` defaults to the seed convention but the origin cache rebuild
        # filters to active apps only, so the origin is absent. Also, the
        # projection-row gate explicitly checks status == "active".
        Facet::OAuth::OriginCache.reset

        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=#{app_id}",
          headers: HTTP::Headers{"Origin" => "https://portal.test.local"},
        )
        Fiber.current.auth_context = nil
        response = call_api(request)
        assert_http_status(response, 403)
      end
    end

    it "falls back to cookie auth when `?app=` is present but no Origin" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        auth = routes_auth(db, "alice", "alice_role", doctype)

        # No Origin header — the `?app=` param MUST be ignored, and the
        # request flows through the cookie/bearer path.
        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=01FAKEAPPID0000000000",
        )
        response = call_api_as(request, auth)
        assert_http_status(response, 302)
        response.headers["Location"]?.should_not be_nil
        response.headers["Location"].to_s.should contain("/A/")
      end
    end

    it "returns 401 when `?app=` is present but no Origin and no cookie" do
      Facet::HTTP::AuthHandler.enabled = true
      # No Origin, no cookie, no bearer — the gateway has no credential and
      # no app attribution. `?app=` is ignored without Origin.
      request = HTTP::Request.new(
        "GET",
        "/Api/core/artifacts/01UNKNOWN00000000000000/download?app=01FAKEAPPID0000000000",
      )
      response = call_api(request)
      assert_http_status(response, 401)
    end

    it "follows the 302 from the app-origin path to the serve route" do
      with_db do |db|
        seed_app_doctypes(db)
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        app_id, _ = create_test_app(
          db, "dl-app-follow",
          allowed_origins: ["https://portal.test.local"],
          grants: [oauth_grant("#{DOMAIN_ROUTES}.#{doctype}", [oauth_action("read", required: true)])],
        )
        Facet::OAuth::OriginCache.reset

        request = HTTP::Request.new(
          "GET",
          "/Api/core/artifacts/#{art_id}/download?app=#{app_id}",
          headers: HTTP::Headers{"Origin" => "https://portal.test.local"},
        )
        Fiber.current.auth_context = nil
        g_response = call_api(request)
        assert_http_status(g_response, 302)
        location = g_response.headers["Location"]

        # Hit the serve route. The serve route takes only `?exp=…&sig=…`;
        # the bytes stream without any auth context.
        path = URI.parse(location).request_target
        s_request = HTTP::Request.new("GET", path)
        s_response = call_api(s_request)
        assert_http_status(s_response, 200)
        s_response.body.bytesize.should eq(routes_png_bytes.size)
      end
    end

    # Phase D: operator fallback (the `download *.*` action).
    it "falls back to the download *.* operator action when provenance denies" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        # The artifact's only provenance is a document the caller cannot
        # read — provenance denies; the operator action covers it.
        perms = [permission_json("download", "*.*")]
        create_role_projection(db, "operator_role", perms)
        create_account_projection(db, "operator", ["operator_role"])
        operator = Facet::RBAC::AuthContext.authenticated(
          "operator",
          Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "operator_role"),
          ),
        )

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, operator)
        assert_http_status(response, 302)
        response.headers["Location"]?.should_not be_nil
        response.headers["Location"].to_s.should contain("/A/")
      end
    end

    it "operator fallback downloads an account-scoped standalone upload owned by another account" do
      with_db do |db|
        doctype, _doc_id = setup_routes_doctype(db)
        # Standalone upload: the only owner row is Alice's `_account` row.
        alice = routes_auth(db, "alice", "alice_role", doctype)
        result = Facet::Artifact::Uploader.upload(
          db, IO::Memory.new(routes_png_bytes), "upload.png", alice,
          domain: Facet::Artifact::Store::ACCOUNT_OWNER_DOMAIN,
          doc_type: Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE,
          doc_id: alice.account_id,
          field_path: Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH,
          view_tag: nil,
        )
        art_id = result.as(Facet::Artifact::Uploader::Result).artifact_id

        perms = [permission_json("download", "*.*")]
        create_role_projection(db, "operator_role", perms)
        create_account_projection(db, "operator", ["operator_role"])
        operator = Facet::RBAC::AuthContext.authenticated(
          "operator",
          Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "operator_role"),
          ),
        )

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, operator)
        assert_http_status(response, 302)
      end
    end

    it "keeps 403 when provenance denies and the caller lacks the download action" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        create_role_projection(db, "bob_role_empty", [] of JSON::Any)
        create_account_projection(db, "bob", ["bob_role_empty"])
        bob = Facet::RBAC::AuthContext.authenticated(
          "bob",
          Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "bob_role_empty"),
          ),
        )

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, bob)
        assert_http_status(response, 403)
      end
    end

    it "answers 410 on the operator path for a tombstoned artifact" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        Facet::Artifact::Prune.soft_delete(db, art_id)

        perms = [permission_json("download", "*.*")]
        create_role_projection(db, "operator_role", perms)
        create_account_projection(db, "operator", ["operator_role"])
        operator = Facet::RBAC::AuthContext.authenticated(
          "operator",
          Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "operator_role"),
          ),
        )

        request = HTTP::Request.new("GET", "/Api/core/artifacts/#{art_id}/download")
        response = call_api_as(request, operator)
        assert_http_status(response, 410)
      end
    end
  end

  # ── Force delete (admin surface) ─────────────────────────────────────────
  #
  # `DELETE /Api/Artifacts/:id` — the operator security deletion. Gated by
  # `purge *.*` (deny-only-Denied) with the system bypass; writes the
  # `iam.ArtifactEvent` audit document transactionally; cascades every
  # child table; answers 204.
  describe "DELETE /Api/Artifacts/:id (force delete)" do
    it "purges with the purge *.* action, CSRF header, and a reason; answers 204" do
      with_db do |db|
        # The purge writes an `iam.ArtifactEvent` document through the real
        # mutation pipeline — the doctype definitions must exist after the
        # per-example TRUNCATE.
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        db.exec(
          "INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field) VALUES ($1, $2, $3, 'file')",
          art_id, DOMAIN_ROUTES, doc_id,
        )
        operator = routes_operator_context(db, true)

        request = HTTP::Request.new(
          "DELETE",
          "/Api/Artifacts/#{art_id}",
          headers: HTTP::Headers{
            "Content-Type"     => "application/json",
            "X-Requested-With" => "XMLHttpRequest",
          },
          body: %({"reason": "security incident 4711"}),
        )
        response = call_api_as(request, operator)
        assert_http_status(response, 204)

        # The row and its children are gone; the audit event is written.
        Facet::Artifact::Store.find_artifact(db, art_id).should be_nil
        db.query_one("SELECT COUNT(*) FROM artifact_references WHERE artifact_id = $1", art_id, as: Int64).should eq(0)
        event = db.query_one(
          "SELECT content, actioner_id FROM projections JOIN mutations ON mutations.id = projections.state WHERE projections.domain = 'iam' AND projections.doc_type = 'ArtifactEvent' AND projections.content->>'artifact_id' = $1",
          art_id,
          as: {JSON::Any, String},
        )
        event[0]["event"].to_s.should eq("purged")
        event[0]["filename"].to_s.should eq("asset.png")
        event[0]["details"].to_s.should eq("security incident 4711")
        event[1].should eq("purge_admin")
      end
    end

    it "answers 403 without the purge action and leaves the artifact alive" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        operator = routes_operator_context(db, false)

        request = HTTP::Request.new(
          "DELETE",
          "/Api/Artifacts/#{art_id}",
          headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"},
        )
        response = call_api_as(request, operator)
        assert_http_status(response, 403)
        Facet::Artifact::Store.find_artifact(db, art_id).should_not be_nil
      end
    end

    it "answers 404 for an unknown artifact" do
      with_db do |db|
        operator = routes_operator_context(db, true)

        request = HTTP::Request.new(
          "DELETE",
          "/Api/Artifacts/01UNKNOWNARTIFACT0000000",
          headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"},
        )
        response = call_api_as(request, operator)
        assert_http_status(response, 404)
      end
    end

    it "rejects a cookie-authenticated request without the CSRF header" do
      with_db do |db|
        doctype, doc_id = setup_routes_doctype(db)
        art_id, _owner_id = upload_routes_fixture(db, doctype, doc_id)
        operator = routes_operator_context(db, true)

        request = HTTP::Request.new("DELETE", "/Api/Artifacts/#{art_id}")
        response = call_api_raw_as(request, operator)
        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].to_s.should contain("X-Requested-With")
        Facet::Artifact::Store.find_artifact(db, art_id).should_not be_nil
      end
    end
  end
end
