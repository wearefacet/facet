# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"
require "../../src/rbac"
require "../../src/iam"

HTTPTest.init

# The B-86 repro role: account administration without definition read.
# File-private (the `metadata_` prefix keeps it out of the shared-def gate).
def metadata_role_ctx(db, account_id : String) : Facet::RBAC::AuthContext
  content = {
    "name"         => "hr_manager",
    "description"  => "Account administration without definition read.",
    "visible_tags" => ["default"],
    "permissions"  => [
      {"action" => "read", "on" => "iam.Account"},
      {"action" => "create", "on" => "iam.Account"},
      {"action" => "update", "on" => "iam.Account"},
      {"action" => "delete", "on" => "iam.Account"},
      {"action" => "read", "on" => "iam.Roles"},
      {"action" => "read", "on" => "iam.LoginEvent"},
    ],
  }.to_json
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.hr_manager",
    content: content,
    actioner_id: "system",
  )
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.hr_manager").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# The structural-metadata read gate (B-86).
#
# A scoped role with full CRUD on `iam.Account` and read on the other IAM
# doctypes — but no `read` line on `core.DocType` — resolves the definition
# registry and the domain list it needs to render its granted surfaces:
# the definition list serves the doctypes the role holds any grant on, the
# domain list the domains it holds grants inside, and a single definition
# read answers 200 for a granted target and a non-disclosing 404 otherwise.
# The row API itself is unaffected.
describe "HTTP structural metadata visibility" do
  before_each do
    with_db do |db|
      %w[iam.Account iam.LoginEvent].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  it "serves the granted definitions on the definition list" do
    ctx = with_db { |db| metadata_role_ctx(db, "01METAROLE001") }
    resp = call_api_as(HTTP::Request.new("GET", "/Api/core/DocType"), ctx)
    assert_http_status(resp, 200)

    ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
    ids.should contain("iam.Account")
    ids.should contain("iam.Roles")
    ids.should contain("iam.LoginEvent")
    # Doctypes the role holds no grant on stay absent — non-disclosing.
    ids.should_not contain("core.Currency")
    ids.should_not contain("app.App")
    ids.should_not contain("core.SystemSettings")
  end

  it "reads a granted definition and 404s an ungranted one" do
    ctx = with_db { |db| metadata_role_ctx(db, "01METAROLE002") }

    resp = call_api_as(HTTP::Request.new("GET", "/Api/core/DocType/iam.Account"), ctx)
    assert_http_status(resp, 200)

    resp = call_api_as(HTTP::Request.new("GET", "/Api/core/DocType/core.Currency"), ctx)
    assert_http_status(resp, 404)
  end

  it "serves the granted domains on the domain list" do
    ctx = with_db { |db| metadata_role_ctx(db, "01METAROLE003") }
    resp = call_api_as(HTTP::Request.new("GET", "/Api/core/Domain"), ctx)
    assert_http_status(resp, 200)

    ids = JSON.parse(resp.body)["data"].as_a.map(&.["meta"]["id"].as_s)
    ids.should contain("iam")
    ids.should_not contain("app")
    ids.should_not contain("core")
  end

  it "keeps the granted doctype's row API fully usable" do
    account_id = with_db do |db|
      ctx = metadata_role_ctx(db, "01METAROLE004")
      create_account_projection(db, "01METAACCOUNT", ["iam.Roles.hr_manager"])
      ctx
    end

    resp = call_api_as(HTTP::Request.new("GET", "/Api/iam/Account"), account_id)
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["count"].as_i.should be >= 1
    ids = body["data"].as_a.map(&.["meta"]["id"].as_s)
    ids.should contain("01METAACCOUNT")
  end
end
