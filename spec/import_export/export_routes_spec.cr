# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "csv"
require "json"
require "../../src/jobs"
require "../../src/http/server"
require "../support/http_helper"
require "../../src/import_export/routes"

# Specs drive the routes with a real generated domain/doctype pair, exactly
# like the document service specs do: the domain and doctype created in the
# block are the ones the URLs name.

private def post_export(domain : String, doctype : String, query : String, csrf : Bool = true) : HTTP::Client::Response
  headers = HTTP::Headers{
    "Content-Type" => "application/json",
  }
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/export?#{query}", headers: headers)
  # Raw dispatch: the csrf flag owns the header's presence, so the harness
  # default must not re-add it.
  call_api_raw(request)
end

# Posts one view-export enqueue: the JSON body is the transport, so the
# helper takes the body text and the headers the test wants to vary.
private def post_export_view(
  domain : String,
  doctype : String,
  body : String,
  query : String = "",
  csrf : Bool = true,
  content_type : String? = "application/json",
) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["Content-Type"] = content_type if content_type
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  suffix = query.empty? ? "" : "?#{query}"
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/export_view#{suffix}", headers: headers, body: body)
  # Raw dispatch: the csrf flag owns the header's presence, so the harness
  # default must not re-add it.
  call_api_raw(request)
end

private def get_status(domain : String, doctype : String, job_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/import_export/#{job_id}"))
end

private def get_download(domain : String, doctype : String, job_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/import_export/#{job_id}/download"))
end

private def body_json(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

private def create_route_doctype(
  db : DB::Connection,
  domain : String,
  doctype : String,
  fields : String,
  extra : String = "",
) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}#{extra}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_route_doc(db : DB::Connection, domain : String, doctype : String, content : String) : String
  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

# One export job in pending state, exactly as the enqueue route stages it.
private def seed_pending_export(db : DB::Connection, domain : String, doctype : String, account_id : String, format : String = "csv") : String
  payload = {
    "domain"     => JSON::Any.new(domain),
    "doc_type"   => JSON::Any.new(doctype),
    "format"     => JSON::Any.new(format),
    "account_id" => JSON::Any.new(account_id),
    "filters"    => JSON::Any.new({} of String => JSON::Any),
  } of String => JSON::Any
  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Document::ExportJob::KIND, JSON.parse(payload.to_json),
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# Claims one row and records the outcome the way the worker does — the
# synchronous counterpart of the wait-mode worker path.
private def run_claimed_export(db : DB::Connection, job_id : String) : Nil
  claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
  job = claimed.find! { |j| j.id == job_id }
  result = Facet::Document::ExportJob.new.execute(job)
  case result.status
  in .succeeded?
    Facet::Jobs::Queries.write_succeeded(db, job.id, result: result.result)
  in .failed?
    Facet::Jobs::Queries.write_failed(db, job.id, error: result.error, result: result.result, backoff_seconds: job.backoff)
  end
end

private def install_enqueue_only_manager : Facet::Jobs::Manager
  mgr = Facet::Jobs::Manager.new(handlers: {
    Facet::Document::ExportJob::KIND => Facet::Document::ExportJob,
  } of String => Facet::Jobs::Handler.class)
  Facet::Jobs::Manager.instance = mgr
  mgr
end

private def download_wait_worker : Facet::Jobs::Worker
  worker = Facet::Jobs::Worker.new(
    poll_interval_s: 0.01,
    handlers: {
      Facet::Document::ExportJob::KIND => Facet::Document::ExportJob,
    } of String => Facet::Jobs::Handler.class,
  )
  worker.start
  worker
end

# Runs the block with a live worker executing the real export handler.
# The worker stops in `ensure` — a failed assertion must never leave a
# worker polling the shared test database into the next example.
private def with_export_worker(& : Facet::Jobs::Worker -> Nil) : Nil
  worker = download_wait_worker
  begin
    yield worker
  ensure
    stop_worker_draining(worker)
  end
end

# A handler that fails a `document_export` row with a scripted error —
# the wait-mode failure branch is a route contract, and a scripted worker
# outcome is its deterministic driver.
private class FailingExportStub < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "scripted export failure")
  end
end

private def with_failing_export_worker(& : Facet::Jobs::Worker -> Nil) : Nil
  worker = Facet::Jobs::Worker.new(
    poll_interval_s: 0.01,
    handlers: {
      Facet::Document::ExportJob::KIND => FailingExportStub,
    } of String => Facet::Jobs::Handler.class,
  )
  worker.start
  begin
    yield worker
  ensure
    stop_worker_draining(worker)
  end
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

  describe "enqueue route" do
    it "answers 202 with job_id and status_url and stages a pending job" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpok", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))

        response = post_export(domain, dt, "format=csv")
        response.status_code.should eq(202)
        body = body_json(response)
        job_id = body["job_id"].as_s
        body["status_url"].as_s.should eq("/Api/#{domain}/#{dt}/import_export/#{job_id}")

        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        row.payload["domain"].as_s.should eq(domain)
        row.max_attempts.should eq(1)
        status, lease = db.query_one(
          "SELECT status, lease_ttl_s FROM background_jobs WHERE id = $1", job_id,
          as: {String, Int32?},
        )
        status.should eq("pending")
        lease.should eq(3600)
      end
    end

    it "answers 422 for an invalid format" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpfmt", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export(domain, dt, "format=yaml")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("yaml")
      end
    end

    it "answers 422 for a missing format" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpnof", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export(domain, dt, "")
        response.status_code.should eq(422)
      end
    end

    it "answers 422 for a malformed money filter, naming the param" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpmoney", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"price": {"type": "money", "filters": ["comparison"]}}))

        response = post_export(domain, dt, "format=csv&price__gte=#{URI.encode_path("XXX 100")}")
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("XXX")
      end
    end

    it "answers 422 for sort, page, per_page, and items" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpsort", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        post_export(domain, dt, "format=csv&sort=-id").status_code.should eq(422)
        post_export(domain, dt, "format=csv&page=2").status_code.should eq(422)
        post_export(domain, dt, "format=csv&per_page=10").status_code.should eq(422)
        post_export(domain, dt, "format=csv&items=10").status_code.should eq(422)
      end
    end

    it "accepts list-action filter brackets and bare operator params" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpbr", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string", "filters": ["comparison"]}}))

        response = post_export(domain, dt, "format=csv&filters[label__eq]=a&label__ne=b")
        response.status_code.should eq(202)
      end
    end

    # B-108: array-valued filters ride JSON-encoded on the query string —
    # the wire form the list action's parser decodes. The export route
    # must decode them through the same decoder, or the shared compiler
    # would answer 422 for a filter value the list action accepts.
    it "decodes a JSON-array __in filter like the list action (B-108)" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpin", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"sku": {"type": "string", "filters": ["equality"]}}))
        create_route_doc(db, domain, dt, %({"sku": "A"}))
        create_route_doc(db, domain, dt, %({"sku": "B"}))
        create_route_doc(db, domain, dt, %({"sku": "C"}))

        payload = URI.encode_path(["A", "B"].to_json)
        response = nil
        with_export_worker do |_worker|
          response = post_export(domain, dt, "format=csv&wait=true&filters[sku__in]=#{payload}")
        end

        response = response.should_not be_nil
        response.status_code.should eq(200)
        rows = CSV.parse(response.body)
        rows.first.should eq(["id", "sku"])
        skus = rows[1..].map { |row| row[1] }
        skus.sort.should eq(["A", "B"])
      end
    end

    it "still answers 422 for a __in value that is not a JSON array (B-108)" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpinbad", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"sku": {"type": "string", "filters": ["equality"]}}))

        # A plain string keeps the raw form and fails the compile, loud.
        plain = post_export(domain, dt, "format=csv&filters[sku__in]=A,B")
        plain.status_code.should eq(422)
        body_json(plain)["error"].as_s.should contain("sku__in")

        # `[`-prefixed text that does not parse as JSON stays a string too.
        malformed = post_export(domain, dt,
          "format=csv&filters[sku__in]=#{URI.encode_path("[\"A\"")}")
        malformed.status_code.should eq(422)
      end
    end

    it "answers 404 for an unknown doctype" do
      install_enqueue_only_manager
      headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      request = HTTP::Request.new("POST", "/Api/rtnone/Nobody/export?format=csv", headers: headers)
      response = call_api(request)
      response.status_code.should eq(404)
      body_json(response)["error"].as_s.should contain("Unknown doctype")
    end

    it "answers 403 at enqueue for a caller with no read grant" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpdeny", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))

        headers = HTTP::Headers{
          "Content-Type"     => "application/json",
          "X-Requested-With" => "XMLHttpRequest",
        }
        request = HTTP::Request.new("POST", "/Api/#{domain}/#{dt}/export?format=csv", headers: headers)
        response = call_api_as(request, Facet::RBAC::AuthContext.denied)

        response.status_code.should eq(403)
        body_json(response)["error"].as_s.should eq("Forbidden")
        # The gate runs before the enqueue: no doomed job row is staged.
        db.query_one("SELECT COUNT(*) FROM background_jobs", as: Int64).should eq(0)
      end
    end

    it "answers 403 without the CSRF header" do
      install_enqueue_only_manager
      with_temp_doctype("rtexpcsrf", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export(domain, dt, "format=csv", csrf: false)
        response.status_code.should eq(403)
      end
    end
  end

  describe "view-export enqueue route" do
    it "answers 202 and stages a job whose payload carries columns, sort, and timezone" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewok", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt,
          %({"label": {"type": "string", "filters": ["equality"]}, "price": {"type": "money"}}))
        create_route_doc(db, domain, dt, %({"label": "a", "price": {"value": "1.0", "currency": "USD"}}))

        body = %({"columns": ["label", "price", "created_at"], "sort": ["-label", "id"], "filters": {"label__eq": "a"}, "timezone": "Europe/Paris"})
        response = post_export_view(domain, dt, body)
        response.status_code.should eq(202)
        job_id = body_json(response)["job_id"].as_s
        body_json(response)["status_url"].as_s.should eq("/Api/#{domain}/#{dt}/import_export/#{job_id}")

        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        row.kind.should eq(Facet::Document::ExportJob::KIND)
        row.payload["format"].as_s.should eq("csv")
        row.payload["columns"].as_a.map(&.as_s).should eq(["label", "price", "created_at"])
        row.payload["sort"].as_a.map(&.as_s).should eq(["-label", "id"])
        row.payload["timezone"].as_s.should eq("Europe/Paris")
        row.payload["filters"]["label__eq"].as_s.should eq("a")
      end
    end

    it "treats an absent sort and timezone as absent" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewmin", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export_view(domain, dt, %({"columns": ["label"]}))
        response.status_code.should eq(202)
        row = Facet::Jobs::Queries.find(db, body_json(response)["job_id"].as_s).not_nil!
        row.payload["columns"].as_a.map(&.as_s).should eq(["label"])
        row.payload["sort"]?.should be_nil
        row.payload["timezone"]?.should be_nil
        row.payload["filters"].as_h.size.should eq(0)
      end
    end

    it "answers 422 for a missing, empty, non-array, or duplicate columns payload" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewcols", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        post_export_view(domain, dt, %({})).status_code.should eq(422)
        post_export_view(domain, dt, %({"columns": []})).status_code.should eq(422)
        post_export_view(domain, dt, %({"columns": "label"})).status_code.should eq(422)
        post_export_view(domain, dt, %({"columns": [1, 2]})).status_code.should eq(422)
        dup = post_export_view(domain, dt, %({"columns": ["label", "label"]}))
        dup.status_code.should eq(422)
        body_json(dup)["error"].as_s.should contain("Duplicate")
      end
    end

    it "answers 422 for an unknown column, naming it, and for an unknown doctype" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewunk", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        unknown = post_export_view(domain, dt, %({"columns": ["label", "ghost"]}))
        unknown.status_code.should eq(422)
        body_json(unknown)["error"].as_s.should contain("ghost")

        response = post_export_view("rtviewnone", "Nobody", %({"columns": ["id"]}))
        response.status_code.should eq(404)
        body_json(response)["error"].as_s.should contain("Unknown doctype")
      end
    end

    it "answers 422 for a malformed money filter and an invalid timezone" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewbad", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"price": {"type": "money", "filters": ["comparison"]}}))

        money = post_export_view(domain, dt, %({"columns": ["price"], "filters": {"price__gte": "XXX 100"}}))
        money.status_code.should eq(422)
        body_json(money)["error"].as_s.should contain("XXX")

        tz = post_export_view(domain, dt, %({"columns": ["price"], "timezone": "Mars/Olympus"}))
        tz.status_code.should eq(422)
        body_json(tz)["error"].as_s.should contain("Mars/Olympus")
      end
    end

    it "answers 415 for a non-JSON content type and 422 for a malformed or non-object body" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewbody", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        post_export_view(domain, dt, %({"columns": ["label"]}), content_type: "text/csv").status_code.should eq(415)
        post_export_view(domain, dt, "not json").status_code.should eq(422)
        post_export_view(domain, dt, %(["label"])).status_code.should eq(422)
      end
    end

    it "answers 422 for a stray query param; wait=true is the only accepted one" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewq", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        stray = post_export_view(domain, dt, %({"columns": ["label"]}), query: "format=csv")
        stray.status_code.should eq(422)
        body_json(stray)["error"].as_s.should contain("format")

        post_export_view(domain, dt, %({"columns": ["label"]}), query: "wait=true").status_code.should eq(202)
      end
    end

    it "answers 403 without the CSRF header" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewcsrf", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export_view(domain, dt, %({"columns": ["label"]}), csrf: false)
        response.status_code.should eq(403)
      end
    end

    it "refuses sidecar and member_of doctypes" do
      install_enqueue_only_manager
      with_temp_doctype("rtviewflat", "Host") do |db, domain, _dt|
        ensure_domain(db, domain)
        member_schema = %({"doctype": "Member", "domain": "#{domain}", "member_of": "Host", "fields": {"name": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", member_schema, Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Create::Result)

        response = post_export_view(domain, "Member", %({"columns": ["name"]}))
        response.status_code.should eq(422)
        body_json(response)["error"].as_s.should contain("parent")
      end
    end

    it "names the download .view.csv after a successful view-export run" do
      with_temp_doctype("rtviewdl", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))

        payload = {
          "domain"     => JSON::Any.new(domain),
          "doc_type"   => JSON::Any.new(dt),
          "format"     => JSON::Any.new("csv"),
          "account_id" => JSON::Any.new("system"),
          "filters"    => JSON::Any.new({} of String => JSON::Any),
          "columns"    => JSON.parse(["label"].to_json),
          "timezone"   => JSON::Any.new("Europe/Paris"),
        } of String => JSON::Any
        job_id = Facet::Util::ScriptHelpers.ulid
        Facet::Jobs::Queries.insert(db, job_id, Facet::Document::ExportJob::KIND, JSON.parse(payload.to_json),
          max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
        run_claimed_export(db, job_id)

        response = get_download(domain, dt, job_id)
        response.status_code.should eq(200)
        response.headers["Content-Disposition"].should contain("#{domain}.#{dt}.view.csv")
        rows = CSV.parse(response.body)
        rows.first.should eq(["label"])
      end
    end

    it "streams the view file in wait mode with the view filename" do
      install_enqueue_only_manager

      with_temp_doctype("rtviewwait", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}, "amount": {"type": "integer"}}))
        create_route_doc(db, domain, dt, %({"label": "a", "amount": 1}))

        response = nil
        with_export_worker do |_worker|
          response = post_export_view(domain, dt, %({"columns": ["label", "amount"], "sort": ["-amount"]}), query: "wait=true")
        end

        response = response.should_not be_nil
        response.status_code.should eq(200)
        response.headers["Content-Type"].should eq("text/csv")
        response.headers["Content-Disposition"].should contain("#{domain}.#{dt}.view.csv")
        rows = CSV.parse(response.body)
        rows.size.should eq(2)
        rows.first.should eq(["label", "amount"])
      end
    end
  end

  describe "status route" do
    it "reports pending with a null result" do
      with_temp_doctype("rtstpend", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        job_id = seed_pending_export(db, domain, dt, "system")

        response = get_status(domain, dt, job_id)
        response.status_code.should eq(200)
        body = body_json(response)
        body["id"].as_s.should eq(job_id)
        body["status"].as_s.should eq("pending")
        body["error"].raw.nil?.should be_true
        body["result"].raw.nil?.should be_true
      end
    end

    it "is requester-scoped: another account's job is a 404" do
      with_temp_doctype("rtstscope", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        job_id = seed_pending_export(db, domain, dt, "someone_else")

        response = get_status(domain, dt, job_id)
        response.status_code.should eq(404)
      end
    end

    it "answers 404 for an unknown job id and a foreign doctype URL" do
      with_temp_doctype("rtstft", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        job_id = seed_pending_export(db, domain, dt, "system")

        get_status(domain, dt, Facet::Util::ScriptHelpers.ulid).status_code.should eq(404)
        # The same job id under a mismatched doctype URL is a miss.
        request = HTTP::Request.new("GET", "/Api/#{domain}/Other/import_export/#{job_id}")
        call_api(request).status_code.should eq(404)
      end
    end
  end

  describe "download route" do
    it "streams the artifact with the export headers after a successful run" do
      with_temp_doctype("rtdl", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))
        job_id = seed_pending_export(db, domain, dt, "system")

        run_claimed_export(db, job_id)

        response = get_download(domain, dt, job_id)
        response.status_code.should eq(200)
        response.headers["Content-Type"].should eq("text/csv")
        response.headers["Content-Disposition"].should contain("attachment")
        response.headers["Content-Disposition"].should contain("#{domain}.#{dt}.csv")
        rows = CSV.parse(response.body)
        rows.size.should eq(2)
        rows.first.should eq(["id", "label"])
      end
    end

    it "answers 404 for another account's job, a running job, and an unknown job" do
      with_temp_doctype("rtdl404", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        foreign = seed_pending_export(db, domain, dt, "someone_else")
        pending = seed_pending_export(db, domain, dt, "system")

        get_download(domain, dt, foreign).status_code.should eq(404)
        get_download(domain, dt, pending).status_code.should eq(404) # not succeeded → no file
        get_download(domain, dt, Facet::Util::ScriptHelpers.ulid).status_code.should eq(404)
      end
    end
  end

  describe "wait mode" do
    it "returns the file itself when the job completes inside the window" do
      install_enqueue_only_manager

      with_temp_doctype("rtwait", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))

        response = nil
        with_export_worker do |_worker|
          response = post_export(domain, dt, "format=csv&wait=true")
        end

        response = response.should_not be_nil
        response.status_code.should eq(200)
        response.headers["Content-Type"].should eq("text/csv")
        rows = CSV.parse(response.body)
        rows.size.should eq(2)
        rows.first.should eq(["id", "label"])
      end
    end

    it "resolves the caller's role when the enqueuer is a real principal" do
      # The route stamps the payload's role_id as the
      # qualified `iam.Roles` reference (`CallerContext.role_reference`).
      # A bare role name there fails the execution-time rebuild —
      # "Import/export role X no longer exists" — for every authenticated
      # caller, while the credential-less specs (system context) never
      # stamp the field at all.
      install_enqueue_only_manager

      with_temp_doctype("rtreal", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_route_doc(db, domain, dt, %({"label": "a"}))

        Facet::Mutation::Client.create(
          db, "iam", "Roles",
          doc_id: "iam.Roles.export_route_real",
          content: %({"name": "export_route_real", "visible_tags": ["default"], "permissions": [{"action": "read", "on": "*.*"}]}),
          actioner_id: "system",
        ).should be_a(String)
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.export_route_real").not_nil!
        auth = Facet::RBAC::AuthContext.authenticated(
          "route_real_owner",
          Facet::RBAC::ActiveRole.from_projection_content(role_content),
        )

        response = nil
        with_export_worker do |_worker|
          headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
          request = HTTP::Request.new("POST", "/Api/#{domain}/#{dt}/export?format=csv&wait=true", headers: headers)
          response = call_api_as(request, auth)
        end

        # Wait mode streams the CSV on success — a role-resolution failure
        # answers 422 with the error instead.
        response = response.should_not be_nil
        response.status_code.should eq(200)
        response.headers["Content-Type"].should eq("text/csv")
      end
    end

    it "returns 500 with the job id when the job fails" do
      install_enqueue_only_manager

      with_temp_doctype("rtwaitfail", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = nil
        with_failing_export_worker do |_worker|
          response = post_export(domain, dt, "format=csv&wait=true")
        end

        response = response.should_not be_nil
        response.status_code.should eq(500)
        body = body_json(response)
        body["job_id"].as_s.should_not be_empty
        body["error"].as_s.should contain("scripted export failure")
      end
    end

    it "falls back to 202 with the enqueue body when the window lapses" do
      install_enqueue_only_manager
      # No worker: the job stays pending until the 1 s test timeout lapses.

      with_temp_doctype("rtwaitto", "Invoice") do |db, domain, dt|
        create_route_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        response = post_export(domain, dt, "format=csv&wait=true")
        response.status_code.should eq(202)
        body = body_json(response)
        job_id = body["job_id"].as_s
        body["status_url"].as_s.should_not be_empty

        status = db.query_one(
          "SELECT status FROM background_jobs WHERE id = $1", job_id, as: String)
        status.should eq("pending")
      end
    end
  end
end
