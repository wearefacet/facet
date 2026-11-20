# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-208 — the domain-import route runs the write gate BEFORE the body
# spool and the archive-magic check when `into` names the target. A
# caller without the write permission must not be able to probe the
# bundle-format contract. A bundle-derived target (no `into`) keeps the
# parse-first order — the gate needs the parsed bundle to name the
# target — and still answers `403` with nothing staged.

require "../../spec_helper"
require "json"
require "../../../src/jobs"
require "../../../src/http/server"
require "../../../src/domain/portable"
require "../../support/http_helper"

HTTPTest.init

private def igo_reseed_core(db) : Nil
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# A small live domain with one doctype — enough for a real bundle.
private def igo_seed_domain(db, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"description": "gate order #{name}"}),
    actioner_id: "system:test",
  )

  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{name}.Widget",
    content: %({
      "doctype": "Widget",
      "domain": "#{name}",
      "schema_version": 1,
      "fields": {"name": {"type": "string"}}
    }),
    meta: %({"parent_id": "#{name}"}),
    actioner_id: "system:test",
  )
end

private def igo_bundle_zip(db, name : String) : Bytes
  result = Facet::Domain::Portable::Export.call(db, name, with_documents: false)
  result.should be_a(Facet::Domain::Portable::Export::Result)
  bundle = result.as(Facet::Domain::Portable::Export::Result).bundle
  path = File.tempname("igo-bundle", ".zip")
  Facet::Domain::Portable::Archive.write(bundle, path)
  bytes = File.read(path).to_slice
  File.delete?(path)
  bytes
end

# The import enqueue route reads the jobs manager when it stages a run;
# a clerk only ever reaches the gates, but the instance must exist.
private def igo_install_manager : Nil
  Facet::Jobs::Manager.instance = Facet::Jobs::Manager.new(handlers: {
    Facet::Domain::Portable::ExportJob::KIND => Facet::Domain::Portable::ExportJob,
    Facet::Domain::Portable::ImportJob::KIND => Facet::Domain::Portable::ImportJob,
  } of String => Facet::Jobs::Handler.class)
end

# A clerk: can read the domain registry, holds no `core.Domain` write.
private def igo_clerk : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated(
    "iam.Account.igoclerk",
    rbac_role([rbac_perm("read", "core.Domain")], "igo_clerk_role"),
  )
end

private def igo_import(bytes : Bytes | String, query : String, auth : Facet::RBAC::AuthContext) : HTTP::Client::Response
  suffix = query.empty? ? "" : "?#{query}"
  request = HTTP::Request.new(
    "POST",
    "/Api/core/Domain/import#{suffix}",
    HTTP::Headers{"Content-Type" => "application/zip", "X-Requested-With" => "XMLHttpRequest"},
    body: bytes,
  )
  # Raw dispatch: the request owns the CSRF header.
  call_api_raw_as(request, auth)
end

describe "Domain import gate order (B-208)" do
  it "answers 403 before the format contract when into names the target" do
    igo_install_manager
    with_db do |db|
      igo_reseed_core(db)
      igo_seed_domain(db, "igosrc")

      resp = igo_import("this is not an archive", "into=igotgt", igo_clerk)
      resp.status_code.should eq(403)
      JSON.parse(resp.body)["error"].as_s.should eq("Forbidden")
    end
  end

  it "answers 422 for a junk body when the target is bundle-derived" do
    igo_install_manager
    with_db do |db|
      igo_reseed_core(db)
      igo_seed_domain(db, "igosrc2")

      resp = igo_import("this is not an archive", "", igo_clerk)
      resp.status_code.should eq(422)
      JSON.parse(resp.body)["error"].as_s.should contain("zip or tar.gz")
    end
  end

  it "a valid bundle without the grant answers 403 and stages nothing" do
    igo_install_manager
    with_db do |db|
      igo_reseed_core(db)
      igo_seed_domain(db, "igosrc3")
      bytes = igo_bundle_zip(db, "igosrc3")

      resp = igo_import(bytes, "", igo_clerk)
      resp.status_code.should eq(403)
      JSON.parse(resp.body)["error"].as_s.should eq("Forbidden")

      # Nothing staged for THIS import — scoped to the rows the run would
      # have created, so the assertion stays order-independent when other
      # specs have legitimately enqueued their own jobs / artifacts.
      jobs = db.query_one("SELECT COUNT(*) FROM background_jobs WHERE kind = 'domain_import' AND payload->>'source_domain' = 'igosrc3'", as: Int64)
      jobs.should eq(0)
      artifacts = db.query_one("SELECT COUNT(*) FROM artifacts WHERE filename = 'igosrc3.facet-domain.zip'", as: Int64)
      artifacts.should eq(0)
    end
  end
end
