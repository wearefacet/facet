# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/agent_tools"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/upload_grants"
require "../../src/artifact/routes"
require "../../src/rbac"
require "../../src/http/server"
require "../support/doctype_helper"
require "../support/agent_tools_helper"
require "../support/http_helper"
require "json"

# Artifact tool group (`AgentTools::Artifacts`).
#
# Specs walk every documented rule:
#   1. `request_artifact_upload` mints a single-use URL bound to the
#      calling principal; the URL round-trips through `UploadGrants.consume`.
#   2. `size_bytes` over the server cap fails before any bytes move.
#   3. Argument validation: missing `filename`, unknown argument keys.
#   4. Visibility: the upload tool requires a write grant, `get_artifact`
#      a read grant.
#   5. `get_artifact` mints a signed download URL for a readable artifact
#      (the URL streams the bytes), and raises NotFound / RbacDenied on the
#      non-disclosing paths.
#   6. `list_artifact_refs` lists the live documents that reference one
#      artifact (file-field and longtext placements), skips referrers the
#      caller cannot read, and answers one non-disclosing NotFound for an
#      unknown, deleted, or denied artifact.

HTTPTest.init

PNG_BYTES = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")

def build_artifact_file_doctype(db, domain : String) : {String, String}
  ensure_domain(db, domain)
  doctype = "T#{unique_suffix}"
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
            "fields": {"file": {"type": "file"}}})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
  {domain, doctype}
end

# Uploads the fixture bytes against a live document (system auth) and
# returns the artifact id.
def upload_artifact_fixture(db, domain, doctype, doc_id) : String
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(PNG_BYTES), "asset.png",
    Facet::RBAC::AuthContext.system,
    domain, doctype, doc_id, "file", nil,
  )
  result.as(Facet::Artifact::Uploader::Result).artifact_id
end

# Uploads arbitrary bytes — distinct bytes dodge the sha256 dedup, so two
# calls return two artifact ids.
private def upload_bytes_fixture(db, domain, doctype, doc_id, bytes : Bytes, filename : String) : String
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(bytes), filename,
    Facet::RBAC::AuthContext.system,
    domain, doctype, doc_id, "file", nil,
  )
  result.as(Facet::Artifact::Uploader::Result).artifact_id
end

# Doctype with one `file` field and one `longtext` field — the two placements
# `list_artifact_refs` reports.
private def build_refs_doctype(db, domain : String) : {String, String}
  ensure_domain(db, domain)
  doctype = "R#{unique_suffix}"
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}",
            "fields": {"file": {"type": "file"}, "body": {"type": "longtext"}}})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
  {domain, doctype}
end

describe "AgentTools::Artifacts" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  describe "request_artifact_upload" do
    it "mints a single-use URL bound to the calling principal" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.editor")
        result = call_tool(ctx, "request_artifact_upload", %({"filename": "report.pdf", "size_bytes": 1024}))

        data = result.as_h["data"].as_h
        data["upload_url"].as_s.should start_with(Facet::Config.instance.artifact_base_url + "/A/upload/")
        data["method"].as_s.should eq("POST")
        data["field"].as_s.should eq("file")
        data["filename"].as_s.should eq("report.pdf")

        meta = result.as_h["meta"].as_h
        meta["max_bytes"].as_i64.should eq(Facet::Config.instance.artifact.max_upload_bytes)
        meta["expires_at"].as_s.should_not be_empty

        # The URL round-trips through consume and carries the minting
        # principal.
        uri = URI.parse(data["upload_url"].as_s)
        cap = Facet::Artifact::UploadGrants.consume(
          uri.path.sub("/A/upload/", ""), uri.query_params["exp"]?, uri.query_params["sig"]?,
        ).as(Facet::Artifact::UploadGrants::Capability)
        cap.account_id.should eq(ctx.account_id)
        cap.role_id.should eq("iam.Roles.editor")
      end
    end

    it "rejects a size_bytes over the server cap before any bytes move" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.editor")
        max = Facet::Config.instance.artifact.max_upload_bytes
        ex = expect_raises(Facet::AgentTools::InvalidParams, /server cap/) do
          call_tool(ctx, "request_artifact_upload", %({"filename": "big.bin", "size_bytes": #{max + 1}}))
        end
        (ex.message || "").should contain("size_bytes")
      end
    end

    it "rejects a missing filename" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.editor")
        expect_raises(Facet::AgentTools::InvalidParams, /filename/) do
          call_tool(ctx, "request_artifact_upload", %({}))
        end
      end
    end

    it "rejects unknown argument keys" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.editor")
        expect_raises(Facet::AgentTools::InvalidParams, /Unknown argument/) do
          call_tool(ctx, "request_artifact_upload", %({"filename": "a.png", "content_base64": "AAAA"}))
        end
      end
    end
  end

  describe "visibility" do
    it "shows request_artifact_upload only to a role holding a write grant" do
      with_db do |db|
        writer = build_context_with_permissions(db, [{"action" => "create", "on" => "*.*"}])
        reader = build_context_with_permissions(db, [{"action" => "read", "on" => "*.*"}])

        writer_tools = Facet::AgentTools.list_for(writer).map(&.name)
        writer_tools.should contain("request_artifact_upload")
        writer_tools.should_not contain("get_artifact")

        reader_tools = Facet::AgentTools.list_for(reader).map(&.name)
        reader_tools.should contain("get_artifact")
        reader_tools.should_not contain("request_artifact_upload")
      end
    end
  end

  describe "get_artifact" do
    it "mints a signed download URL whose bytes stream" do
      artifact_id = nil
      auth = nil
      with_db do |db|
        domain, doctype = build_artifact_file_doctype(db, "mcparts")
        doc_id = create_doc_via_service(db, domain, doctype, %({}))
        artifact_id = upload_artifact_fixture(db, domain, doctype, doc_id)
        auth = build_context_with_permissions(db, [{"action" => "read", "on" => "#{domain}.#{doctype}"}])
      end

      result = call_tool(auth.not_nil!, "get_artifact", %({"artifact_id": "#{artifact_id.as(String)}"}))
      data = result.as_h["data"].as_h
      data["id"].as_s.should eq(artifact_id)
      data["filename"].as_s.should eq("asset.png")
      data["mime_type"].as_s.should eq("image/png")
      data["download_url"].as_s.should start_with(Facet::Config.instance.artifact_base_url + "/A/")
      result.as_h["meta"].as_h["expires_at"].as_s.should_not be_empty

      # The URL streams the bytes (same router, path + query direct).
      path = URI.parse(data["download_url"].as_s).request_target
      response = call_api(HTTP::Request.new("GET", path))
      assert_http_status(response, 200)
      response.body.bytesize.should eq(PNG_BYTES.size)
    end

    it "raises NotFound for an unknown artifact id" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.viewer")
        expect_raises(Facet::AgentTools::NotFound) do
          call_tool(ctx, "get_artifact", %({"artifact_id": "01UNKNOWNARTIFACT0000000"}))
        end
      end
    end

    it "raises RbacDenied for an artifact outside the role's scope" do
      artifact_id = nil
      with_db do |db|
        domain, doctype = build_artifact_file_doctype(db, "mcparts")
        doc_id = create_doc_via_service(db, domain, doctype, %({}))
        artifact_id = upload_artifact_fixture(db, domain, doctype, doc_id)
      end

      with_db do |db|
        # A role whose read grant covers only a different domain.
        other = build_context_with_permissions(db, [{"action" => "read", "on" => "otherdomain.*"}])
        expect_raises(Facet::AgentTools::RbacDenied) do
          call_tool(other, "get_artifact", %({"artifact_id": "#{artifact_id.as(String)}"}))
        end
      end
    end
  end

  describe "list_artifact_refs" do
    it "lists file-field and longtext references with their placement" do
      with_db do |db|
        domain, doctype = build_refs_doctype(db, "mcrefs")
        anchor = create_doc_via_service(db, domain, doctype, %({}))
        art_file = upload_artifact_fixture(db, domain, doctype, anchor)
        art_link = upload_bytes_fixture(db, domain, doctype, anchor, Bytes[1, 2, 3], "note.bin")
        doc_b = create_doc_via_service(db, domain, doctype,
          %({"file": "#{art_file}", "body": "see [x](urn:facet:artifact:#{art_link})"}))

        ctx = build_context(db, "iam.Roles.viewer")
        result = call_tool(ctx, "list_artifact_refs", %({"artifact_id": "#{art_file}"}))
        data = result.as_h["data"].as_a
        data.size.should eq(1)
        row = data.first.as_h
        row["id"].as_s.should eq(doc_b)
        row["domain"].as_s.should eq(domain)
        row["doc_type"].as_s.should eq(doctype)
        row["field"].as_s.should eq("file")
        row["display_name"].as_s?.should be_nil
        row["last_reference_at"].as_s.should_not be_empty

        meta = result.as_h["meta"].as_h
        meta["artifact"].as_s.should eq(art_file)
        meta["total"].as_i64.should eq(1)
        meta["capped"].as_bool.should be_false

        # The longtext placement — same document, different field.
        result2 = call_tool(ctx, "list_artifact_refs", %({"artifact_id": "#{art_link}"}))
        rows2 = result2.as_h["data"].as_a
        rows2.size.should eq(1)
        rows2.first.as_h["id"].as_s.should eq(doc_b)
        rows2.first.as_h["field"].as_s.should eq("body")
      end
    end

    it "skips referrers the caller cannot read" do
      with_db do |db|
        d1, t1 = build_refs_doctype(db, "refsdom1")
        d2, t2 = build_refs_doctype(db, "refsdom2")
        anchor1 = create_doc_via_service(db, d1, t1, %({}))
        create_doc_via_service(db, d2, t2, %({}))
        art = upload_artifact_fixture(db, d1, t1, anchor1)
        doc1 = create_doc_via_service(db, d1, t1, %({"file": "#{art}"}))
        create_doc_via_service(db, d2, t2, %({"file": "#{art}"}))

        # A role whose read grant covers only the first domain — concrete
        # doctype paths (the wildcard-doctype form is reserved for the
        # all-domain `*.*` line).
        ctx = Facet::RBAC::AuthContext.authenticated(
          create_test_account(db),
          Facet::RBAC::ActiveRole.new(
            role_id: "mcrefs.reader",
            visible_tags: Set.new(["*"]),
            permissions: [
              Facet::RBAC::Permission.new(action: "read", domain: d1, path: [t1]),
            ],
          ),
        )
        result = call_tool(ctx, "list_artifact_refs", %({"artifact_id": "#{art}"}))
        data = result.as_h["data"].as_a
        data.size.should eq(1)
        data.first.as_h["id"].as_s.should eq(doc1)
      end
    end

    it "excludes a tombstoned referrer" do
      with_db do |db|
        domain, doctype = build_refs_doctype(db, "mcrefs")
        anchor = create_doc_via_service(db, domain, doctype, %({}))
        art = upload_artifact_fixture(db, domain, doctype, anchor)
        doc_b = create_doc_via_service(db, domain, doctype, %({"file": "#{art}"}))
        db.exec("UPDATE projections SET deleted_at = now() WHERE domain = $1 AND id = $2", domain, doc_b)

        ctx = build_context(db, "iam.Roles.viewer")
        result = call_tool(ctx, "list_artifact_refs", %({"artifact_id": "#{art}"}))
        result.as_h["data"].as_a.size.should eq(0)
        result.as_h["meta"].as_h["total"].as_i64.should eq(0)
      end
    end

    it "raises NotFound for an unknown artifact id" do
      with_db do |db|
        ctx = build_context(db, "iam.Roles.viewer")
        expect_raises(Facet::AgentTools::NotFound) do
          call_tool(ctx, "list_artifact_refs", %({"artifact_id": "01UNKNOWNARTIFACT0000000"}))
        end
      end
    end

    it "raises NotFound for a denied artifact (non-disclosing, unlike get_artifact)" do
      with_db do |db|
        domain, doctype = build_refs_doctype(db, "mcrefs")
        anchor = create_doc_via_service(db, domain, doctype, %({}))
        art = upload_artifact_fixture(db, domain, doctype, anchor)

        # A role whose read grant covers only a different domain. The
        # listing follows the get_backrefs target-gate shape: denial is
        # indistinguishable from absence.
        other = Facet::RBAC::AuthContext.authenticated(
          create_test_account(db),
          Facet::RBAC::ActiveRole.new(
            role_id: "mcrefs.other",
            visible_tags: Set.new(["*"]),
            permissions: [
              Facet::RBAC::Permission.new(action: "read", domain: "otherdomain", path: ["*"]),
            ],
          ),
        )
        expect_raises(Facet::AgentTools::NotFound) do
          call_tool(other, "list_artifact_refs", %({"artifact_id": "#{art}"}))
        end
      end
    end

    it "is visible to a role holding a read grant, hidden from write-only" do
      with_db do |db|
        reader = build_context_with_permissions(db, [{"action" => "read", "on" => "*.*"}])
        writer = build_context_with_permissions(db, [{"action" => "create", "on" => "*.*"}])

        Facet::AgentTools.list_for(reader).map(&.name).should contain("list_artifact_refs")
        Facet::AgentTools.list_for(writer).map(&.name).should_not contain("list_artifact_refs")
      end
    end
  end
end
