# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../support/migration_fixtures"
require "../../src/jobs/job"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# Specs for the maintenance job handlers (`ReprojectJob`,
# `AheadMigrationJob`). The handlers run through `execute` with a
# fabricated `Jobs::Job` row — the worker's outcome write is exercised by
# the jobs subsystem specs, not here. Each spec seeds a real doctype and
# corpus and asserts on the returned `Result` and the stored state.

# Builds a minimal `Jobs::Job` row for *kind* with *payload*.
def maintenance_job(kind : String, payload : String) : Facet::Jobs::Job
  Facet::Jobs::Job.new(
    id: Facet::Util::ScriptHelpers.ulid,
    kind: kind,
    payload: JSON.parse(payload),
    attempts: 1,
    max_attempts: 1,
    backoff: nil,
  )
end

# The payload the maintenance routes build: coordinates plus the
# requester's identity.
def maintenance_payload(domain : String, dt : String) : String
  %({"domain": "#{domain}", "doc_type": "#{dt}", "account_id": "system"})
end

# Reads the `schema_version` stored on one projection row.
def stored_version(db, domain, dt, id) : Int32
  db.query_one(
    "SELECT (meta->>'schema_version')::int FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
    domain, dt, id, as: Int32)
end

# Reads the `search` column of one projection row.
def stored_search(db, id) : String?
  db.query_one("SELECT search FROM projections WHERE id = $1", id, as: String?)
end

module Facet::Doctype
  describe ReprojectJob do
    it "re-projects the derived columns and reports the stats" do
      with_temp_doctype("reprojjob") do |db, domain, dt|
        ensure_domain(db, domain)
        create_schema = %({
          "doctype": "#{dt}", "domain": "#{domain}",
          "display_name": "{{ name }}",
          "search": "{{ name }}",
          "fields": {"name": {"type": "string"}}
        })
        Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Create::Result)

        r = Facet::Document::Create.call(db, domain, dt, %({"name": "Acme"}), Facet::RBAC::AuthContext.system)
        id = r.as(Facet::Document::Create::Result).projection.id
        db.exec("UPDATE projections SET search = 'POISONED' WHERE id = $1", id)

        result = ReprojectJob.new.execute(maintenance_job(ReprojectJob::KIND, maintenance_payload(domain, dt)))

        result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
        result.error.should be_nil
        stats = result.result.not_nil!
        stats["total"].as_i.should eq(1)
        stats["processed"].as_i.should eq(1)
        stats["failed"].as_i.should eq(0)
        stored_search(db, id).should eq("acme")
      end
    end

    it "answers a Failed result for an unknown doctype" do
      domain = "ghost"
      dt = "Missing#{unique_suffix(6)}"
      ghost = "#{domain}.#{dt}"
      result = ReprojectJob.new.execute(maintenance_job(ReprojectJob::KIND, maintenance_payload(domain, dt)))
      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain(ghost)
    end
  end

  describe AheadMigrationJob do
    it "migrates the corpus and reports the stats" do
      with_temp_doctype("aheadjob") do |db, domain, dt|
        ids = seed_v1_documents(db, domain, dt, 2)
        bump_to_v2_working(db, domain, dt)

        result = AheadMigrationJob.new.execute(maintenance_job(AheadMigrationJob::KIND, maintenance_payload(domain, dt)))

        result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
        stats = result.result.not_nil!
        stats["total"].as_i.should eq(2)
        stats["migrated"].as_i.should eq(2)
        stats["failed"].as_i.should eq(0)
        ids.each { |id| stored_version(db, domain, dt, id).should eq(2) }
      end
    end

    it "succeeds with the failure stats when rows still fail" do
      with_temp_doctype("aheadjob2") do |db, domain, dt|
        seed_v1_documents(db, domain, dt, 1)
        bump_to_v2(db, domain, dt)

        result = AheadMigrationJob.new.execute(maintenance_job(AheadMigrationJob::KIND, maintenance_payload(domain, dt)))

        # A failing row is an expected outcome of the run, not a job
        # failure — the run completed and the operator reads the stats.
        result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
        stats = result.result.not_nil!
        stats["migrated"].as_i.should eq(0)
        stats["failed"].as_i.should eq(1)
        stats["failed_ids"].as_a.size.should eq(1)
        stored_version(db, domain, dt, stats["failed_ids"].as_a.first.as_s).should eq(1)
      end
    end

    it "answers a Failed result for an unknown doctype" do
      result = AheadMigrationJob.new.execute(maintenance_job(AheadMigrationJob::KIND, maintenance_payload("ghost", "Missing#{unique_suffix(6)}")))
      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.should_not be_nil
    end
  end
end
