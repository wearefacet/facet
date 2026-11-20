# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

require "../../../src/domain/portable"
require "../../../src/import_export/job_outcome"
require "../../../src/event"

# Specs for the `domain_export` / `domain_import` background handlers: the
# packaging (zip artifact), the execution-time gates, the expected-vs-crash
# failure classification, and the terminal result payloads.
#
# The routes are covered by `http_routes_spec.cr`; the portable services
# themselves by `import_export_spec.cr`.

private def portable_job_reseed_core(db) : Nil
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

private def portable_job_seed_domain(db, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "job test #{name}", "color": "amber"}),
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

private def portable_job_export_payload(domain : String, account_id : String = "iam.Account.owner") : JSON::Any
  payload = {
    "domain"     => JSON::Any.new(domain),
    "account_id" => JSON::Any.new(account_id),
    "role_id"    => JSON::Any.new("iam.Roles.admin"),
  } of String => JSON::Any
  JSON.parse(payload.to_json)
end

private def portable_job_insert_export(db, payload : JSON::Any) : String
  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Domain::Portable::ExportJob::KIND, payload,
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

private def portable_job_import_payload(
  db,
  source : String,
  account_id : String = "iam.Account.owner",
  into : String? = nil,
  merge : Bool = false,
) : JSON::Any
  bundle = portable_job_bundle(db, source)
  path = File.tempname("spec-job-bundle", ".zip")
  Facet::Domain::Portable::Archive.write(bundle, path)
  # Fixture staging has no requester — a system context keeps the bundle
  # ownerless; the import job reads it by id, never by provenance.
  artifact = Facet::ImportExport::Artifacts.put(db, File.open(path, "rb"), "spec.zip", "application/zip", Facet::RBAC::AuthContext.system)
  File.delete?(path)

  payload = {
    "bundle_artifact_id" => JSON::Any.new(artifact.artifact_id),
    "source_domain"      => JSON::Any.new(source),
    "into"               => JSON::Any.new(into),
    "merge"              => JSON::Any.new(merge),
    "account_id"         => JSON::Any.new(account_id),
    "role_id"            => JSON::Any.new("iam.Roles.admin"),
  } of String => JSON::Any
  JSON.parse(payload.to_json)
end

# Builds an in-memory bundle from the named live domain.
private def portable_job_bundle(db, source : String) : Facet::Domain::Portable::Archive::Bundle
  result = Facet::Domain::Portable::Export.call(db, source)
  result.should be_a(Facet::Domain::Portable::Export::Result)
  result.as(Facet::Domain::Portable::Export::Result).bundle
end

private def portable_job_insert_import(db, payload : JSON::Any) : String
  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Domain::Portable::ImportJob::KIND, payload,
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# Claims one row and runs the real handler — no worker fiber.
private def portable_job_execute(db, job_id : String) : Facet::Jobs::Handler::Result
  claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
  job = claimed.find! { |j| j.id == job_id }
  case job.kind
  when Facet::Domain::Portable::ExportJob::KIND
    Facet::Domain::Portable::ExportJob.new.execute(job)
  else
    Facet::Domain::Portable::ImportJob.new.execute(job)
  end
end

private def admin_auth(account_id : String = "iam.Account.owner") : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(account_id, rbac_role([rbac_perm("*", "*.*")], "admin"))
end

private def reader_only_auth(account_id : String = "iam.Account.reader") : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(account_id, rbac_role([rbac_perm("read", "core.Domain")], "reader"))
end

describe Facet::Domain::Portable::ExportJob do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))
  end

  it "packages the bundle as a zip artifact and records the counts" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobexp")

      job_id = portable_job_insert_export(db, portable_job_export_payload("jobexp"))
      result = portable_job_execute(db, job_id)

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      payload = result.result.not_nil!
      artifact_id = payload["artifact_id"].as_s
      payload["doctype_count"].as_i.should eq(1)
      payload["format"].as_s.should eq("zip")

      artifact = Facet::Artifact::Store.find_artifact(db, artifact_id).not_nil!
      artifact.mime_type.should eq("application/zip")
      header = Bytes.new(4)
      io = Facet::Artifact::Uploader.open(artifact.path)
      begin
        io.read_fully?(header)
      ensure
        io.close
      end
      header.hexstring.should eq("504b0304")
    end
  end

  it "notifies the requesting account with the domain document as doc_ref" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobnotif")
      ensure_iam_account(db, "iam.Account.owner")

      job_id = portable_job_insert_export(db, portable_job_export_payload("jobnotif"))
      portable_job_execute(db, job_id)

      rows = db.query_all(
        "SELECT title, data, domain, doc_type, doc_id FROM notifications " \
        "WHERE account_id = $1 AND kind = $2",
        "iam.Account.owner", "domain_export_completed",
        as: {String, JSON::Any, String, String, String},
      )
      rows.size.should eq(1)
      title, data, n_domain, n_doc_type, n_doc_id = rows[0]
      n_domain.should eq("core")
      n_doc_type.should eq("Domain")
      n_doc_id.should eq("jobnotif")
      data["download"].as_s.should eq("/Api/core/Domain/import_export/#{job_id}/download")
      title.should eq("Domain export ready")
    end
  end

  it "fails expected for a draft domain" do
    with_db do |db|
      portable_job_reseed_core(db)
      Facet::Mutation::Client.create(
        db, "core", "Domain",
        doc_id: "jobdraft",
        content: %({"draft": true}),
        actioner_id: "system:test",
      )

      job_id = portable_job_insert_export(db, portable_job_export_payload("jobdraft"))
      result = portable_job_execute(db, job_id)

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("draft")
      result.result.not_nil!["expected"].as_bool.should be_true
    end
  end

  it "fails expected when the caller lost read access by execution time" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobdenied")

      # The payload pins a role that cannot read `core.Domain` — the
      # execution-time gate denies the export.
      payload = {
        "domain"     => JSON::Any.new("jobdenied"),
        "account_id" => JSON::Any.new("iam.Account.restricted"),
        "role_id"    => JSON::Any.new("iam.Roles.anonymous"),
      } of String => JSON::Any
      job_id = portable_job_insert_export(db, JSON.parse(payload.to_json))
      result = portable_job_execute(db, job_id)

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("Not authorized")
      result.result.not_nil!["expected"].as_bool.should be_true
    end
  end
end

describe Facet::Domain::Portable::ImportJob do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))
  end

  it "creates the target domain from a definition-only bundle" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobimp")

      job_id = portable_job_insert_import(db, portable_job_import_payload(db, "jobimp", into: "jobnew"))
      result = portable_job_execute(db, job_id)

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      report = result.result.not_nil!
      report["domain"].as_s.should eq("jobnew")
      report["created"].as_bool.should be_true
      report["doctypes_created"].as_i.should eq(1)
      report["documents_created"].as_i.should eq(0)

      exists = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'jobnew' " \
        "AND deleted_at IS NULL", as: Int32)
      exists.should_not be_nil
    end
  end

  it "notifies the requesting account with the target domain document as doc_ref" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobimpnot")
      ensure_iam_account(db, "iam.Account.owner")

      job_id = portable_job_insert_import(db, portable_job_import_payload(db, "jobimpnot", into: "jobimpnew"))
      portable_job_execute(db, job_id)

      rows = db.query_all(
        "SELECT title, domain, doc_type, doc_id FROM notifications " \
        "WHERE account_id = $1 AND kind = $2",
        "iam.Account.owner", "domain_import_completed",
        as: {String, String, String, String},
      )
      rows.size.should eq(1)
      title, n_domain, n_doc_type, n_doc_id = rows[0]
      n_domain.should eq("core")
      n_doc_type.should eq("Domain")
      n_doc_id.should eq("jobimpnew")
      title.should eq("Domain import ready")
    end
  end

  it "fails expected for a bundle carrying document data" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobdocsrc")
      Facet::Mutation::Client.create(
        db, "jobdocsrc", "Widget",
        doc_id: "jobdocsrc.Widget.1",
        content: %({"name": "one"}),
        actioner_id: "system:test",
      )

      result = Facet::Domain::Portable::Export.call(db, "jobdocsrc", with_documents: true)
      result.should be_a(Facet::Domain::Portable::Export::Result)
      bundle = result.as(Facet::Domain::Portable::Export::Result).bundle
      bundle.documents.size.should be > 0

      path = File.tempname("spec-docs-bundle", ".zip")
      Facet::Domain::Portable::Archive.write(bundle, path)
      artifact = Facet::ImportExport::Artifacts.put(db, File.open(path, "rb"), "docs.zip", "application/zip", Facet::RBAC::AuthContext.system)
      File.delete?(path)

      payload = {
        "bundle_artifact_id" => JSON::Any.new(artifact.artifact_id),
        "source_domain"      => JSON::Any.new("jobdocsrc"),
        "into"               => JSON::Any.new("jobdocnew"),
        "merge"              => JSON::Any.new(false),
        "account_id"         => JSON::Any.new("iam.Account.owner"),
        "role_id"            => JSON::Any.new("iam.Roles.admin"),
      } of String => JSON::Any
      job_id = portable_job_insert_import(db, JSON.parse(payload.to_json))
      job_result = portable_job_execute(db, job_id)

      job_result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      job_result.error.not_nil!.should contain("definition-only")
      job_result.result.not_nil!["expected"].as_bool.should be_true
    end
  end

  it "fails expected for a version-gate rejection on merge" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobmerge")

      # Import once to land the target...
      first = portable_job_insert_import(db, portable_job_import_payload(db, "jobmerge", into: "jobmerge", merge: true))
      portable_job_execute(db, first).status.should eq(Facet::Jobs::Handler::Kind::Succeeded)

      # ...then submit a tampered bundle: the doctype's field type
      # changed at the same schema_version — a gate rejection.
      exported = Facet::Domain::Portable::Export.call(db, "jobmerge")
      exported.should be_a(Facet::Domain::Portable::Export::Result)
      source_bundle = exported.as(Facet::Domain::Portable::Export::Result).bundle

      entry = source_bundle.doctypes[0]
      tampered = JSON.parse(entry[:entry].content.to_json)
      tampered.as_h["fields"].as_h["name"].as_h["type"] = JSON::Any.new("integer")
      tampered_bundle = Facet::Domain::Portable::Archive::Bundle.new(
        source_bundle.source_domain,
        source_bundle.exported_at,
        source_bundle.facet_version,
        source_bundle.domain,
        [{doctype: entry[:doctype], entry: Facet::Domain::Portable::Archive::Entry.new(tampered, entry[:entry].meta)}],
        source_bundle.document_views,
        source_bundle.collection_views,
      )

      path = File.tempname("spec-gate-bundle", ".zip")
      Facet::Domain::Portable::Archive.write(tampered_bundle, path)
      artifact = Facet::ImportExport::Artifacts.put(db, File.open(path, "rb"), "gate.zip", "application/zip", Facet::RBAC::AuthContext.system)
      File.delete?(path)

      payload = {
        "bundle_artifact_id" => JSON::Any.new(artifact.artifact_id),
        "source_domain"      => JSON::Any.new("jobmerge"),
        "into"               => JSON::Any.new("jobmerge"),
        "merge"              => JSON::Any.new(true),
        "account_id"         => JSON::Any.new("iam.Account.owner"),
        "role_id"            => JSON::Any.new("iam.Roles.admin"),
      } of String => JSON::Any
      second = portable_job_insert_import(db, JSON.parse(payload.to_json))
      result = portable_job_execute(db, second)

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("jobmerge.Widget")
      result.result.not_nil!["expected"].as_bool.should be_true
    end
  end

  it "fails expected when the caller lacks write access by execution time" do
    with_db do |db|
      portable_job_reseed_core(db)
      portable_job_seed_domain(db, "jobgate")

      # The payload pins a role that cannot create or update
      # `core.Domain` — the execution-time gate denies the import, and
      # nothing lands.
      bundle = portable_job_bundle(db, "jobgate")
      path = File.tempname("spec-gate-bundle", ".zip")
      Facet::Domain::Portable::Archive.write(bundle, path)
      artifact = Facet::ImportExport::Artifacts.put(db, File.open(path, "rb"), "gate.zip", "application/zip", Facet::RBAC::AuthContext.system)
      File.delete?(path)

      payload = {
        "bundle_artifact_id" => JSON::Any.new(artifact.artifact_id),
        "source_domain"      => JSON::Any.new("jobgate"),
        "into"               => JSON::Any.new("jobgatetgt"),
        "merge"              => JSON::Any.new(false),
        "account_id"         => JSON::Any.new("iam.Account.restricted"),
        "role_id"            => JSON::Any.new("iam.Roles.anonymous"),
      } of String => JSON::Any
      job_id = portable_job_insert_import(db, JSON.parse(payload.to_json))

      result = portable_job_execute(db, job_id)
      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("Not authorized")
      result.result.not_nil!["expected"].as_bool.should be_true

      exists = db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'jobgatetgt'", as: Int32)
      exists.should be_nil
    end
  end
end
