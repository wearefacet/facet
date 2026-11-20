# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"

# B-166 — CSRF admission gate on the document write routes.
#
# A cookie-session write must carry a non-blank `X-Requested-With` header
# (403 with the shared CSRF body otherwise). A request that presents a
# `Bearer` Authorization credential without an `auth_token` cookie is
# exempt — browsers never attach an Authorization header to cross-site
# requests, so the credential is non-ambient and cannot be replayed by a
# CSRF forgery. The specs drive the raw request shape through
# `call_api_raw` / `call_api_raw_as`: `call_api` adds the browser default
# header and would mask the negative paths.
HTTPTest.init

def seed_csrf_doctypes : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    ensure_domain(db, "hr")

    # hr.Employee carries a reference to identity.Person — the target
    # doctype must be registered before an Employee create validates.
    person_defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(person_defn)

    employee_defn = build_doctype_definition("hr.Employee/definition.yml", "hr.Employee/script.lua")
    create_doctype(employee_defn)

    career_defn = load_doctype_schema("hr.CareerEvent/definition.yml")
    create_doctype(career_defn)
  end
end

# Creates the identity.Person row an hr.Employee `person` reference
# validates against. Returns the qualified reference token.
def seed_csrf_person : String
  person_id = "csrf-person-#{unique_suffix}"
  with_db do |db|
    result = Facet::Document::Create.call(
      db, "identity", "Person",
      %({"full_name": "CSRF Spec Target", "email": "#{person_id}@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}),
      Facet::RBAC::AuthContext.system,
      doc_id: person_id,
    )
    raise "person seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
  "identity.Person.#{person_id}"
end

describe "document write routes CSRF gate" do
  before_each do
    seed_csrf_doctypes
  end

  it "answers 403 with the shared CSRF body for a create with no header and no Authorization credential" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{"Content-Type" => "application/json"},
      %({ "id": "csrf-flat-#{unique_suffix}" }),
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("CSRF")
    JSON.parse(resp.body)["error"].as_s.should contain("X-Requested-With")
  end

  it "answers 201 for the same create with the header" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      },
      %({ "id": "csrf-ok-#{unique_suffix}" }),
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 201)
  end

  it "lets a Bearer credential create without the header (non-ambient exemption)" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer spec-non-ambient-token",
      },
      %({ "id": "csrf-bearer-#{unique_suffix}" }),
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 201)
  end

  it "answers 403 for an empty X-Requested-With value" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "",
      },
      %({ "id": "csrf-empty-#{unique_suffix}" }),
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("CSRF")
  end

  it "keeps the cookie session CSRF-checked beside a Bearer credential" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer spec-ambient-token",
        "Cookie"        => "auth_token=spec-session-token",
      },
      %({ "id": "csrf-cookie-#{unique_suffix}" }),
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("CSRF")
  end

  it "answers 403 for a nested child create without the header and 201 with it" do
    person = seed_csrf_person
    emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "Engineer", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": #{person.to_json}}))

    no_header = HTTP::Request.new(
      "POST", "/Api/hr/Employee/#{emp_id}/career_events",
      HTTP::Headers{"Content-Type" => "application/json"},
      %({ "seq": 1, "event_type": "hired", "effective_date": "2025-01-01" }),
    )
    resp = call_api_raw(no_header)
    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("CSRF")

    with_header = HTTP::Request.new(
      "POST", "/Api/hr/Employee/#{emp_id}/career_events",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      },
      %({ "seq": 1, "event_type": "hired", "effective_date": "2025-01-01" }),
    )
    resp = call_api_raw(with_header)
    assert_http_status(resp, 201)
  end

  it "answers 403 for an action POST without the header and 200 with it" do
    person = seed_csrf_person
    emp_id = create_doc_id_http("hr", "Employee", %({"status": "active", "hire_date": "2024-01-01", "job_title": "Junior Engineer", "department": "Eng", "salary": #{money_json("50000", "USD")}, "remote": false, "person": #{person.to_json}}))

    no_header = HTTP::Request.new(
      "POST", "/Api/hr/Employee/#{emp_id}/promote",
      HTTP::Headers{"Content-Type" => "application/json"},
      %({ "new_title": "Senior Engineer" }),
    )
    resp = call_api_raw(no_header)
    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("CSRF")

    with_header = HTTP::Request.new(
      "POST", "/Api/hr/Employee/#{emp_id}/promote",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      },
      %({ "new_title": "Senior Engineer" }),
    )
    resp = call_api_raw(with_header)
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"]["job_title"].as_s.should eq("Senior Engineer")
  end
end

# B-165 — media-type gate on the flat document routes (create / update).
#
# A declared non-JSON media type answers 415 (multipart/form-data keeps its
# dedicated intake on create and update); a malformed body under a JSON
# media type answers 400 on create. A body with no Content-Type at all
# keeps the flat routes' tolerance: the body itself must parse.
describe "document routes media gate" do
  it "answers 415 for a form-urlencoded create" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"     => "application/x-www-form-urlencoded",
        "X-Requested-With" => "XMLHttpRequest",
      },
      "id=notjson",
    )
    resp = call_api(request)

    assert_http_status(resp, 415)
    resp.body.should contain("application/json")
    resp.body.should contain("multipart/form-data")
  end

  it "answers 415 for a form-urlencoded update" do
    request = HTTP::Request.new(
      "PATCH", "/Api/core/Domain/01NOFORMDOCTYPE000000000",
      HTTP::Headers{
        "Content-Type"     => "text/plain",
        "X-Requested-With" => "XMLHttpRequest",
      },
      "plain text",
    )
    resp = call_api(request)

    assert_http_status(resp, 415)
    resp.body.should contain("application/json")
  end

  it "answers 400 for malformed JSON on create" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      },
      "{broken",
    )
    resp = call_api(request)

    assert_http_status(resp, 400)
    resp.body.should contain("Invalid JSON body")
  end

  it "keeps the no-Content-Type tolerance on create" do
    request = HTTP::Request.new(
      "POST", "/Api/core/Domain",
      HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"},
      %({ "id": "csrf-noct-#{unique_suffix}" }),
    )
    resp = call_api(request)

    assert_http_status(resp, 201)
  end
end
