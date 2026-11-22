# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/domain/draft"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/iam_helper"

HTTPTest.init

# Seeds the core doctype definitions (`core.DocType`, `core.Domain`,
# `core.DocumentView`, …) and ensures the live source domain exists with one
# doctype definition under it. The global per-example TRUNCATE wipes the
# seeded rows, so every example re-establishes the baseline.
#
# The doctype definition is persisted via `Mutation::Client.create` directly
# (not `Doctype::Create`) because the live domain's doctype must exist under
# the `hr` domain string, and `Doctype::Create`'s service layer would run
# full validation against the seeded `core.DocType` definition — the same
# pattern `spec/domain/draft_domains_spec.cr` uses.
def seed_live_domain_with_doctype(db : DB::Connection) : Nil
  restore_seeded_baseline(db)
  ensure_domain(db, "hr")

  content = %({"doctype": "Employee", "domain": "hr", "schema_version": 1, "fields": {"name": {"type": "string"}}})
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "hr.Employee",
    content: content,
    actioner_id: "system:test",
  )
end

# Creates a draft via the public HTTP route and returns its id.
# Creates a draft derived from the live `hr` domain via the public route
# (`POST /Api/core/Domain/hr/draft`), then rewrites the draft's Employee
# definition with the caller's shape (fields / version / migrations / script).
# Returns the draft id.
def seed_draft_with_doctype_shape(
  db : DB::Connection,
  draft_fields : String? = nil,
  draft_version : Int32 = 1,
  draft_migrations : String? = nil,
  draft_script : String? = nil,
) : String
  resp = call_api(HTTP::Request.new(
    "POST",
    "/Api/core/Domain/hr/draft",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
  ))
  assert_http_status(resp, 201)
  draft = JSON.parse(resp.body)["data"]["id"].as_s

  content = JSON.build do |j|
    j.object do
      j.field "doctype", "Employee"
      j.field "domain", draft
      j.field "schema_version", draft_version
      j.field "fields", JSON.parse(draft_fields || %({"name": {"type": "string"}}))
      if draft_migrations
        j.field "migrations", JSON.parse(draft_migrations)
      end
      if draft_script
        j.field "script", draft_script
      end
    end
  end
  Facet::Mutation::Client.update(
    db, "core", "DocType", "#{draft}.Employee",
    diff_json: Facet::Mutation::JsonDiff.diff(
      Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Employee"),
      JSON.parse(content),
    ).to_json,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate("#{draft}.Employee")
  draft
end

describe "POST /Api/core/Domain/:id/draft" do
  before_each do
    with_db { |db| seed_live_domain_with_doctype(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  it "drafts a live domain's structure into a new _-prefixed draft domain" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/hr/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 201)

    data = JSON.parse(resp.body)["data"].as_h
    data["draft"].raw.should be_true
    data["source_domain"].as_s.should eq("hr")
    draft_name = data["id"].as_s
    draft_name.should start_with("_")

    # The doctype definition was copied under the draft domain.
    with_db do |db|
      draft_def = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "#{draft_name}.Employee")
      draft_def.content["domain"].as_s.should eq(draft_name)

      # No document data copied — zero Employee documents under the draft.
      count = db.query_one(
        "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = 'Employee'",
        draft_name, as: Int64)
      count.should eq(0)
    end
  end

  it "rejects with 422 when the source domain does not exist" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/_ghost/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("not found")
  end

  it "rejects with 422 when the source is itself a draft" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Cannot draft from a draft")
  end

  it "rejects with 409 when a draft already exists for the source domain" do
    first = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/hr/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(first, 201)

    second = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/hr/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(second, 409)
    JSON.parse(second.body)["error"].as_s.should contain("already exists")
  end

  # B-59: a present body that is not a JSON object must answer 422, not be
  # silently coerced to `{}` (which would create a draft nobody asked for).
  it "rejects with 422 when the draft body is not a JSON object (B-59)" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/draft",
      body: %("x"),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Body must be a JSON object (got string)")
  end
end

# ── B-240 gate helpers. Top-level private defs: this project's Crystal
#    rejects def declarations inside describe blocks. ──────────────────────

private def draft_from_request(source_id : String) : HTTP::Request
  HTTP::Request.new(
    "POST",
    "/Api/core/Domain/#{source_id}/draft",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
  )
end

# A role whose only permission is a scoped `create core.Domain` line — the
# intent-channel shape the seeded editor role carries on the definition
# surfaces.
private def scoped_create_ctx(account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "scoped-domain-create",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [
      Facet::RBAC::Permission.new(
        action: "create", domain: "core", path: ["Domain"],
        scope: ["$domain_editor"],
      ),
    ],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Same shape without the scope — the permission resolves to `All`.
private def all_create_ctx(account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "blanket-domain-create",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [
      Facet::RBAC::Permission.new(action: "create", domain: "core", path: ["Domain"]),
    ],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def grant_editorship(db, account_id : String, domain_id : String) : Nil
  Facet::Document::Create.call(
    db, "core", "DomainEditor",
    %({"account": "iam.Account.#{account_id}", "domain": "#{domain_id}"}),
    Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
end

# B-240 / F04-01: the draft-from-live route must require the caller to
# edit the source domain — a scoped grant does not widen it, and a blanket
# (All) `create core.Domain` grant does not skip it. The route enforcer
# passes `Scoped`/`All` (presence-only at create time), so the service gate
# (`Domain::Editors.authorize_draft_from?`) is the enforcement point.
describe "POST /Api/core/Domain/:id/draft — source-membership gate (B-240)" do
  before_each do
    with_db { |db| seed_live_domain_with_doctype(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  # The pinned principals must not leak into the next example — later
  # request-level specs run under the test-mode system default.
  after_each { Fiber.current.auth_context = nil }

  it "answers 201 for a scoped caller who edits the source domain" do
    with_db do |db|
      ensure_iam_account(db, "acc_member")
      grant_editorship(db, "acc_member", "hr")

      resp = call_api_as(draft_from_request("hr"), scoped_create_ctx("acc_member"))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["source_domain"].as_s.should eq("hr")
    end
  end

  it "answers 403 for a scoped caller who does not edit the source domain" do
    with_db do |db|
      ensure_iam_account(db, "acc_outsider")

      resp = call_api_as(draft_from_request("hr"), scoped_create_ctx("acc_outsider"))
      assert_http_status(resp, 403)
      JSON.parse(resp.body)["error"].as_s.should eq("Forbidden")
    end
  end

  it "answers 403 for an unrestricted (All) create caller without membership" do
    with_db do |db|
      ensure_iam_account(db, "acc_anyone")

      # The seeded editor role holds a blanket `create core.Domain`. That
      # must not let the caller fork a domain it does not edit (F04-01).
      resp = call_api_as(draft_from_request("hr"), all_create_ctx("acc_anyone"))
      assert_http_status(resp, 403)
      JSON.parse(resp.body)["error"].as_s.should eq("Forbidden")
    end
  end

  it "answers 201 for an unrestricted (All) create caller who edits the source domain" do
    with_db do |db|
      ensure_iam_account(db, "acc_anyone")
      grant_editorship(db, "acc_anyone", "hr")

      resp = call_api_as(draft_from_request("hr"), all_create_ctx("acc_anyone"))
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["data"]["source_domain"].as_s.should eq("hr")
    end
  end

  it "answers 201 for the system bypass" do
    resp = call_api_as(draft_from_request("hr"), Facet::RBAC::AuthContext.system)
    assert_http_status(resp, 201)
    JSON.parse(resp.body)["data"]["source_domain"].as_s.should eq("hr")
  end

  it "names the elected-role requirement when the route gate denies a caller without create core.Domain" do
    # The route's WriteEnforcer gate fires before the B-240 service gate:
    # the 403 body names the fix, not a bare Forbidden.
    resp = call_api_as(draft_from_request("hr"), Facet::RBAC::AuthContext.denied)
    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("domain creation requires an elected role")
  end
end

describe "POST /Api/core/Domain/draft — creation gate" do
  after_each { Fiber.current.auth_context = nil }

  it "names the elected-role requirement when the route gate denies a caller without create core.Domain" do
    resp = call_api_as(
      HTTP::Request.new("POST", "/Api/core/Domain/draft",
        headers: HTTP::Headers{"Content-Type" => "application/json"}, body: "{}"),
      Facet::RBAC::AuthContext.denied,
    )
    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should contain("domain creation requires an elected role")
  end
end

describe "POST /Api/core/Domain/:id/publish" do
  before_each do
    with_db { |db| seed_live_domain_with_doctype(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  it "publishes a draft into a fresh real-named domain" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %({"target_name": "orders"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 200)

    data = JSON.parse(resp.body)["data"].as_h
    data["domain"].as_s.should eq("orders")
    data["draft"].raw.should be_false

    # Target domain exists as a live (non-draft) core.Domain document.
    with_db do |db|
      target = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", "orders")
      target.content["draft"].raw.should be_false
    end
  end

  it "carries the selected doctype's documents and reports the count" do
    draft = create_draft_via_api
    with_db do |db|
      Facet::Mutation::Client.create(
        db, "core", "DocType",
        doc_id: "#{draft}.Status",
        content: %({"doctype": "Status", "domain": "#{draft}", "schema_version": 1, "fields": {"name": {"type": "string"}}}),
        meta: %({"parent_id": "#{draft}"}),
        actioner_id: "system:test",
      )
      Facet::Doctype::DefinitionStore.invalidate("#{draft}.Status")
      Facet::Mutation::Client.create(
        db, draft, "Status",
        doc_id: "#{draft}.Status.1",
        content: %({"name": "open"}),
        actioner_id: "system:test",
      )
    end

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %({"target_name": "orders", "documents": {"import": true, "doctypes": ["Status"]}}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 200)

    data = JSON.parse(resp.body)["data"].as_h
    data["documents_imported"].as_i.should eq(1)

    with_db do |db|
      row = Facet::Mutation::Client.fetch_projection(db, "orders", "Status", "orders.Status.1")
      row.content["name"].as_s.should eq("open")
    end
  end

  it "answers 422 for a documents selection naming a doctype the draft lacks" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %({"target_name": "orders", "documents": {"import": true, "doctypes": ["Nope"]}}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Nope")
  end

  it "answers 422 when documents is not an object" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %({"target_name": "orders", "documents": "yes"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("'documents' must be a JSON object")
  end

  it "rejects with 422 when the body lacks target_name" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("target_name")
  end

  # B-59: a body that parses but is not a JSON object used to escape as a
  # 500 Crystal type error on the `target_name` read; it must answer 422
  # like the sibling body-shape guards.
  it "rejects with 422 when the publish body is not a JSON object (B-59)" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %("x"),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Body must be a JSON object (got string)")

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %([1,2]),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Body must be a JSON object (got array)")
  end

  it "rejects with 409 when publishing over an existing domain without overwrite" do
    # `hr` already exists as a live domain (seeded by the helper). Draft from
    # it, then publish without `overwrite` → must 409.
    draft = with_db { |db| seed_draft_with_doctype_shape(db) }

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/publish",
      body: %({"target_name": "hr"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 409)
    JSON.parse(resp.body)["error"].as_s.should contain("already in use")
  end
end

describe "POST /Api/core/Domain/:id/publish with overwrite" do
  before_each do
    with_db { |db| seed_live_domain_with_doctype(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  it "publishes over an existing domain when structure is identical" do
    with_db do |db|
      draft = seed_draft_with_doctype_shape(db)

      resp = call_api(HTTP::Request.new(
        "POST",
        "/Api/core/Domain/#{draft}/publish",
        body: %({"target_name": "hr", "overwrite": true}),
        headers: HTTP::Headers{"Content-Type" => "application/json"},
      ))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"]["domain"].as_s.should eq("hr")
    end
  end

  it "rejects with 422 when structure changed and the migration entry is missing" do
    with_db do |db|
      draft = seed_draft_with_doctype_shape(
        db,
        draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
        draft_version: 2,
        # no migrations, no script
      )

      resp = call_api(HTTP::Request.new(
        "POST",
        "/Api/core/Domain/#{draft}/publish",
        body: %({"target_name": "hr", "overwrite": true}),
        headers: HTTP::Headers{"Content-Type" => "application/json"},
      ))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Migration from v1 to v2 is missing")
    end
  end

  it "rejects with 422 when structure changed but the version is not live + 1" do
    with_db do |db|
      draft = seed_draft_with_doctype_shape(
        db,
        draft_fields: %({"name": {"type": "string"}, "age": {"type": "integer"}}),
        draft_version: 1, # same as live — must be 2
      )

      resp = call_api(HTTP::Request.new(
        "POST",
        "/Api/core/Domain/#{draft}/publish",
        body: %({"target_name": "hr", "overwrite": true}),
        headers: HTTP::Headers{"Content-Type" => "application/json"},
      ))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("schema_version must be 2")
    end
  end
end
