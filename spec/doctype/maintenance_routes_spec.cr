# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

require "../../src/jobs"
require "../../src/http/server"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../support/http_helper"

# Specs for the doctype maintenance HTTP routes (`MaintenanceRoutes`):
# the enqueue gates (definition existence, write permission on the
# `core.DocType` document, CSRF, dedupe), the staged job rows, the status
# counts, and the doctype-scoped jobs list.
#
# Tests run with `AuthHandler` disabled: `call_api` answers as system, and
# `call_api_as` pins a specific `AuthContext` for the RBAC paths. The jobs
# manager is reset, so enqueues take the direct-insert fallback and rows
# stay `pending` — no worker claims them mid-spec.

# Seeds a v1 doctype with a `migrate_from_1` script and *count* documents.
# Returns the document ids.
private def maintenance_http_seed(db, domain, dt, count : Int32 = 1) : Array(String)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'migrated'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  ensure_domain(db, domain)
  Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

  ids = [] of String
  count.times do |i|
    r = Facet::Document::Create.call(db, domain, dt, %({"title": "doc #{i}"}), Facet::RBAC::AuthContext.system)
    ids << r.as(Facet::Document::Create::Result).projection.id
  end
  ids
end

# Bumps the doctype to v2 with a failing migration body. Includes the
# `migrations` map — a breaking (version-bumping) update may carry one.
private def maintenance_http_bump(db, domain, dt) : Nil
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.error('boom')
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{dt}")
end

# An auth that may read the doctype definitions but not update them.
private def maintenance_reader_auth : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(
    "iam.Account.reader",
    rbac_role([rbac_perm("read", "core.DocType")], "dt_reader"),
  )
end

# POSTs one maintenance enqueue route. Raw dispatch: the csrf flag owns
# the header's presence, so the harness default must not re-add it.
private def post_maintenance(path : String, csrf : Bool = true) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  call_api_raw(HTTP::Request.new("POST", path, headers))
end

private def get_maintenance(path : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", path))
end

private def body_json(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

describe Facet::Doctype::MaintenanceRoutes do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    HTTPTest.init

    Facet::Jobs::Manager.reset!
    with_db(&.exec("DELETE FROM background_jobs"))
  end

  describe "enqueue" do
    it "answers 202 with job_id and status_url and stages a pending job" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        response = post_maintenance("/Api/core/DocType/#{qualified}/reproject")
        response.status_code.should eq(202)
        body = body_json(response)
        job_id = body["job_id"].as_s
        body["status_url"].as_s.should eq("/Api/core/DocType/#{qualified}/maintenance_jobs")

        row = Facet::Jobs::Queries.find(db, job_id).not_nil!
        row.kind.should eq("doctype_reproject")
        row.payload["domain"].as_s.should eq(domain)
        row.payload["doc_type"].as_s.should eq(dt)
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

    it "answers 409 while a same-kind row is pending and 202 once it is terminal" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        first = post_maintenance("/Api/core/DocType/#{qualified}/reproject")
        first.status_code.should eq(202)
        job_id = body_json(first)["job_id"].as_s

        dup = post_maintenance("/Api/core/DocType/#{qualified}/reproject")
        dup.status_code.should eq(409)

        # The other kind is a distinct dedupe slot.
        other = post_maintenance("/Api/core/DocType/#{qualified}/migrate_ahead")
        other.status_code.should eq(202)

        # A terminal row no longer blocks a new enqueue.
        Facet::Jobs::Queries.write_succeeded(db, job_id)
        again = post_maintenance("/Api/core/DocType/#{qualified}/reproject")
        again.status_code.should eq(202)
      end
    end

    it "answers 404 for an unknown doctype and 422 for a malformed id" do
      with_db do |_db|
        ghost = "ghost.T#{unique_suffix(4)}"
        response = post_maintenance("/Api/core/DocType/#{ghost}/reproject")
        response.status_code.should eq(404)

        malformed = post_maintenance("/Api/core/DocType/nodot/reproject")
        malformed.status_code.should eq(422)
      end
    end

    it "answers 403 without the CSRF header and 403 without update permission" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        no_csrf = post_maintenance("/Api/core/DocType/#{qualified}/reproject", csrf: false)
        no_csrf.status_code.should eq(403)

        request = HTTP::Request.new("POST", "/Api/core/DocType/#{qualified}/reproject",
          headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"})
        response = call_api_as(request, maintenance_reader_auth)
        response.status_code.should eq(403)
      end
    end
  end

  describe "status counts" do
    it "reports the ahead and blocked counts and the current version" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        ids = maintenance_http_seed(db, domain, dt, 2)
        qualified = "#{domain}.#{dt}"

        # Before the bump: nothing is ahead, nothing is blocked.
        before = get_maintenance("/Api/core/DocType/#{qualified}/maintenance_status")
        before.status_code.should eq(200)
        body = body_json(before)
        body["ahead_count"].as_i.should eq(0)
        body["blocked_count"].as_i.should eq(0)
        body["current_version"].as_i.should eq(1)

        # After the bump: both rows sit below the current version. A lazy
        # read of one row fails and writes the marker.
        maintenance_http_bump(db, domain, dt)
        read = Facet::Document::Read.call(db, domain, dt, ids.first, Facet::RBAC::AuthContext.system)
        read.should be_a(Facet::Document::Read::Result)

        after = get_maintenance("/Api/core/DocType/#{qualified}/maintenance_status")
        after.status_code.should eq(200)
        body = body_json(after)
        body["ahead_count"].as_i.should eq(2)
        body["blocked_count"].as_i.should eq(1)
        body["current_version"].as_i.should eq(2)
      end
    end

    it "answers 404 for an unknown doctype" do
      ghost = "ghost.T#{unique_suffix(4)}"
      response = get_maintenance("/Api/core/DocType/#{ghost}/maintenance_status")
      response.status_code.should eq(404)
    end
  end

  describe "jobs list" do
    it "lists the doctype's maintenance jobs, newest first" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        first = post_maintenance("/Api/core/DocType/#{qualified}/reproject")
        second = post_maintenance("/Api/core/DocType/#{qualified}/migrate_ahead")
        first_id = body_json(first)["job_id"].as_s
        second_id = body_json(second)["job_id"].as_s

        response = get_maintenance("/Api/core/DocType/#{qualified}/maintenance_jobs")
        response.status_code.should eq(200)
        body = body_json(response)
        body["meta"]["more"].as_bool.should be_false
        rows = body["data"].as_a
        rows.size.should eq(2)
        rows[0]["id"].as_s.should eq(second_id)
        rows[1]["id"].as_s.should eq(first_id)
        rows[0]["kind"].as_s.should eq("doctype_migrate_ahead")
        rows[1]["kind"].as_s.should eq("doctype_reproject")
        rows[0]["status"].as_s.should eq("pending")
      end
    end

    it "paginates with the capped count and more flag" do
      with_db do |db|
        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        first_id = body_json(post_maintenance("/Api/core/DocType/#{qualified}/reproject"))["job_id"].as_s
        Facet::Jobs::Queries.write_succeeded(db, first_id)
        post_maintenance("/Api/core/DocType/#{qualified}/reproject")

        # Two jobs fit under the cap, so `more` stays false and `count` is
        # the real number from each page's offset.
        response = get_maintenance("/Api/core/DocType/#{qualified}/maintenance_jobs?page=1&items=1")
        response.status_code.should eq(200)
        body = body_json(response)
        body["data"].as_a.size.should eq(1)
        body["meta"]["count"].as_i.should eq(2)
        body["meta"]["more"].as_bool.should be_false

        page2 = get_maintenance("/Api/core/DocType/#{qualified}/maintenance_jobs?page=2&items=1")
        body2 = body_json(page2)
        body2["data"].as_a.size.should eq(1)
        body2["meta"]["count"].as_i.should eq(1)
        body2["meta"]["more"].as_bool.should be_false
      end
    end

    it "answers 404 for an unknown doctype and 403 without update permission" do
      with_db do |db|
        ghost = "ghost.T#{unique_suffix(4)}"
        response = get_maintenance("/Api/core/DocType/#{ghost}/maintenance_jobs")
        response.status_code.should eq(404)

        domain = "maint#{unique_suffix(4)}"
        dt = "T#{unique_suffix(4)}"
        maintenance_http_seed(db, domain, dt)
        qualified = "#{domain}.#{dt}"

        request = HTTP::Request.new("GET", "/Api/core/DocType/#{qualified}/maintenance_jobs")
        forbidden = call_api_as(request, maintenance_reader_auth)
        forbidden.status_code.should eq(403)
      end
    end
  end
end
