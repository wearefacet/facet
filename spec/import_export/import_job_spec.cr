# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/rbac"
require "../../src/document"
require "../../src/notifications"
require "../../src/import_export/import"
require "../../src/import_export/import_job"

# ── Spec helpers ─────────────────────────────────────────────────────────────

private def create_jimp_doctype(db : DB::Connection, domain : String, doctype : String, fields : String) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_jimp_doc(db : DB::Connection, domain : String, doctype : String, content : String) : String
  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

# Stores the raw file and the positional manifest as ownerless artifacts,
# exactly what the enqueue route stages, and enqueues one pending
# `document_import` row carrying their ids.
private def enqueue_import_job(
  db : DB::Connection,
  domain : String,
  doctype : String,
  format : String,
  account_id : String,
  file_text : String,
  role_id : String? = nil,
) : String
  mime = format == "csv" ? "text/csv" : "application/json"
  # Fixture staging has no requester — a system context keeps the staged
  # file and manifest ownerless; the import job reads them by id.
  file_artifact = Facet::ImportExport::Artifacts.put(db, IO::Memory.new(file_text), "#{domain}.#{doctype}.#{format}", mime, Facet::RBAC::AuthContext.system)
  ids, supplied = staging_manifest(file_text, format)
  manifest_artifact = Facet::ImportExport::Artifacts.put(
    db, IO::Memory.new({"ids" => ids, "supplied" => supplied}.to_json), "#{domain}.#{doctype}.manifest.json", "application/json", Facet::RBAC::AuthContext.system)

  payload = {
    "domain"               => JSON::Any.new(domain),
    "doc_type"             => JSON::Any.new(doctype),
    "format"               => JSON::Any.new(format),
    "account_id"           => JSON::Any.new(account_id),
    "file_artifact_id"     => JSON::Any.new(file_artifact.artifact_id),
    "manifest_artifact_id" => JSON::Any.new(manifest_artifact.artifact_id),
  } of String => JSON::Any
  payload["role_id"] = JSON::Any.new(role_id) if role_id

  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Document::ImportJob::KIND, JSON.parse(payload.to_json),
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# Mirrors the route's structural parse spec-side: one id per data row
# (the file's id, a generated ULID when absent) with the supplied flag
# recording whether the row carried the id itself.
private def staging_manifest(file_text : String, format : String) : {Array(String), Array(Bool)}
  ids = [] of String
  supplied = [] of Bool
  if format == "csv"
    parsed = CSV.parse(file_text)
    headers = parsed[0]
    id_index = headers.index("id")
    parsed[1..].each do |cells|
      raw = id_index ? cells[id_index]? : ""
      has_id = !raw.to_s.empty?
      ids << (has_id ? raw.to_s : Facet::Util::ScriptHelpers.ulid)
      supplied << has_id
    end
  else
    JSON.parse(file_text).as_a.each do |el|
      raw = el["id"]?.try(&.as_s?)
      has_id = !(raw.nil? || raw.empty?)
      ids << (has_id ? raw.as(String) : Facet::Util::ScriptHelpers.ulid)
      supplied << has_id
    end
  end
  {ids, supplied}
end

# Claims the row and records the outcome the way the worker does — the
# handler never touches its own row.
private def run_import_job(db : DB::Connection, job_id : String) : Facet::Jobs::Handler::Result
  claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
  job = claimed.find! { |j| j.id == job_id }
  result = Facet::Document::ImportJob.new.execute(job)
  case result.status
  in .succeeded?
    Facet::Jobs::Queries.write_succeeded(db, job.id, http_status: result.http_status, result: result.result)
  in .failed?
    Facet::Jobs::Queries.write_failed(db, job.id, error: result.error, http_status: result.http_status, backoff_seconds: job.backoff, result: result.result)
  end
  result
end

private def jimp_outcome(db : DB::Connection, job_id : String) : Facet::Jobs::Queries::Outcome
  Facet::Jobs::Queries.find_outcome(db, job_id).not_nil!
end

private def jimp_doc_exists(db : DB::Connection, domain : String, doctype : String, id : String) : Bool
  !db.query_one?("SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
    domain, doctype, id, as: Int32).nil?
end

private def jimp_notification_rows(db : DB::Connection, account_id : String, kind : String)
  db.query_all(
    "SELECT title, body, data FROM notifications WHERE account_id = $1 AND kind = $2",
    account_id, kind,
    as: {String, String, JSON::Any},
  )
end

describe Facet::Document::ImportJob do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies

    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))

    Facet::Event::Publisher.manager = Facet::Event::InProcessManager.new
  end

  describe "success outcome" do
    it "runs the file end to end: rows exist, report correct, event + notification land" do
      with_temp_doctype("jimpok") do |db, domain, dt|
        create_jimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        ensure_iam_account(db, "jimp_owner")

        file = %([
          {"id": null, "content": {"name": "a"}},
          {"id": null, "content": {"name": "b"}}
        ])

        job_id = enqueue_import_job(db, domain, dt, "json", "jimp_owner", file)
        run_import_job(db, job_id)

        outcome = jimp_outcome(db, job_id)
        outcome.status.should eq("succeeded")
        report = outcome.result.not_nil!
        report["row_count"].as_i.should eq(2)
        report["created"].as_i.should eq(2)
        report["updated"].as_i.should eq(0)
        report["skipped"].as_i.should eq(0)

        # Both rows persist — the ids came from the manifest, so the docs
        # were created under them.
        count = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
        count.should eq(2)

        # The doctype stream carries the file's row events (one burst) and
        # then the completion event — in that order. No mutation id, no
        # collection fanout.
        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(3)
        events[0].headers["event"].as_s.should eq("created")
        events[1].headers["event"].as_s.should eq("created")
        events[2].headers["event"].as_s.should eq("import_completed")
        events[2].headers["actioner_id"].as_s.should eq("jimp_owner")
        events[2].headers["mutation_id"]?.should be_nil
        events[2].content["id"].as_s.should eq(job_id)
        events[2].content["import"]["row_count"].as_i.should eq(2)
        events2 = event_manager.events_for("fanout:#{domain}.#{dt}")
        events2.size.should eq(2) # the row created-events fan out like any document write
        events2.each { |e| e.headers["event"].as_s.should eq("created") }

        # The notification carries the counts and the status path.
        rows = jimp_notification_rows(db, "jimp_owner", "import_completed")
        rows.size.should eq(1)
        title, _body, _data = rows[0]
        title.should eq("Import ready")
      end
    end

    it "drives CSV through the same service (decode + report match JSON)" do
      with_temp_doctype("jimpcsv") do |db, domain, dt|
        create_jimp_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "price": {"type": "money"}}))
        ensure_iam_account(db, "jimp_csv")

        file = "id,label,price\n,Fall item,EUR 12.50\n,Fall item 2,EUR 1.00\n"

        job_id = enqueue_import_job(db, domain, dt, "csv", "jimp_csv", file)
        run_import_job(db, job_id)

        outcome = jimp_outcome(db, job_id)
        outcome.status.should eq("succeeded")
        outcome.result.not_nil!["created"].as_i.should eq(2)

        prices = db.query_all(
          "SELECT content->'price'->>'currency' FROM projections WHERE domain = $1 AND doc_type = $2",
          domain, dt, as: String)
        prices.should eq(["EUR", "EUR"])
      end
    end

    it "notifies with the recovery message on a failing row, and emits import_failed" do
      with_temp_doctype("jimpfail") do |db, domain, dt|
        create_jimp_doctype(db, domain, dt, %({"name": {"type": "string", "required": true}}))
        ensure_iam_account(db, "jimp_fail")

        file = %([
          {"id": null, "content": {"name": "good"}},
          {"id": null, "content": {}}
        ])
        job_id = enqueue_import_job(db, domain, dt, "json", "jimp_fail", file)
        run_import_job(db, job_id)

        outcome = jimp_outcome(db, job_id)
        outcome.status.should eq("failed")
        failure = outcome.result.not_nil!
        failure["row"].as_i.should eq(2)
        failure["field"].as_s.should eq("name")

        # The required-name error rides the result; nothing persists.
        count = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
        count.should eq(0)

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(1) # the rolled-back row's event was discarded
        events.first.headers["event"].as_s.should eq("import_failed")
        events.first.content["import"]["error"]["row"].as_i.should eq(2)

        rows = jimp_notification_rows(db, "jimp_fail", "import_failed")
        rows.size.should eq(1)
        _title, body, _data = rows[0]
        body.should contain("fix")
        body.should contain("row 2")
      end
    end
  end

  describe "row-count guard (B-272)" do
    it "fails a staged import above the limit with the limit named, before any row is written" do
      original = Facet::Config.instance
      Facet::Config.instance = Facet::Config.new(
        artifact_grant_secret: original.artifact_grant_secret,
        secrets: original.secrets,
        import_export: Facet::Config::ImportExportConfig.new(max_import_rows: 2),
        # The suite runs with the staleness bound disabled; a swap that
        # defaulted it to 300 would let the process caches rebuild from
        # the truncated projections mid-suite.
        cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
      )
      begin
        with_temp_doctype("jimpcap") do |db, domain, dt|
          create_jimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
          ensure_iam_account(db, "jimp_cap")

          file = %([
            {"id": null, "content": {"name": "a"}},
            {"id": null, "content": {"name": "b"}},
            {"id": null, "content": {"name": "c"}}
          ])
          job_id = enqueue_import_job(db, domain, dt, "json", "jimp_cap", file)
          run_import_job(db, job_id)

          outcome = jimp_outcome(db, job_id)
          outcome.status.should eq("failed")
          outcome.error.not_nil!.should contain("the file carries 3 rows")
          outcome.error.not_nil!.should contain("the configured import limit is 2 rows")
          outcome.error.not_nil!.should contain("import_export.max_import_rows")

          failure = outcome.result.not_nil!
          failure["row"].as_i.should eq(0)
          failure["message"].as_s.should contain("import_export.max_import_rows")

          # Nothing applied — the guard runs before any decode or write.
          count = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
          count.should eq(0)

          # The failure event and notification carry the limit, without
          # the row prefix (no single row owns the refusal).
          events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
          events.size.should eq(1)
          events.first.headers["event"].as_s.should eq("import_failed")
          events.first.content["import"]["error"]["row"].as_i.should eq(0)

          rows = jimp_notification_rows(db, "jimp_cap", "import_failed")
          rows.size.should eq(1)
          _title, body, _data = rows[0]
          body.should contain("fix the file")
          body.should contain("import_export.max_import_rows")
        end
      ensure
        Facet::Config.instance = original
      end
    end

    it "imports a file at the limit unchanged" do
      original = Facet::Config.instance
      Facet::Config.instance = Facet::Config.new(
        artifact_grant_secret: original.artifact_grant_secret,
        secrets: original.secrets,
        import_export: Facet::Config::ImportExportConfig.new(max_import_rows: 2),
        cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
      )
      begin
        with_temp_doctype("jimpcapok") do |db, domain, dt|
          create_jimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
          ensure_iam_account(db, "jimp_cap_ok")

          file = %([
            {"id": null, "content": {"name": "a"}},
            {"id": null, "content": {"name": "b"}}
          ])
          job_id = enqueue_import_job(db, domain, dt, "json", "jimp_cap_ok", file)
          run_import_job(db, job_id)

          jimp_outcome(db, job_id).status.should eq("succeeded")
        end
      ensure
        Facet::Config.instance = original
      end
    end
  end

  describe "manifest idempotence" do
    it "re-executes after a simulated crash with no duplicate rows or events" do
      with_temp_doctype("jimpre") do |db, domain, dt|
        create_jimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        ensure_iam_account(db, "jimp_re")
        a = Facet::Util::ScriptHelpers.ulid
        file = %([{"id": "#{a}", "content": {"name": "a"}}])

        job_id = enqueue_import_job(db, domain, dt, "json", "jimp_re", file)
        run_import_job(db, job_id)
        jimp_outcome(db, job_id).status.should eq("succeeded")

        Facet::Event::Publisher.flush
        event_manager.clear!

        # Simulate the lease sweep requeue of a row whose outcome write
        # never landed; the same manifest ids absorb the committed attempt.
        db.exec("UPDATE background_jobs SET status = 'pending', run_after = now() WHERE id = $1", job_id)
        run_import_job(db, job_id)

        outcome = jimp_outcome(db, job_id)
        outcome.status.should eq("succeeded")
        outcome.result.not_nil!["created"].as_i.should eq(0)
        outcome.result.not_nil!["updated"].as_i.should eq(1)

        count = db.query_one(
          "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
        count.should eq(1)
        jimp_doc_exists(db, domain, dt, a).should be_true

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(1) # the re-execution's own completion event only
      end
    end
  end

  describe "crash-class failures" do
    it "raises JobError for a vanished manifest artifact, terminal with no event" do
      with_temp_doctype("jimpghost") do |db, domain, dt|
        create_jimp_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        file = %([{"id": null, "content": {"name": "a"}}])
        job_id = enqueue_import_job(db, domain, dt, "json", "jimp_parentless", file)

        # Delete both artifact rows to simulate a pruned file + manifest.
        db.exec("DELETE FROM artifacts WHERE filename LIKE '%manifest%'")

        claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
        job = claimed.find! { |j| j.id == job_id }
        expect_raises(Facet::Jobs::JobError) do
          Facet::Document::ImportJob.new.execute(job)
        end
      end
    end
  end
end
