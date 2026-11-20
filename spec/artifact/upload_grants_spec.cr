# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/upload_grants"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/routes"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/http/server"
require "../support/http_helper"
require "openssl/hmac"
require "json"
require "base64"

# Signed upload capabilities (`Artifact::UploadGrants`) and the
# `POST /A/upload/:uid` route.
#
# Specs walk every documented rule:
#   1. mint → consume round-trip carries the minting principal (account +
#      role) and the URL points at the artifact origin.
#   2. single-use — a second consume answers `already_used`.
#   3. a tampered signature answers `invalid_signature` without burning the
#      capability (the valid consume still succeeds afterwards).
#   4. an expired `exp` answers `expired` without burning.
#   5. consume-time revalidation — a deleted account or a dropped role
#      fails the rebuild (`build_auth_context` returns nil → route maps to
#      `stale`).
#   6. HTTP flow — the multipart POST lands through the standard uploader
#      under the `_account` owner convention; the artifact is readable by
#      the minting account; the URL refuses a non-multipart body without
#      burning the capability.
#
# The Redis-backed store is cleaned through `redis_cleanup` (the
# `artifact_upload:` prefix is part of its sweep list).

HTTPTest.init

# Replicates the capability HMAC so a spec can craft URLs with arbitrary
# `exp` values (the expiry and tamper cases). Pins the signature format:
# base64url(HMAC-SHA256(secret, "uid|exp")), no padding.
def upload_cap_sig(uid : String, exp : String) : String
  secret = Facet::Config.instance.artifact_grant_secret
  Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, secret, "#{uid}|#{exp}"), padding: false)
end

def upload_cap_auth(db, account_id = "cap_alice", role_name = "cap_role")
  # The canonical role shape: the projection id is the qualified
  # `iam.Roles.<name>`, the content `name` is the bare role name (the
  # same shape `seed_test_roles` and `build_context_with_permissions` use).
  role_id = "iam.Roles.#{role_name}"
  content = JSON::Any.new({
    "name"         => JSON::Any.new(role_name),
    "level"        => JSON::Any.new(20_i64),
    "permissions"  => JSON::Any.new([permission_json("read", "*.*"), permission_json("create", "*.*")]),
    "visible_tags" => JSON::Any.new(["*"].map { |t| JSON::Any.new(t) }),
  })
  Facet::Mutation::Client.create(db, "iam", "Roles", doc_id: role_id,
    content: content.to_json, actioner_id: "system")
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Roles", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def upload_cap_png : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")
end

def multipart_file_body : String
  bytes = upload_cap_png
  String.build do |io|
    io << "--facet\r\n"
    io << "Content-Disposition: form-data; name=\"file\"; filename=\"cap.png\"\r\n"
    io << "Content-Type: application/octet-stream\r\n\r\n"
    io.write(bytes)
    io << "\r\n--facet--\r\n"
  end
end

def post_upload(url : String, content_type : String? = "multipart/form-data; boundary=facet", authorization : String? = nil) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["Content-Type"] = content_type if content_type
  headers["Authorization"] = authorization if authorization
  request = HTTP::Request.new("POST", URI.parse(url).request_target, headers: headers, body: multipart_file_body)
  call_api(request)
end

describe "Artifact::UploadGrants" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  it "mints a capability bound to the minting principal" do
    with_db do |db|
      auth = upload_cap_auth(db)

      minted = Facet::Artifact::UploadGrants.mint(auth)
      minted.url.should start_with(Facet::Config.instance.artifact_base_url + "/A/upload/")
      (minted.expires_at - Time.utc).total_seconds.should be_close(300, 5)

      uri = URI.parse(minted.url)
      uid = uri.path.sub("/A/upload/", "")
      consumed = Facet::Artifact::UploadGrants.consume(uid, uri.query_params["exp"]?, uri.query_params["sig"]?)
      cap = consumed.as(Facet::Artifact::UploadGrants::Capability)
      cap.account_id.should eq(auth.account_id)
      cap.role_id.should eq("iam.Roles.cap_role")
    end
  end

  it "consumes once — a second consume answers already_used" do
    with_db do |db|
      auth = upload_cap_auth(db)
      minted = Facet::Artifact::UploadGrants.mint(auth)
      uri = URI.parse(minted.url)
      uid = uri.path.sub("/A/upload/", "")
      exp = uri.query_params["exp"]?
      sig = uri.query_params["sig"]?

      Facet::Artifact::UploadGrants.consume(uid, exp, sig)
        .should be_a(Facet::Artifact::UploadGrants::Capability)

      second = Facet::Artifact::UploadGrants.consume(uid, exp, sig)
      second.should eq(Facet::Artifact::UploadGrants::Failure::AlreadyUsed)
    end
  end

  it "rejects a tampered signature without burning the capability" do
    with_db do |db|
      auth = upload_cap_auth(db)
      minted = Facet::Artifact::UploadGrants.mint(auth)
      uri = URI.parse(minted.url)
      uid = uri.path.sub("/A/upload/", "")
      exp = uri.query_params["exp"]?
      sig = uri.query_params["sig"]?

      tampered = sig.to_s + "x"
      Facet::Artifact::UploadGrants.consume(uid, exp, tampered)
        .should eq(Facet::Artifact::UploadGrants::Failure::InvalidSignature)

      # The failed attempt must not have consumed the record.
      Facet::Artifact::UploadGrants.consume(uid, exp, sig)
        .should be_a(Facet::Artifact::UploadGrants::Capability)
    end
  end

  it "rejects an expired URL without burning the capability" do
    with_db do |db|
      auth = upload_cap_auth(db)
      minted = Facet::Artifact::UploadGrants.mint(auth)
      uid = URI.parse(minted.url).path.sub("/A/upload/", "")

      past = (Time.utc - 60.seconds).to_unix.to_s
      Facet::Artifact::UploadGrants.consume(uid, past, upload_cap_sig(uid, past))
        .should eq(Facet::Artifact::UploadGrants::Failure::Expired)

      # The real capability is untouched.
      uri = URI.parse(minted.url)
      Facet::Artifact::UploadGrants.consume(uid, uri.query_params["exp"]?, uri.query_params["sig"]?)
        .should be_a(Facet::Artifact::UploadGrants::Capability)
    end
  end

  it "maps failure reasons to agent-readable strings" do
    Facet::Artifact::UploadGrants.failure_reason(Facet::Artifact::UploadGrants::Failure::Expired)
      .should eq("expired")
    Facet::Artifact::UploadGrants.failure_reason(Facet::Artifact::UploadGrants::Failure::AlreadyUsed)
      .should eq("already_used")
  end

  describe "revalidation (build_auth_context)" do
    it "rebuilds the context for an active account holding the role" do
      with_db do |db|
        auth = upload_cap_auth(db)
        minted = Facet::Artifact::UploadGrants.mint(auth)
        uri = URI.parse(minted.url)
        cap = Facet::Artifact::UploadGrants.consume(
          uri.path.sub("/A/upload/", ""), uri.query_params["exp"]?, uri.query_params["sig"]?,
        ).as(Facet::Artifact::UploadGrants::Capability)

        rebuilt = Facet::Artifact::UploadGrants.build_auth_context(db, cap)
        rebuilt.should_not be_nil
        rebuilt.not_nil!.account_id.should eq(auth.account_id)
      end
    end

    it "refuses a deleted account" do
      with_db do |db|
        auth = upload_cap_auth(db)
        minted = Facet::Artifact::UploadGrants.mint(auth)
        uri = URI.parse(minted.url)
        cap = Facet::Artifact::UploadGrants.consume(
          uri.path.sub("/A/upload/", ""), uri.query_params["exp"]?, uri.query_params["sig"]?,
        ).as(Facet::Artifact::UploadGrants::Capability)

        db.exec("DELETE FROM projections WHERE id = $1", auth.account_id)
        Facet::Artifact::UploadGrants.build_auth_context(db, cap).should be_nil
      end
    end

    it "refuses an account that no longer holds the role" do
      with_db do |db|
        auth = upload_cap_auth(db)
        minted = Facet::Artifact::UploadGrants.mint(auth)
        uri = URI.parse(minted.url)
        cap = Facet::Artifact::UploadGrants.consume(
          uri.path.sub("/A/upload/", ""), uri.query_params["exp"]?, uri.query_params["sig"]?,
        ).as(Facet::Artifact::UploadGrants::Capability)

        db.exec("UPDATE projections SET content = jsonb_set(content, '{roles}', '[]') WHERE id = $1", auth.account_id)
        Facet::Artifact::UploadGrants.build_auth_context(db, cap).should be_nil
      end
    end
  end
end

describe "POST /A/upload/:uid (upload capability route)" do
  before_each do
    redis_cleanup
    # The global per-example TRUNCATE covers mutations/projections; the
    # artifact tables are not in it — clear them so cross-test dedup
    # cannot reuse another test's artifact (the owner-count assertion
    # must see exactly the one row this test created).
    with_db &.exec("TRUNCATE artifacts, artifact_owners, artifact_grants, artifact_references RESTART IDENTITY CASCADE")
  end
  after_each { redis_cleanup }

  it "uploads through the capability and binds the _account owner row" do
    auth = nil
    with_db do |db|
      auth = upload_cap_auth(db)
    end

    minted = Facet::Artifact::UploadGrants.mint(auth.not_nil!)
    response = post_upload(minted.url)
    assert_http_status(response, 201)

    json = JSON.parse(response.body)
    artifact_id = json["id"].to_s
    json["filename"].to_s.should eq("cap.png")
    json["mime_type"].to_s.should eq("image/png")

    with_db do |db|
      owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
      owners.size.should eq(1)
      owner = owners.first
      owner.domain.should eq(Facet::Artifact::Store::ACCOUNT_OWNER_DOMAIN)
      owner.doc_type.should eq(Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE)
      owner.field_path.should eq(Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH)
      owner.doc_id.should eq(auth.not_nil!.account_id)

      # The uploader can read their own upload — the `_account` owner-row
      # short-circuit.
      Facet::Artifact::Access.can_read?(db, auth.not_nil!, artifact_id).should be_true
    end
  end

  it "ignores a presented bearer token — the URL signature is the credential" do
    # An MCP caller naturally attaches its bearer to every request. The
    # token is aud-bearing (or otherwise unacceptable to REST), so the
    # presented-token 401 must not fire here: the capability route skips
    # auth processing, and the signature alone authorizes the upload.
    auth = nil
    with_db do |db|
      auth = upload_cap_auth(db)
    end

    minted = Facet::Artifact::UploadGrants.mint(auth.not_nil!)
    response = post_upload(minted.url, authorization: "Bearer not-a-real-token")
    assert_http_status(response, 201)
    JSON.parse(response.body)["filename"].to_s.should eq("cap.png")
  end

  it "refuses a second POST of the same URL (single-use)" do
    auth = nil
    with_db do |db|
      auth = upload_cap_auth(db)
    end

    minted = Facet::Artifact::UploadGrants.mint(auth.not_nil!)
    post_upload(minted.url)
    second = post_upload(minted.url)
    assert_http_status(second, 403)
    JSON.parse(second.body)["reason"].to_s.should eq("already_used")
  end

  it "refuses a non-multipart body without burning the capability" do
    auth = nil
    with_db do |db|
      auth = upload_cap_auth(db)
    end

    minted = Facet::Artifact::UploadGrants.mint(auth.not_nil!)
    early = post_upload(minted.url, content_type: "application/json")
    assert_http_status(early, 415)

    # The capability survived the 415 — the fixed request succeeds.
    retry_response = post_upload(minted.url)
    assert_http_status(retry_response, 201)
  end

  it "answers 403 with a reason for a tampered URL" do
    minted = nil
    with_db do |db|
      minted = Facet::Artifact::UploadGrants.mint(upload_cap_auth(db))
    end
    uri = URI.parse(minted.not_nil!.url)
    path = "#{uri.path}?exp=#{uri.query_params["exp"]}&sig=#{uri.query_params["sig"]}x"
    response = post_upload("https://local#{path}")
    assert_http_status(response, 403)
    JSON.parse(response.body)["reason"].to_s.should eq("invalid_signature")
  end

  it "answers 403 stale when the minting account is gone" do
    auth = nil
    minted = nil
    with_db do |db|
      auth = upload_cap_auth(db)
      minted = Facet::Artifact::UploadGrants.mint(auth)
      db.exec("DELETE FROM projections WHERE id = $1", auth.account_id)
    end

    response = post_upload(minted.not_nil!.url)
    assert_http_status(response, 403)
    JSON.parse(response.body)["reason"].to_s.should eq("stale")
  end
end
