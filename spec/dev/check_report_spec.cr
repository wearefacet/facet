# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "file_utils"
require "../../src/http/server"
require "../../src/dev/check_report"
require "../../src/domain/check"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Specs for the dev check-report surface: `Facet::Dev::CheckReport` (the
# in-process store the watcher feeds) and `GET /Api/dev/check-report`
# (the endpoint that serves it).
#
# The dev gate reads `Config.app_env` (the resolved `APP_ENV`), so the
# production-refusal example flips the variable directly — the test
# environment is not `production`, and the value is restored after the
# example. The store clears after every example; domains carry unique
# suffixes where tests could otherwise collide across workers.
#
# The endpoint requires a session: the endpoint examples log in a test
# account and carry the Bearer token, and a credential-less request
# answers 401 (B-343) — the anonymous principal never reads the report.
# The 401 comes from the route's own `require_account` gate; the
# `AuthHandler` stays disabled (the test default) so the production-refusal
# example keeps its 404 without a seeded anonymous role.

# ── Watcher helpers ─────────────────────────────────────────────────────────
# Prefixed `cr_`: `spec/dev/domain_watcher_spec.cr` defines the same harness
# under the plain names, and both spec files run in one binary.

def cr_watcher_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

def cr_watcher_seed_domain(db, domain, doctypes = ["Widget"])
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: %({"description": "watch #{domain}", "color": "#123456"}),
    actioner_id: "system:test",
  )
  doctypes.each do |doctype|
    Facet::Mutation::Client.create(
      db, "core", "DocType",
      doc_id: "#{domain}.#{doctype}",
      content: %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
      meta: %({"parent_id": "#{domain}"}),
      actioner_id: "system:test",
    )
  end
end

def cr_watcher_write_bundle(db, domain, root) : String
  result = Facet::Domain::Portable::Export.call(db, domain, with_documents: true)
  result = result.as(Facet::Domain::Portable::Export::Result)
  path = File.join(root, domain)
  Facet::Domain::Portable::Archive.write(result.bundle, path)
  path
end

def cr_watcher_build(root) : Facet::Dev::DomainWatcher
  Facet::Dev::DomainWatcher.new(
    Facet::Config::DomainWatchConfig.new(path: root, poll_ms: 100, documents: Facet::Config::DocumentsMode::Preserve),
  )
end

# One poll tick. Two ticks are the minimum for a child to cycle (debounce).
def cr_watcher_polls(watcher, times = 2) : Nil
  times.times { watcher.sync_now }
end

# Rewrites a bundle file. The watcher's fingerprint is content-addressed,
# so any content change is seen on the next poll — no mtime spacing needed.
def cr_watcher_touch_file(path : String, content : String) : Nil
  File.write(path, content)
end

def cr_watch_root(& : String ->) : Nil
  root = File.join(Dir.tempdir, "facet-dev-check-report-#{unique_suffix}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_r(root) if Dir.exists?(root)
  end
end

# ── Store specs ─────────────────────────────────────────────────────────────

describe "Facet::Dev::CheckReport (store)" do
  after_each do
    Facet::Dev::CheckReport.clear
  end

  it "stores a completed check result and serializes the inline check shape" do
    domain = "chk#{unique_suffix}"
    result = Facet::Domain::Check::Result.new(
      domain: domain,
      domain_issues: [Facet::Domain::Check::Issue.new(:warning, :hooks, nil, "Hook 'on_create' does not export the required symbol")],
      doctypes: [Facet::Domain::Check::DoctypeResult.new(
        doctype_id: "#{domain}.Widget",
        issues: [Facet::Domain::Check::Issue.new(:warning, :reference, "owner", "Reference field 'owner' targets doctype '#{domain}.Missing'")],
        notices: [Facet::Domain::Check::Issue.new(:info, :defaults, nil, "Default fields applied")],
      )],
    )

    Facet::Dev::CheckReport.record(result)

    report = Facet::Dev::CheckReport.fetch(domain).as(Facet::Dev::CheckReport::Report)
    report.issue_count.should eq(2)
    report.domain_issues.size.should eq(1)
    report.doctypes.size.should eq(1)
    report.doctypes[0].issues[0].category.should eq("reference")
    report.doctypes[0].notices[0].severity.should eq("info")

    parsed = JSON.parse(Facet::Dev::CheckReport.to_json(report))
    parsed["data"]["domain"].as_s.should eq(domain)
    parsed["data"]["issue_count"].as_i.should eq(2)
    parsed["data"]["domain_issues"][0]["category"].as_s.should eq("hooks")
    parsed["data"]["doctypes"][0]["doctype_id"].as_s.should eq("#{domain}.Widget")
    parsed["data"]["doctypes"][0]["issue_count"].as_i.should eq(1)
    parsed["data"]["doctypes"][0]["issues"][0]["field"].as_s.should eq("owner")
    parsed["data"]["doctypes"][0]["issues"][0]["message"].as_s.should contain("Missing")
    parsed["data"]["doctypes"][0]["notices"][0]["severity"].as_s.should eq("info")
    parsed["data"]["captured_at"].as_s.should_not be_empty
  end

  it "keeps a clean check as a zero-issue report" do
    domain = "chk#{unique_suffix}"
    Facet::Dev::CheckReport.record(
      Facet::Domain::Check::Result.new(domain: domain, domain_issues: [] of Facet::Domain::Check::Issue, doctypes: [] of Facet::Domain::Check::DoctypeResult),
    )

    report = Facet::Dev::CheckReport.fetch(domain).as(Facet::Dev::CheckReport::Report)
    report.issue_count.should eq(0)
  end

  it "drops the stored report on a failed check" do
    domain = "chk#{unique_suffix}"
    Facet::Dev::CheckReport.record(
      Facet::Domain::Check::Result.new(domain: domain, domain_issues: [] of Facet::Domain::Check::Issue, doctypes: [] of Facet::Domain::Check::DoctypeResult),
    )

    Facet::Dev::CheckReport.record_failure(domain)

    Facet::Dev::CheckReport.fetch(domain).should be_nil
  end

  it "stores an import-failure marker with the failing doctypes and details" do
    domain = "chk#{unique_suffix}"
    error = Facet::ServiceError.new(
      422,
      "#{domain}.Widget: schema validation failed",
      [Facet::ValidationError.new("schema_version must be >= 1 (got: 0)", code: "schema")],
    )

    Facet::Dev::CheckReport.record_import_failure(domain, error, ["#{domain}.Widget"])

    failure = Facet::Dev::CheckReport.fetch(domain).as(Facet::Dev::CheckReport::ImportFailure)
    failure.domain.should eq(domain)
    failure.status.should eq(422)
    failure.message.should contain("#{domain}.Widget: schema validation failed")
    failure.doctypes.should eq(["#{domain}.Widget"])
    failure.details.size.should eq(1)
    failure.details[0].code.should eq("schema")
    failure.captured_at.should_not be_nil

    parsed = JSON.parse(Facet::Dev::CheckReport.to_json(failure))
    parsed["data"]["kind"].as_s.should eq("import_failure")
    parsed["data"]["domain"].as_s.should eq(domain)
    parsed["data"]["captured_at"].as_s.should_not be_empty
    parsed["data"]["status"].as_i.should eq(422)
    parsed["data"]["message"].as_s.should contain("schema validation failed")
    parsed["data"]["doctypes"][0].as_s.should eq("#{domain}.Widget")
    parsed["data"]["details"][0]["message"].as_s.should contain("schema_version must be >= 1")
    parsed["data"]["details"][0]["code"].as_s.should eq("schema")
  end

  it "stores no doctype on an import failure that names none" do
    domain = "chk#{unique_suffix}"
    error = Facet::ServiceError.new(422, "core.Domain '#{domain}': RBAC context set validation failed")

    Facet::Dev::CheckReport.record_import_failure(domain, error, [] of String)

    failure = Facet::Dev::CheckReport.fetch(domain).as(Facet::Dev::CheckReport::ImportFailure)
    failure.doctypes.should be_empty
    failure.details.should be_empty
  end

  it "overwrites a stored import-failure marker when a check completes" do
    domain = "chk#{unique_suffix}"
    error = Facet::ServiceError.new(422, "#{domain}.Widget: schema validation failed")
    Facet::Dev::CheckReport.record_import_failure(domain, error, ["#{domain}.Widget"])

    Facet::Dev::CheckReport.record(
      Facet::Domain::Check::Result.new(domain: domain, domain_issues: [] of Facet::Domain::Check::Issue, doctypes: [] of Facet::Domain::Check::DoctypeResult),
    )

    report = Facet::Dev::CheckReport.fetch(domain).as(Facet::Dev::CheckReport::Report)
    report.issue_count.should eq(0)
  end

  it "drops a stored import-failure marker on a failed check" do
    domain = "chk#{unique_suffix}"
    error = Facet::ServiceError.new(422, "#{domain}.Widget: schema validation failed")
    Facet::Dev::CheckReport.record_import_failure(domain, error, ["#{domain}.Widget"])

    Facet::Dev::CheckReport.record_failure(domain)

    Facet::Dev::CheckReport.fetch(domain).should be_nil
  end
end

# ── Endpoint specs ──────────────────────────────────────────────────────────

describe "GET /Api/dev/check-report" do
  around_each do |example|
    redis_cleanup
    begin
      example.run
    ensure
      redis_cleanup
    end
  end

  before_each do
    with_db { |db| seed_iam_doctypes(db) }
  end

  after_each do
    Facet::Dev::CheckReport.clear
  end

  it "answers 401 for a credential-less request in dev (B-343)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report?domain=whatever"))
    assert_http_status(resp, 401)
  end

  it "answers 404 when no check has run for the domain" do
    with_db do |db|
      create_test_account(db, email: "cr404@example.com", password: "pw-pw-pw")
    end
    token = login_token("cr404@example.com", "pw-pw-pw")

    resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report?domain=never_checked",
      headers: bearer_headers(token)))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("No check report")
  end

  it "answers 422 when the domain query parameter is missing" do
    with_db do |db|
      create_test_account(db, email: "cr422@example.com", password: "pw-pw-pw")
    end
    token = login_token("cr422@example.com", "pw-pw-pw")

    resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report",
      headers: bearer_headers(token)))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("domain")
  end

  it "serves a stored report in the inline check shape" do
    with_db do |db|
      create_test_account(db, email: "cr200@example.com", password: "pw-pw-pw")
    end
    token = login_token("cr200@example.com", "pw-pw-pw")

    domain = "chk#{unique_suffix}"
    Facet::Dev::CheckReport.record(
      Facet::Domain::Check::Result.new(
        domain: domain,
        domain_issues: [Facet::Domain::Check::Issue.new(:warning, :no_doctypes, nil, "Domain '#{domain}' has no registered doctypes")],
        doctypes: [] of Facet::Domain::Check::DoctypeResult,
      ),
    )

    resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report?domain=#{domain}",
      headers: bearer_headers(token)))
    assert_http_status(resp, 200)
    parsed = JSON.parse(resp.body)
    parsed["data"]["domain"].as_s.should eq(domain)
    parsed["data"]["issue_count"].as_i.should eq(1)
    parsed["data"]["domain_issues"][0]["category"].as_s.should eq("no_doctypes")
    parsed["data"]["doctypes"].as_a.should be_empty
  end

  it "serves a stored import-failure marker" do
    with_db do |db|
      create_test_account(db, email: "crfail@example.com", password: "pw-pw-pw")
    end
    token = login_token("crfail@example.com", "pw-pw-pw")

    domain = "chk#{unique_suffix}"
    error = Facet::ServiceError.new(
      422,
      "#{domain}.Widget: schema validation failed",
      [Facet::ValidationError.new("doctype 'widget' must be CamelCase alphanumeric and cannot start with a digit", code: "schema")],
    )
    Facet::Dev::CheckReport.record_import_failure(domain, error, ["#{domain}.Widget"])

    resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report?domain=#{domain}",
      headers: bearer_headers(token)))
    assert_http_status(resp, 200)
    parsed = JSON.parse(resp.body)
    parsed["data"]["kind"].as_s.should eq("import_failure")
    parsed["data"]["domain"].as_s.should eq(domain)
    parsed["data"]["status"].as_i.should eq(422)
    parsed["data"]["message"].as_s.should contain("#{domain}.Widget: schema validation failed")
    parsed["data"]["doctypes"][0].as_s.should eq("#{domain}.Widget")
    parsed["data"]["details"][0]["code"].as_s.should eq("schema")
  end

  it "answers 404 when the environment is production (dev gate)" do
    previous = ENV["APP_ENV"]?
    ENV["APP_ENV"] = "production"
    begin
      resp = call_api(HTTP::Request.new("GET", "/Api/dev/check-report?domain=whatever"))
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should eq("Not found")
    ensure
      if previous
        ENV["APP_ENV"] = previous
      else
        ENV.delete("APP_ENV")
      end
    end
  end
end

# ── Watcher integration ─────────────────────────────────────────────────────

describe "DomainWatcher check-report integration" do
  after_each do
    Facet::Dev::CheckReport.clear
  end

  it "stores the report after a sync cycle with issues" do
    cr_watch_root do |root|
      Facet::Database.with_db do |db|
        cr_watcher_reseed_core(db)
        cr_watcher_seed_domain(db, "achk")
        a_path = cr_watcher_write_bundle(db, "achk", root)
        Facet::Domain::Scratch.dispose!(db, "achk")

        # A reference field whose target is not a registered doctype — the
        # import succeeds and the check reports the reference warning.
        cr_watcher_touch_file(File.join(a_path, "doctypes", "achk.Widget.yml"),
          "content:\n  doctype: Widget\n  domain: achk\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n    owner:\n      doctype: achk.Missing\nmeta:\n  parent_id: achk\n")

        watcher = cr_watcher_build(root)
        cr_watcher_polls(watcher)

        report = Facet::Dev::CheckReport.fetch("achk").as(Facet::Dev::CheckReport::Report)
        report.issue_count.should be > 0
        report.doctypes.any?(&.issues.any?(&.message.includes?("achk.Missing"))).should be_true
      end
    end
  end

  it "replaces a stale report with the latest completed check" do
    cr_watch_root do |root|
      Facet::Database.with_db do |db|
        cr_watcher_reseed_core(db)
        cr_watcher_seed_domain(db, "achk2")
        a_path = cr_watcher_write_bundle(db, "achk2", root)
        Facet::Domain::Scratch.dispose!(db, "achk2")

        # A reference field whose target is not a registered doctype — the
        # import succeeds and the check reports the reference warning.
        cr_watcher_touch_file(File.join(a_path, "doctypes", "achk2.Widget.yml"),
          "content:\n  doctype: Widget\n  domain: achk2\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n    owner:\n      doctype: achk2.Missing\nmeta:\n  parent_id: achk2\n")

        watcher = cr_watcher_build(root)
        cr_watcher_polls(watcher)
        first = Facet::Dev::CheckReport.fetch("achk2").as(Facet::Dev::CheckReport::Report)
        first.issue_count.should be > 0

        # Repair the bundle: drop the stale field, so the next cycle's
        # check is clean and the stored report replaces the stale one.
        cr_watcher_touch_file(File.join(a_path, "doctypes", "achk2.Widget.yml"),
          "content:\n  doctype: Widget\n  domain: achk2\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\nmeta:\n  parent_id: achk2\n")
        cr_watcher_polls(watcher)

        latest = Facet::Dev::CheckReport.fetch("achk2").as(Facet::Dev::CheckReport::Report)
        latest.captured_at.should be >= first.captured_at
        # The repair removed the only issue, so the fresh report replaced
        # the stale one instead of accumulating onto it.
        latest.issue_count.should eq(0)
        latest.doctypes.any?(&.issues.any?(&.message.includes?("achk2.Missing"))).should be_false
      end
    end
  end
end
