# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "csv"
require "json"
require "../../src/rbac"
require "../../src/document"
require "../../src/notifications"
require "../../src/artifact/access"
require "../../src/import_export/export"
require "../../src/import_export/export_job"

# ── Spec helpers ─────────────────────────────────────────────────────────────

private def create_job_doctype(
  db : DB::Connection,
  domain : String,
  doctype : String,
  fields : String,
  scopes : String = "{}",
) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "scopes": #{scopes}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_job_doc(db : DB::Connection, domain : String, doctype : String, content : String) : String
  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

private def create_role_for(db, role_id : String, permissions : Array(JSON::Any)) : Nil
  content = JSON::Any.new({
    "name"         => JSON::Any.new(role_id),
    "level"        => JSON::Any.new(20_i64),
    "permissions"  => JSON::Any.new(permissions),
    "visible_tags" => JSON::Any.new(["default"].map { |t| JSON::Any.new(t) }),
  })
  Facet::Mutation::Client.create(db, "iam", "Roles",
    doc_id: role_id, content: content.to_json, actioner_id: "system")
end

# Replaces the role's permission list in place (raw diff, same convention
# the RBAC specs use to seed roles without the iam.Roles doctype
# validation layer).
private def set_role_permissions(db, role_id : String, permissions : Array(JSON::Any)) : Nil
  diff = JSON::Any.new({
    "set" => JSON::Any.new([
      JSON::Any.new({
        "path"  => JSON::Any.new(["permissions"].map { |p| JSON::Any.new(p) }),
        "value" => JSON::Any.new(permissions),
      }),
    ]),
    "unset" => JSON::Any.new([] of JSON::Any),
  })
  Facet::Mutation::Client.update(db, "iam", "Roles", role_id, diff.to_json, actioner_id: "system")
end

# Enqueues one export job row directly (the enqueue route is covered in the
# routes spec). The payload shape mirrors exactly what the route assembles.
private def enqueue_export_job(
  db : DB::Connection,
  domain : String,
  doctype : String,
  format : String,
  account_id : String,
  role_id : String?,
  filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
  columns : Array(String)? = nil,
  sort : Array(String)? = nil,
  timezone : String? = nil,
) : String
  payload = {
    "domain"     => JSON::Any.new(domain),
    "doc_type"   => JSON::Any.new(doctype),
    "format"     => JSON::Any.new(format),
    "account_id" => JSON::Any.new(account_id),
    "filters"    => JSON::Any.new(filters),
  } of String => JSON::Any
  payload["role_id"] = JSON::Any.new(role_id) if role_id
  payload["columns"] = JSON.parse(columns.to_json) if columns
  payload["sort"] = JSON.parse(sort.to_json) if sort
  payload["timezone"] = JSON::Any.new(timezone) if timezone

  id = Facet::Util::ScriptHelpers.ulid
  Facet::Jobs::Queries.insert(db, id, Facet::Document::ExportJob::KIND, JSON.parse(payload.to_json),
    max_attempts: 1, backoff: [] of Int32, lease_ttl_s: 600)
  id
end

# Runs the handler for one claimed row and records the outcome the way
# `Jobs::Worker.write_result` does — the handler never touches its own row.
private def run_export_job(db : DB::Connection, job_id : String) : Facet::Jobs::Handler::Result
  claimed = Facet::Jobs::Queries.claim(db, "spec-worker", 600, 10)
  job = claimed.find! { |j| j.id == job_id }
  result = Facet::Document::ExportJob.new.execute(job)
  case result.status
  in .succeeded?
    Facet::Jobs::Queries.write_succeeded(db, job.id, http_status: result.http_status, result: result.result)
  in .failed?
    Facet::Jobs::Queries.write_failed(db, job.id, error: result.error, http_status: result.http_status, backoff_seconds: job.backoff, result: result.result)
  end
  result
end

private def outcome_of(db : DB::Connection, job_id : String) : Facet::Jobs::Queries::Outcome
  Facet::Jobs::Queries.find_outcome(db, job_id).not_nil!
end

private def artifact_id_of(db : DB::Connection, job_id : String) : String
  outcome_of(db, job_id).result.not_nil!["artifact_id"].as_s
end

# The artifact's bytes as text. Streams directly through the store — the
# same mechanism the job download route uses.
private def artifact_text(db : DB::Connection, artifact_id : String) : String
  artifact = Facet::Artifact::Store.find_artifact(db, artifact_id).not_nil!
  io = Facet::Artifact::Uploader.open(artifact.path)
  begin
    io.gets_to_end
  ensure
    io.close
  end
end

private def notification_rows(db : DB::Connection, account_id : String, kind : String)
  db.query_all(
    "SELECT title, body, data, domain, doc_type, doc_id FROM notifications WHERE account_id = $1 AND kind = $2",
    account_id, kind,
    as: {String, String, JSON::Any, String, String, String},
  )
end

describe Facet::Document::ExportJob do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies

    # `background_jobs` and `notifications` are not in the global
    # truncation list; each spec cleans its own rows.
    with_db(&.exec("DELETE FROM background_jobs"))
    with_db(&.exec("DELETE FROM notifications"))

    # A fresh in-process event manager so completion events are
    # capturable without Redis.
    Facet::Event::Publisher.manager = Facet::Event::InProcessManager.new
  end

  describe "success outcome" do
    it "stores the artifact, records the result, and emits the completion event" do
      with_temp_doctype("expjob") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        2.times { create_job_doc(db, domain, dt, %({"label": "x"})) }

        # The seeding creates buffered fiber-local events; publish and
        # clear so the assertions below see only the job's own event.
        Facet::Event::Publisher.flush
        event_manager.clear!

        job_id = enqueue_export_job(db, domain, dt, "csv", "system", nil)
        run_export_job(db, job_id)

        outcome = outcome_of(db, job_id)
        outcome.status.should eq("succeeded")
        outcome.result.not_nil!["row_count"].as_i.should eq(2)
        outcome.result.not_nil!["format"].as_s.should eq("csv")
        artifact_id = outcome.result.not_nil!["artifact_id"].as_s

        # The artifact row exists with the export's mime type and the
        # expected filename. A system requester carries no account
        # identity, so the row stays ownerless (bytes only).
        artifact = Facet::Artifact::Store.find_artifact(db, artifact_id).not_nil!
        artifact.mime_type.should eq("text/csv")
        artifact.filename.should eq("#{domain}.#{dt}.csv")
        db.query_one("SELECT COUNT(*) FROM artifact_owners WHERE artifact_id = $1", artifact_id, as: Int64).should eq(0)

        # The bytes are the CSV export with a leading id column.
        rows = CSV.parse(artifact_text(db, artifact_id))
        rows.size.should eq(3)
        rows.first.should eq(["id", "label"])

        # Only the completion event rode the doctype stream — no
        # collection fanout, no per-document fanout, no mutation id.
        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(1)
        events.first.headers["event"].as_s.should eq("export_completed")
        events.first.headers["actioner_id"].as_s.should eq("system")
        events.first.headers["mutation_id"]?.should be_nil
        events.first.content["id"].as_s.should eq(job_id)
        events.first.content["export"]["row_count"].as_i.should eq(2)
        event_manager.events_for("fanout:#{domain}.#{dt}").size.should eq(0)
        event_manager.events_for("fanout:#{domain}.#{dt}:#{job_id}").size.should eq(0)
      end
    end

    it "binds the artifact to the requesting account when the caller is real" do
      with_temp_doctype("expjobown") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_job_doc(db, domain, dt, %({"label": "x"}))

        create_role_for(db, "exp_job_own_role", [permission_json("read", "#{domain}.#{dt}")])
        job_id = enqueue_export_job(db, domain, dt, "csv", "exp_job_own_acct", "exp_job_own_role")
        run_export_job(db, job_id)

        artifact_id = artifact_id_of(db, job_id)
        o_domain, o_doc_type, o_doc_id, o_field_path, o_created_by = db.query_one(
          "SELECT domain, doc_type, doc_id, field_path, created_by FROM artifact_owners WHERE artifact_id = $1",
          artifact_id,
          as: {String, String, String, String, String},
        )
        o_domain.should eq("core")
        o_doc_type.should eq("_account")
        o_doc_id.should eq("exp_job_own_acct")
        o_field_path.should eq("upload")
        o_created_by.should eq("exp_job_own_acct")

        # The requester reads their own export through the artifact access
        # check; another account does not.
        role_content = Facet::IAM::Helpers.find_role_content(db, "exp_job_own_role").not_nil!
        owner = Facet::RBAC::AuthContext.authenticated(
          "exp_job_own_acct",
          Facet::RBAC::ActiveRole.from_projection_content(role_content),
        )
        other = Facet::RBAC::AuthContext.authenticated(
          "exp_job_other_acct",
          Facet::RBAC::ActiveRole.from_projection_content(role_content),
        )
        Facet::Artifact::Access.can_read?(db, owner, artifact_id).should be_true
        Facet::Artifact::Access.can_read?(db, other, artifact_id).should be_false
      end
    end

    it "notifies the requesting account with the doctype document as doc_ref" do
      with_temp_doctype("expjobnotif") do |db, domain, dt|
        ensure_iam_account(db, "exp_job_owner")
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_job_doc(db, domain, dt, %({"label": "x"}))

        job_id = enqueue_export_job(db, domain, dt, "json", "exp_job_owner", nil)
        run_export_job(db, job_id)

        outcome_of(db, job_id).status.should eq("succeeded")
        rows = notification_rows(db, "exp_job_owner", "export_completed")
        rows.size.should eq(1)
        title, _body, data, n_domain, n_doc_type, n_doc_id = rows[0]
        n_domain.should eq("core")
        n_doc_type.should eq("DocType")
        n_doc_id.should eq("#{domain}.#{dt}")
        data["job_id"].as_s.should eq(job_id)
        data["download"].as_s.should eq("/Api/#{domain}/#{dt}/import_export/#{job_id}/download")
        data["row_count"].as_i.should eq(1)
        title.should eq("Export ready")
      end
    end
  end

  describe "view export payload" do
    it "runs the service with columns/sort/timezone and names the artifact .view.csv" do
      with_temp_doctype("expjobview") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}, "amount": {"type": "integer"}}))
        create_job_doc(db, domain, dt, %({"label": "a", "amount": 2}))
        create_job_doc(db, domain, dt, %({"label": "b", "amount": 1}))

        Facet::Event::Publisher.flush
        event_manager.clear!

        job_id = enqueue_export_job(db, domain, dt, "csv", "system", nil,
          columns: ["amount", "label"], sort: ["-amount"], timezone: "Europe/Paris")
        run_export_job(db, job_id)

        outcome = outcome_of(db, job_id)
        outcome.status.should eq("succeeded")
        outcome.result.not_nil!["row_count"].as_i.should eq(2)
        outcome.result.not_nil!["format"].as_s.should eq("csv")
        artifact_id = outcome.result.not_nil!["artifact_id"].as_s

        artifact = Facet::Artifact::Store.find_artifact(db, artifact_id).not_nil!
        artifact.filename.should eq("#{domain}.#{dt}.view.csv")

        # The requested columns, in the requested order, under the sort.
        rows = CSV.parse(artifact_text(db, artifact_id))
        rows.first.should eq(["amount", "label"])
        rows[1..].map(&.[0]).should eq(["2", "1"])
        rows[1..].map(&.[1]).should eq(["a", "b"])
      end
    end

    it "notifies with the view title and the view filename" do
      with_temp_doctype("expjobvnot") do |db, domain, dt|
        ensure_iam_account(db, "exp_job_view_owner")
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_job_doc(db, domain, dt, %({"label": "x"}))

        job_id = enqueue_export_job(db, domain, dt, "csv", "exp_job_view_owner", nil,
          columns: ["label"])
        run_export_job(db, job_id)

        outcome_of(db, job_id).status.should eq("succeeded")
        rows = notification_rows(db, "exp_job_view_owner", "export_completed")
        rows.size.should eq(1)
        title, body, data, _n_domain, _n_doc_type, _n_doc_id = rows[0]
        title.should eq("View export ready")
        body.should contain("#{domain}.#{dt}.view.csv")
        data["download"].as_s.should eq("/Api/#{domain}/#{dt}/import_export/#{job_id}/download")
      end
    end
  end

  describe "execution-time RBAC" do
    it "recompiles the caller's scopes when the job runs, not when enqueued" do
      with_temp_doctype("expjobrbac") do |db, domain, dt|
        ensure_iam_account(db, "exp_job_rb_owner")
        create_job_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "iam.Account"}, "label": {"type": "string"}}),
          %({"mine": {"where": {"owner": "$self"}}}))

        own_id = create_job_doc(db, domain, dt, %({"owner": "iam.Account.exp_job_rb_owner", "label": "a"}))
        ensure_iam_account(db, "exp_job_other")
        create_job_doc(db, domain, dt, %({"owner": "iam.Account.exp_job_other", "label": "b"}))

        # The role starts with NO permissions — an enqueue-time compile
        # would have produced an empty export.
        create_role_for(db, "exp_job_scope_role", [] of JSON::Any)

        job_id = enqueue_export_job(db, domain, dt, "csv", "exp_job_rb_owner", "exp_job_scope_role")

        # Grant the scoped read before executing: the recompile at
        # execution time must pick it up.
        set_role_permissions(db, "exp_job_scope_role", [permission_json("read", "#{domain}.#{dt}", "$mine")])

        run_export_job(db, job_id)

        outcome = outcome_of(db, job_id)
        outcome.status.should eq("succeeded")
        rows = CSV.parse(artifact_text(db, artifact_id_of(db, job_id)))
        rows.size.should eq(2) # header + the one in-scope row
        rows[1][0].should eq(own_id)
      end
    end
  end

  describe "failure outcome" do
    it "emits export_failed with the error and no artifact" do
      with_temp_doctype("expjobfail") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}, "price": {"type": "money", "filters": ["comparison"]}}))
        create_job_doc(db, domain, dt, %({"label": "x", "price": {"value": "1.0", "currency": "USD"}}))

        Facet::Event::Publisher.flush
        event_manager.clear!

        # A malformed money filter rides the payload — a definition change
        # between enqueue and execution can invalidate a pre-compiled
        # filter; the job fails loud.
        job_id = enqueue_export_job(db, domain, dt, "csv", "system", nil,
          filters: {"price__gte" => JSON::Any.new("XXX 100")})

        run_export_job(db, job_id)

        outcome = outcome_of(db, job_id)
        outcome.status.should eq("failed")
        outcome.error.to_s.should contain("XXX")
        outcome.result.should be_nil

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(1)
        events.first.headers["event"].as_s.should eq("export_failed")
        events.first.content["export"]["error"].as_s.should contain("XXX")
      end
    end

    it "does not emit a notification for a ghost account, and the job still fails correctly" do
      with_temp_doctype("expjobghost") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}, "price": {"type": "money", "filters": ["comparison"]}}))

        job_id = enqueue_export_job(db, domain, dt, "csv", "exp_job_ghost", nil,
          filters: {"price__gte" => JSON::Any.new("XXX 1")})

        run_export_job(db, job_id)
        outcome_of(db, job_id).status.should eq("failed")
        notification_rows(db, "exp_job_ghost", "export_failed").size.should eq(0)
      end
    end

    it "fails when the sort names an unknown field — never silently reorders (B-158)" do
      with_temp_doctype("expjobsort") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}, "amount": {"type": "integer"}}))
        create_job_doc(db, domain, dt, %({"label": "x", "amount": 1}))

        Facet::Event::Publisher.flush
        event_manager.clear!

        # A view config saved against an older schema can name a field the
        # published definition no longer has — the job fails loud instead
        # of silently producing an id-ordered file.
        job_id = enqueue_export_job(db, domain, dt, "csv", "system", nil,
          columns: ["label"], sort: ["-created"])

        run_export_job(db, job_id)

        outcome = outcome_of(db, job_id)
        outcome.status.should eq("failed")
        outcome.error.to_s.should contain("Unknown sort field 'created'")
        outcome.result.should be_nil

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(1)
        events.first.headers["event"].as_s.should eq("export_failed")
        events.first.content["export"]["error"].as_s.should contain("Unknown sort field 'created'")
      end
    end
  end

  describe "re-execution" do
    it "re-runs after a lease-sweep requeue and produces the same content" do
      with_temp_doctype("expjobre") do |db, domain, dt|
        create_job_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_job_doc(db, domain, dt, %({"label": "x"}))

        job_id = enqueue_export_job(db, domain, dt, "csv", "system", nil)
        run_export_job(db, job_id)
        first_csv = artifact_text(db, artifact_id_of(db, job_id))

        # Simulate the lease sweep's requeue of a row whose outcome write
        # never landed: back to pending, due now.
        db.exec(
          "UPDATE background_jobs SET status = 'pending', run_after = now() WHERE id = $1",
          job_id,
        )
        run_export_job(db, job_id)

        outcome_of(db, job_id).status.should eq("succeeded")
        artifact_text(db, artifact_id_of(db, job_id)).should eq(first_csv)
      end
    end
  end
end
