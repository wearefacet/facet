# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/jobs"
require "../../src/http/server"
require "../support/http_helper"
require "../../src/import_export/routes"

# Specs drive the import routes with a real generated domain/doctype pair,
# exactly like the export routes spec does.

private def post_import(domain : String, doctype : String, body : String, content_type : String = "application/json", csrf : Bool = true, query : String = "") : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => content_type}
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  suffix = query.empty? ? "" : "?#{query}"
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/import#{suffix}", headers: headers, body: body)
  # Raw dispatch: the csrf flag owns the header's presence, so the harness
  # default must not re-add it.
  call_api_raw(request)
end

private def get_status(domain : String, doctype : String, job_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/import_export/#{job_id}"))
end

private def body_json(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

private def create_rimp_doctype(db : DB::Connection, domain : String, doctype : String, fields : String) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

# One pending import job row staged exactly as the enqueue route stages it.
private def seed_pending_import(db : DB::Connection, domain : String, doctype : String, account_id : String) : String
  # Fixture staging has no requester — a system context keeps the staged
  # file and manifest ownerless; the import job reads them by id.
  file_artifact = Facet::ImportExport::Artifacts.put(
    db, IO::Memory.new(%([{"content": {"name": "x"}}])), "#{domain}.#{doctype}.json", "application/json", Facet::RBAC::AuthContext.system)
  manifest_artifact = Facet::ImportExport::Artifacts.put(
    db, IO::Memory.new(%({"ids": ["#{Facet::Util::ScriptHelpers.ulid}"], "supplied": [false]})), "#{domain}.#{doctype}.manifest.json", "application/json", Facet::RBAC::AuthContext.system)

  payload = {
    "domain"               => JSON::Any.new(domain),
    "doc_type"             => JSON::Any.new(doctype),
    "format"               => JSON::Any.new("json"),
    "account_id"           => JSON::Any.new(account_id),
    "file_artifact_id"     => JSON::Any.new(file_artifact.artifact_id),
    "manifest_artifact_id" => JSON::Any.new(manifest_artifact.artifact_id),
  } of String => JSON::Any

  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Document::ImportJob::KIND, JSON.parse(payload.to_json),
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# A live worker running the real import handler, stopped in ensure.
private def with_import_worker(& : Facet::Jobs::Worker -> Nil) : Nil
  worker = Facet::Jobs::Worker.new(
    poll_interval_s: 0.01,
    handlers: {
      Facet::Document::ImportJob::KIND => Facet::Document::ImportJob,
    } of String => Facet::Jobs::Handler.class,
  )
  worker.start
  begin
    yield worker
  ensure
    worker.stop
  end
end

private def install_enqueue_only_manager : Facet::Jobs::Manager
  mgr = Facet::Jobs::Manager.new(handlers: {
    Facet::Document::ImportJob::KIND => Facet::Document::ImportJob,
  } of String => Facet::Jobs::Handler.class)
  Facet::Jobs::Manager.instance = mgr
  mgr
end

describe Facet::ImportExport::Routes do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies
    HTTPTest.init

    Facet::Jobs::Manager.reset!
    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))
  end

  describe "import enqueue route" do
    it "answers 202 with job_id, row_count, and status_url; stages file + manifest artifacts" do
      install_enqueue_only_manager
      with_temp_doctype("rimpok", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        body = %([{"id": null, "content": {"name": "a"}}, {"content": {"name": "b"}}])
        response = post_import(domain, dt, body)

        response.status_code.should eq(202)
        result = body_json(response)
        job_id = result["job_id"].as_s
        result["row_count"].as_i.should eq(2)
        result["status_url"].as_s.should eq("/Api/#{domain}/#{dt}/import_export/#{job_id}")

        # The payload carries artifact ids only — no row content.
        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        payload = row.payload
        payload["file_artifact_id"].as_s.should_not be_empty
        payload["manifest_artifact_id"].as_s.should_not be_empty
        payload.as_h.has_key?("content").should be_false
        row.max_attempts.should eq(1)

        manifest = Facet::Artifact::Store.find_artifact(db, payload["manifest_artifact_id"].as_s).not_nil!
        manifest.filename.should eq("#{domain}.#{dt}.manifest.json")
      end
    end

    it "fast-fails a malformed CSV with the row number, before any job row exists" do
      install_enqueue_only_manager
      with_temp_doctype("rimpcsv", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        response = post_import(domain, dt, "id,name\n,r1\n,r2,extra\n", content_type: "text/csv")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("row 2")

        jobs = db.query_one("SELECT COUNT(*) FROM background_jobs", as: Int64)
        jobs.should eq(0)
      end
    end

    it "fast-fails a CSV with unknown header columns" do
      install_enqueue_only_manager
      with_temp_doctype("rimpcsvu", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        response = post_import(domain, dt, "id,name,bogus\n,x,y\n", content_type: "text/csv")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("bogus")
      end
    end

    it "fast-fails malformed JSON and a non-array JSON body" do
      install_enqueue_only_manager
      with_temp_doctype("rimpjson", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        bad = post_import(domain, dt, %({"content": {"name": "a"}}))
        bad.status_code.should eq(422)
        body_json(bad)["error"].as_s.should contain("array")

        broken = post_import(domain, dt, %([{"id": 1,))
        broken.status_code.should eq(422)
      end
    end

    it "answers 413 for an over-cap upload" do
      install_enqueue_only_manager
      with_temp_doctype("rimpcap", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        # A body larger than the 50 MiB test-config cap — the same
        # strategy the artifact upload specs use.
        big = %([{"content": {"name": "#{"x" * 53_000_000}"}}])
        response = post_import(domain, dt, big)
        response.status_code.should eq(413)
        body_json(response)["error"].as_s.should contain("maximum allowed size")
      end
    end

    it "answers 404 for an unknown doctype and 422 for sidecar/member_of" do
      install_enqueue_only_manager
      headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}

      response = call_api(HTTP::Request.new("POST", "/Api/rtnone/Nobody/import", headers: headers, body: %([])))
      response.status_code.should eq(404)
      body_json(response)["error"].as_s.should contain("Unknown doctype")

      with_temp_doctype("rimpguard", "Host") do |db, domain, _dt|
        # A member_of doctype refuses the flat route.
        ensure_domain(db, domain)
        member_schema = %({"doctype": "Member", "domain": "#{domain}", "member_of": "Host", "fields": {"name": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", member_schema, Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Create::Result)

        member = call_api(HTTP::Request.new("POST", "/Api/#{domain}/Member/import", headers: headers, body: %([])))
        member.status_code.should eq(422)
        body_json(member)["error"].as_s.should contain("parent")
      end
    end

    it "answers 403 without the CSRF header" do
      install_enqueue_only_manager
      with_temp_doctype("rimpcsrf", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        response = post_import(domain, dt, %([]), csrf: false)
        response.status_code.should eq(403)
      end
    end
  end

  describe "status + download for imports" do
    it "is requester-scoped like the export status route" do
      with_temp_doctype("rimpscope", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        job_id = seed_pending_import(db, domain, dt, "someone_else")

        get_status(domain, dt, job_id).status_code.should eq(404)
      end
    end

    it "reports succeeded with the report in result after a run" do
      with_temp_doctype("rimpstat", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        job_id = seed_pending_import(db, domain, dt, "system")

        # Run the claimed row with the real handler.
        claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
        job = claimed.find! { |j| j.id == job_id }
        result = Facet::Document::ImportJob.new.execute(job)
        Facet::Jobs::Queries.write_succeeded(db, job.id, result: result.result)

        response = get_status(domain, dt, job_id)
        response.status_code.should eq(200)
        body = body_json(response)
        body["status"].as_s.should eq("succeeded")
        body["result"]["row_count"].as_i.should eq(1)
        body["result"]["created"].as_i.should eq(1)
      end
    end
  end

  describe "import wait mode" do
    it "returns the report shape when the job completes inside the window" do
      install_enqueue_only_manager
      with_temp_doctype("rimpwait", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        response = nil
        with_import_worker do |_worker|
          response = post_import(domain, dt, %([{"content": {"name": "a"}}, {"content": {"name": "b"}}]), query: "wait=true")
        end

        response = response.should_not be_nil
        response.status_code.should eq(200)
        body = body_json(response)
        body["job_id"].as_s.should_not be_empty
        body["status"].as_s.should eq("succeeded")
        body["row_count"].as_i.should eq(2)
        body["created"].as_i.should eq(2)
        body["updated"].as_i.should eq(0)
        body["skipped"].as_i.should eq(0)
      end
    end

    it "returns 422 with the failing row when a row fails validation" do
      install_enqueue_only_manager
      with_temp_doctype("rimpwaitf", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string", "required": true}}))

        response = nil
        with_import_worker do |_worker|
          response = post_import(domain, dt, %([{"content": {"name": "ok"}}, {"content": {}}]), query: "wait=true")
        end

        response = response.should_not be_nil
        response.status_code.should eq(422)
        body = body_json(response)
        body["job_id"].as_s.should_not be_empty
        body["status"].as_s.should eq("failed")
        body["error"]["row"].as_i.should eq(2)
        body["error"]["field"].as_s.should eq("name")

        rows = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
        rows.should eq(0)
      end
    end

    it "falls back to 202 with the enqueue body when the window lapses" do
      install_enqueue_only_manager
      # No worker: the job stays pending until the 1 s test timeout lapses.

      with_temp_doctype("rimpwaitto", "Contact") do |db, domain, dt|
        create_rimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        response = post_import(domain, dt, %([{"content": {"name": "a"}}]))
        response.status_code.should eq(202)
        body = body_json(response)
        body["row_count"].as_i.should eq(1)
        body["status_url"].as_s.should_not be_empty

        status = db.query_one("SELECT status FROM background_jobs WHERE id = $1", body["job_id"].as_s, as: String)
        status.should eq("pending")
      end
    end
  end
end
