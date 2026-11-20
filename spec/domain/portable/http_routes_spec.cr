# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

require "../../../src/jobs"
require "../../../src/http/server"
require "../../../src/domain/portable"
require "../../support/http_helper"

# Specs for the portable-domain HTTP routes: enqueue, status, download.
#
# The export/import *services* are covered by `import_export_spec.cr`; here
# the concern is the HTTP contract — the gates (read for export, write for
# import), the synchronous validations, the requester-scoped status and
# download routes, and the job rows the routes stage.
#
# Tests run with `AuthHandler` disabled: `call_api` answers as system, and
# `call_api_as` pins a specific `AuthContext` for the RBAC paths.

private def portable_http_reseed_core(db) : Nil
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# A small live domain with one doctype — enough for a real export bundle.
private def portable_http_seed_domain(db, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "http test #{name}", "color": "teal"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: %({
      "doctype": "Widget",
      "domain": "#{name}",
      "schema_version": 1,
      "search": "{{ name }}",
      "fields": {"name": {"type": "string"}}
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )
end

private def portable_http_draft_domain(db, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"draft": true}),
    actioner_id: "system:test",
  )
end

# Exports the domain and zips it — the natural way to produce a valid
# bundle for the import route.
private def portable_http_bundle_zip(db, name : String, with_documents : Bool = false) : Bytes
  result = Facet::Domain::Portable::Export.call(db, name, with_documents: with_documents)
  result.should be_a(Facet::Domain::Portable::Export::Result)
  bundle = result.as(Facet::Domain::Portable::Export::Result).bundle
  path = File.tempname("spec-bundle", ".zip")
  Facet::Domain::Portable::Archive.write(bundle, path)
  bytes = File.read(path).to_slice
  File.delete?(path)
  bytes
end

private def post_domain_export(domain : String, query : String = "", csrf : Bool = true) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  suffix = query.empty? ? "" : "?#{query}"
  request = HTTP::Request.new("POST", "/Api/core/Domain/#{domain}/export#{suffix}", headers)
  # Raw dispatch: the csrf flag owns the header's presence, so the harness
  # default must not re-add it.
  call_api_raw(request)
end

private def post_domain_import(bytes : Bytes, query : String = "", csrf : Bool = true) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/zip"}
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  suffix = query.empty? ? "" : "?#{query}"
  request = HTTP::Request.new("POST", "/Api/core/Domain/import#{suffix}", headers, body: bytes)
  # Raw dispatch: the csrf flag owns the header's presence, so the harness
  # default must not re-add it.
  call_api_raw(request)
end

private def get_domain_status(job_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/core/Domain/import_export/#{job_id}"))
end

private def get_domain_download(job_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/core/Domain/import_export/#{job_id}/download"))
end

private def body_json(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

# One `domain_export` job in pending state, exactly as the enqueue route
# stages it.
private def seed_pending_domain_export(db, domain : String, account_id : String) : String
  payload = {
    "domain"     => JSON::Any.new(domain),
    "account_id" => JSON::Any.new(account_id),
  } of String => JSON::Any
  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Domain::Portable::ExportJob::KIND, JSON.parse(payload.to_json),
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# Claims one row and records the outcome the way the worker does — the
# synchronous counterpart of the wait-mode worker path.
private def run_claimed_domain_job(db, job_id : String) : Nil
  claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
  job = claimed.find! { |j| j.id == job_id }
  case job.kind
  when Facet::Domain::Portable::ExportJob::KIND
    result = Facet::Domain::Portable::ExportJob.new.execute(job)
  else
    result = Facet::Domain::Portable::ImportJob.new.execute(job)
  end
  case result.status
  in .succeeded?
    Facet::Jobs::Queries.write_succeeded(db, job.id, result: result.result)
  in .failed?
    Facet::Jobs::Queries.write_failed(db, job.id, error: result.error, result: result.result, backoff_seconds: job.backoff)
  end
end

private def install_portable_enqueue_only_manager : Facet::Jobs::Manager
  mgr = Facet::Jobs::Manager.new(handlers: {
    Facet::Domain::Portable::ExportJob::KIND => Facet::Domain::Portable::ExportJob,
    Facet::Domain::Portable::ImportJob::KIND => Facet::Domain::Portable::ImportJob,
  } of String => Facet::Jobs::Handler.class)
  Facet::Jobs::Manager.instance = mgr
  mgr
end

private def with_domain_worker(& : Facet::Jobs::Worker -> Nil) : Nil
  worker = Facet::Jobs::Worker.new(
    poll_interval_s: 0.01,
    handlers: {
      Facet::Domain::Portable::ExportJob::KIND => Facet::Domain::Portable::ExportJob,
      Facet::Domain::Portable::ImportJob::KIND => Facet::Domain::Portable::ImportJob,
    } of String => Facet::Jobs::Handler.class,
  )
  worker.start
  begin
    yield worker
  ensure
    worker.stop
  end
end

private def reader_auth(account_id : String = "iam.Account.reader") : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(account_id, rbac_role([rbac_perm("read", "core.Domain")], "domain_reader"))
end

private def writer_auth(account_id : String = "iam.Account.writer") : Facet::RBAC::AuthContext
  perms = [
    rbac_perm("read", "core.Domain"),
    rbac_perm("create", "core.Domain"),
    rbac_perm("update", "core.Domain"),
  ]
  Facet::RBAC::AuthContext.authenticated(account_id, rbac_role(perms, "domain_writer"))
end

private def viewer_auth(account_id : String = "iam.Account.viewer") : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(account_id, rbac_role([] of Facet::RBAC::Permission, "domain_nobody"))
end

describe Facet::Domain::Portable::Routes do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    HTTPTest.init

    Facet::Jobs::Manager.reset!
    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))
  end

  describe "export enqueue" do
    it "answers 202 with job_id and status_url and stages a pending job" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipexp")

        response = post_domain_export("zipexp")
        response.status_code.should eq(202)
        body = body_json(response)
        job_id = body["job_id"].as_s
        body["status_url"].as_s.should eq("/Api/core/Domain/import_export/#{job_id}")

        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        row.kind.should eq("domain_export")
        row.payload["domain"].as_s.should eq("zipexp")
        row.payload["account_id"].as_s.should eq("system")
        row.max_attempts.should eq(1)
        status, lease = db.query_one(
          "SELECT status, lease_ttl_s FROM background_jobs WHERE id = $1", job_id,
          as: {String, Int32?},
        )
        status.should eq("pending")
        lease.should eq(3600)
      end
    end

    it "answers 404 for an unknown domain" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)

        request = HTTP::Request.new("POST", "/Api/core/Domain/zipmissing/export",
          headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"})
        response = call_api_as(request, reader_auth)
        response.status_code.should eq(404)
        body_json(response)["error"].as_s.should eq("Not found")
      end
    end

    it "answers 404 (non-disclosing) when the caller lacks read on core.Domain" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipden")

        request = HTTP::Request.new("POST", "/Api/core/Domain/zipden/export",
          headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"})
        response = call_api_as(request, viewer_auth)
        response.status_code.should eq(404)
      end
    end

    it "answers 422 for a draft domain" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_draft_domain(db, "zipdraft")

        response = post_domain_export("zipdraft")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("draft")
      end
    end

    it "answers 403 without the CSRF header" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipcsrf")

        response = post_domain_export("zipcsrf", csrf: false)
        response.status_code.should eq(403)
      end
    end
  end

  describe "import enqueue" do
    it "answers 202, stages an ownerless artifact, and carries the payload" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipsrc")
        bytes = portable_http_bundle_zip(db, "zipsrc")

        response = post_domain_import(bytes, "into=ziptgt")
        response.status_code.should eq(202)
        body = body_json(response)
        job_id = body["job_id"].as_s
        body["target_domain"].as_s.should eq("ziptgt")
        body["status_url"].as_s.should eq("/Api/core/Domain/import_export/#{job_id}")

        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        row.kind.should eq("domain_import")
        row.payload["into"].as_s.should eq("ziptgt")
        row.payload["merge"].as_bool.should be_false

        artifact_id = row.payload["bundle_artifact_id"].as_s
        artifact = Facet::Artifact::Store.find_artifact(db, artifact_id).not_nil!
        artifact.mime_type.should eq("application/zip")
        # Ownerless: no artifact_owners row.
        owners = db.query_one(
          "SELECT count(*) FROM artifact_owners WHERE artifact_id = $1", artifact_id, as: Int64)
        owners.should eq(0)
      end
    end

    it "answers 422 for a body that is not an archive" do
      install_portable_enqueue_only_manager
      response = post_domain_import("plain text".to_slice)
      response.status_code.should eq(422)
      body_json(response)["error"].as_s.should contain("zip or tar.gz")
    end

    it "answers 422 for a structurally broken zip" do
      install_portable_enqueue_only_manager
      response = post_domain_import(Bytes[0x50, 0x4b, 0x03, 0x04, 0x00, 0x00])
      response.status_code.should eq(422)
      body_json(response)["error"].as_s.should contain("Unreadable bundle")
    end

    it "answers 413 once the body passes the upload cap" do
      install_portable_enqueue_only_manager
      cap = Facet::Config.instance.artifact.max_upload_bytes
      # One byte past the cap: the spool drains the remainder and answers 413.
      oversized = Bytes.new(cap.to_i + 1, 0x61_u8)
      response = post_domain_import(oversized)
      response.status_code.should eq(413)
      body_json(response)["error"].as_s.should contain("maximum allowed size")
    end

    it "answers 422 for a bundle carrying document data" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipdocs")
        Facet::Mutation::Client.create(
          db, "zipdocs", "Widget",
          doc_id: "zipdocs.Widget.1",
          content: %({"name": "one"}),
          actioner_id: "system:test",
        )
        bytes = portable_http_bundle_zip(db, "zipdocs", with_documents: true)

        response = post_domain_import(bytes, "into=zipnew")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("definition-only")
      end
    end

    it "answers 409 when the target exists and merge is off" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipconflict")
        portable_http_seed_domain(db, "zipothersrc")
        bytes = portable_http_bundle_zip(db, "zipothersrc")

        response = post_domain_import(bytes, "into=zipconflict")
        response.status_code.should eq(409)
        body_json(response)["error"].as_s.should contain("merge=true")
      end
    end

    it "answers 422 for an invalid into name" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipnamesrc")
        bytes = portable_http_bundle_zip(db, "zipnamesrc")

        response = post_domain_import(bytes, "into=Bad_Name")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("Target name")
      end
    end

    it "answers 403 when the caller lacks write access and never leaks existence" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipwriteden")
        portable_http_seed_domain(db, "zipwriteden2")
        bytes = portable_http_bundle_zip(db, "zipwriteden")

        request = HTTP::Request.new("POST", "/Api/core/Domain/import?into=zipwriteden2",
          headers: HTTP::Headers{"Content-Type" => "application/zip", "X-Requested-With" => "XMLHttpRequest"},
          body: bytes)
        # A merge onto an existing domain needs update; the viewer has none.
        response = call_api_as(request, viewer_auth)
        response.status_code.should eq(403)

        # A fresh import needs create; the viewer has none — and the
        # 403 must come before any 409-style existence answer.
        fresh_request = HTTP::Request.new("POST", "/Api/core/Domain/import?into=zipbrandnew",
          headers: HTTP::Headers{"Content-Type" => "application/zip", "X-Requested-With" => "XMLHttpRequest"},
          body: bytes)
        fresh = call_api_as(fresh_request, viewer_auth)
        fresh.status_code.should eq(403)
      end
    end

    it "answers 403 without the CSRF header" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipicsrf")
        bytes = portable_http_bundle_zip(db, "zipicsrf")

        response = post_domain_import(bytes, "into=zipicsrftgt", csrf: false)
        response.status_code.should eq(403)
      end
    end
  end

  describe "status route" do
    it "reports pending with a null result" do
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipst")
        job_id = seed_pending_domain_export(db, "zipst", "system")

        response = get_domain_status(job_id)
        response.status_code.should eq(200)
        body = body_json(response)
        body["id"].as_s.should eq(job_id)
        body["status"].as_s.should eq("pending")
        body["result"].raw.should be_nil
      end
    end

    it "answers 404 for an unknown job and for another account's job" do
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipst404")
        job_id = seed_pending_domain_export(db, "zipst404", "iam.Account.somebody")

        get_domain_status("01J00000000000000000000000").status_code.should eq(404)

        request = HTTP::Request.new("GET", "/Api/core/Domain/import_export/#{job_id}")
        foreign = call_api_as(request, writer_auth("iam.Account.otherbody"))
        foreign.status_code.should eq(404)
      end
    end

    it "answers 404 for a document-concern job id (kind not served here)" do
      with_db do |db|
        payload = {
          "domain"     => JSON::Any.new("core"),
          "doc_type"   => JSON::Any.new("Domain"),
          "format"     => JSON::Any.new("csv"),
          "account_id" => JSON::Any.new("system"),
          "filters"    => JSON::Any.new({} of String => JSON::Any),
        } of String => JSON::Any
        id = Facet::Util::ScriptHelpers.ulid
        Facet::Jobs::Queries.insert(db, id, Facet::Document::ExportJob::KIND, JSON.parse(payload.to_json),
          max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)

        get_domain_status(id).status_code.should eq(404)
      end
    end
  end

  describe "download route" do
    it "streams the zip for a succeeded export" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipdl")
        job_id = seed_pending_domain_export(db, "zipdl", "system")
        run_claimed_domain_job(db, job_id)

        response = get_domain_download(job_id)
        response.status_code.should eq(200)
        response.headers["Content-Type"].should contain("application/zip")
        response.headers["Content-Disposition"].should contain("zipdl.facet-domain.zip")
        response.body[0, 4].to_slice.hexstring.should eq("504b0304")
      end
    end

    it "answers 404 for a pending job, a failed job, and an import job" do
      install_portable_enqueue_only_manager
      with_db do |db|
        portable_http_reseed_core(db)
        portable_http_seed_domain(db, "zipdl404")

        pending_id = seed_pending_domain_export(db, "zipdl404", "system")
        get_domain_download(pending_id).status_code.should eq(404)

        # A failed export has no file.
        Facet::Jobs::Queries.write_failed(db, pending_id, error: "nope", backoff_seconds: [] of Int32)
        get_domain_download(pending_id).status_code.should eq(404)

        # An import job never carries a downloadable file.
        import_payload = {
          "bundle_artifact_id" => JSON::Any.new("01J00000000000000000000000"),
          "source_domain"      => JSON::Any.new("zipdl404"),
          "into"               => JSON::Any.new(nil),
          "merge"              => JSON::Any.new(false),
          "account_id"         => JSON::Any.new("system"),
        } of String => JSON::Any
        import_id = Facet::Util::ScriptHelpers.ulid
        Facet::Jobs::Queries.insert(db, import_id, Facet::Domain::Portable::ImportJob::KIND,
          JSON.parse(import_payload.to_json), max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
        get_domain_download(import_id).status_code.should eq(404)
      end
    end
  end

  describe "wait mode" do
    it "resolves to the zip bytes when a real worker finishes the export" do
      with_domain_worker do
        with_db do |db|
          portable_http_reseed_core(db)
          portable_http_seed_domain(db, "zipwait")

          response = post_domain_export("zipwait", "wait=true")
          response.status_code.should eq(200)
          response.headers["Content-Type"].should contain("application/zip")
          response.body[0, 4].to_slice.hexstring.should eq("504b0304")
        end
      end
    end

    it "resolves the caller's role when the enqueuer is a real principal" do
      # The payload's role_id is the qualified `iam.Roles` reference
      # (`CallerContext.role_reference`) — a bare name fails the
      # execution-time rebuild. The credential-less specs never stamp the
      # field, and the gate specs build their ActiveRoles in memory, so only
      # a Real principal over a seeded role exercises the stamp → rebuild seam.
      with_domain_worker do
        with_db do |db|
          portable_http_reseed_core(db)
          portable_http_seed_domain(db, "zipreal")

          Facet::Mutation::Client.create(
            db, "iam", "Roles",
            doc_id: "iam.Roles.portable_route_real",
            content: %({"name": "portable_route_real", "visible_tags": ["default"], "permissions": [{"action": "read", "on": "core.Domain"}]}),
            actioner_id: "system",
          ).should be_a(String)
          role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.portable_route_real").not_nil!
          auth = Facet::RBAC::AuthContext.authenticated(
            "iam.Account.portable_real",
            Facet::RBAC::ActiveRole.from_projection_content(role_content),
          )

          request = HTTP::Request.new("POST", "/Api/core/Domain/zipreal/export?wait=true",
            headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"})
          response = call_api_as(request, auth)

          # Wait mode streams the zip on success — a role-resolution
          # failure answers 422 with the error instead.
          response.status_code.should eq(200)
          response.headers["Content-Type"].should contain("application/zip")
        end
      end
    end
  end
end
