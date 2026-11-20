# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "csv"
require "json"
require "../../src/rbac"
require "../../src/document"
require "../../src/import_export/export"

alias Export = Facet::Document::Export

# ── Spec helpers ─────────────────────────────────────────────────────────────

# Persists a doctype definition with the given fields (and optional scopes).
private def create_export_doctype(
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

private def create_export_doc(db : DB::Connection, domain : String, doctype : String, content : String) : String
  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

# Runs one export, reads the temp file, deletes it, and returns its text.
# `batch_size` defaults to the service constant; pass a small value to test
# batch boundaries. The view-export parameters (columns / sort / timezone)
# ride the same entry point the job uses.
private def run_export(
  db : DB::Connection,
  domain : String,
  doctype : String,
  format : String,
  filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
  auth_context : Facet::RBAC::AuthContext = Facet::RBAC::AuthContext.system,
  batch_size : Int32? = nil,
  columns : Array(String)? = nil,
  sort : Array(String)? = nil,
  timezone : String? = nil,
) : String
  result = Export.call(db, domain, doctype, format,
    filters: filters,
    auth_context: auth_context,
    batch_size: batch_size || Facet::Document::Export::BATCH_SIZE,
    columns: columns,
    sort: sort,
    timezone: timezone,
  )
  result.should be_a(Facet::Document::Export::Result)
  r = result.as(Facet::Document::Export::Result)
  text = File.read(r.path)
  File.delete?(r.path)
  text
end

# RBAC projection fixtures come from the shared iam helper
# (create_role_projection, create_account_projection, permission_json).

# Builds a Real caller from the projections created above.
private def caller_with_role(db, account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Seeds a doctype with a `mine` ($self) scope on an iam.Account reference
# field, an owning account (scoped caller), a second account (out of scope),
# and documents for both. Returns the scoped caller context.
private def scoped_fixture(db, domain, doctype, owner_labels : Array({String, String}))
  ensure_iam_account(db, "exp_owner_a")
  ensure_iam_account(db, "exp_owner_b")
  create_role_projection(db, "exp_scope_role", [permission_json("read", "#{domain}.#{doctype}", "$mine")])
  create_account_projection(db, "exp_owner_a", ["exp_scope_role"])

  create_export_doctype(db, domain, doctype,
    %({"owner": {"type": "reference", "doctype": "iam.Account"}, "label": {"type": "string", "filters": ["equality"]}}),
    %({"mine": {"where": {"owner": "$self"}}}))

  ids = owner_labels.map do |owner, label|
    create_export_doc(db, domain, doctype, %({"owner": "#{owner}", "label": "#{label}"}))
  end

  {context: caller_with_role(db, "exp_owner_a", "exp_scope_role"), ids: ids}
end

describe Facet::Document::Export do
  # Money filter values validate against the currency registry, which loads
  # from Config. `before_each` is used (not `before_all`) per the spec-helper
  # rule that `before_all` is broken in this project.
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies
  end

  describe "format shapes" do
    it "writes a CSV header row then one data row per document, in id order" do
      with_temp_doctype("expbasic") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}, "amount": {"type": "integer"}}))
        id1 = create_export_doc(db, domain, dt, %({"label": "first", "amount": 1}))
        id2 = create_export_doc(db, domain, dt, %({"label": "second"}))

        text = run_export(db, domain, dt, "csv")
        rows = CSV.parse(text)
        rows.size.should eq(3)
        rows.first.should eq(["id", "label", "amount"])
        rows[1][0].should eq(id1)
        rows[1][1].should eq("first")
        rows[1][2].should eq("1")
        rows[2][0].should eq(id2)
        rows[2][2].should eq("") # absent field → empty cell
      end
    end

    it "writes JSON rows with id, content, and meta (created_at, updated_at, schema_version)" do
      with_temp_doctype("expjson") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        doc_id = create_export_doc(db, domain, dt, %({"label": "hello"}))

        data = JSON.parse(run_export(db, domain, dt, "json")).as_a
        data.size.should eq(1)
        row = data[0]
        row["id"].as_s.should eq(doc_id)
        row["content"]["label"].as_s.should eq("hello")

        meta = row["meta"]
        created = Time::Format::RFC_3339.parse(meta["created_at"].as_s)
        updated = Time::Format::RFC_3339.parse(meta["updated_at"].as_s)
        (updated >= created).should be_true
        meta["schema_version"].as_i.should eq(1)
      end
    end

    it "exports an empty doctype: CSV header-only file, JSON []" do
      with_temp_doctype("expempty") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        CSV.parse(run_export(db, domain, dt, "csv")).should eq([["id", "label"]])
        run_export(db, domain, dt, "json").should eq("[]")
      end
    end
  end

  describe "RBAC" do
    it "a scoped caller exports only rows inside their scopes, in both formats" do
      with_temp_doctype("expscope") do |db, domain, dt|
        fx = scoped_fixture(db, domain, dt, [
          {"exp_owner_a", "a1"},
          {"exp_owner_a", "a2"},
          {"exp_owner_b", "b1"},
        ])
        # ids are creation-ordered; the first two belong to the scoped owner.
        own_ids = fx[:ids][0, 2]

        rows = CSV.parse(run_export(db, domain, dt, "csv", auth_context: fx[:context]))
        rows.size.should eq(3)
        rows[1..].map(&.first).should eq(own_ids)

        data = JSON.parse(run_export(db, domain, dt, "json", auth_context: fx[:context])).as_a
        data.map(&.["id"].as_s).should eq(own_ids)
      end
    end

    it "answers 403 for a denied caller, not an empty file" do
      with_temp_doctype("expdenied") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_export_doc(db, domain, dt, %({"label": "x"}))

        # A caller with no read grant on the doctype at all is denied the
        # resource class — the same 403 the list endpoint answers. An
        # export file that is silently empty would hide the
        # misconfiguration.
        result = Facet::Document::Export.call(db, domain, dt, "csv", auth_context: Facet::RBAC::AuthContext.denied)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "drops read-masked fields from both formats" do
      with_temp_doctype("expmask") do |db, domain, dt|
        create_role_projection(db, "exp_mask_role", [permission_json("read", "#{domain}.#{dt}")])
        create_account_projection(db, "exp_mask_account", ["exp_mask_role"])
        ctx = caller_with_role(db, "exp_mask_account", "exp_mask_role")

        create_export_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "salary": {"type": "integer", "tags": ["confidential"]}}))
        doc_id = create_export_doc(db, domain, dt, %({"label": "x", "salary": 99}))

        rows = CSV.parse(run_export(db, domain, dt, "csv", auth_context: ctx))
        rows.first.should eq(["id", "label"]) # the invisible field is omitted from the header
        rows.size.should eq(2)
        # The data row must carry exactly the header's columns — no trailing
        # cell for the omitted field.
        rows[1].size.should eq(rows.first.size)
        rows[1][0].should eq(doc_id)
        rows[1][1].should eq("x")

        data = JSON.parse(run_export(db, domain, dt, "json", auth_context: ctx)).as_a
        data[0]["content"].as_h.has_key?("salary").should be_false
        data[0]["content"]["label"].as_s.should eq("x")
      end
    end
  end

  describe "filters" do
    it "narrow, never widen: a filter outside the caller's scopes yields an empty result" do
      with_temp_doctype("expfilter") do |db, domain, dt|
        fx = scoped_fixture(db, domain, dt, [
          {"exp_owner_a", "a1"},
          {"exp_owner_b", "b1"},
        ])
        own_id = fx[:ids].first
        ctx = fx[:context]

        rows = CSV.parse(run_export(db, domain, dt, "csv",
          filters: {"label__eq" => JSON::Any.new("b1")}, auth_context: ctx))
        rows.size.should eq(1) # header only — the filter matches a row the scope excludes

        rows = CSV.parse(run_export(db, domain, dt, "csv",
          filters: {"label__eq" => JSON::Any.new("a1")}, auth_context: ctx))
        rows.size.should eq(2)
        rows[1][0].should eq(own_id)
      end
    end

    it "surface a malformed money filter as 422" do
      with_temp_doctype("expmoney") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"price": {"type": "money", "filters": ["comparison"]}}))

        result = Export.call(db, domain, dt, "csv",
          filters: {"price__gte" => JSON::Any.new("XXX 100")})
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.to_s.should contain("XXX")
      end
    end
  end

  describe "batching" do
    it "keeps id ordering across batch boundaries" do
      with_temp_doctype("expbatch") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        ids = Array.new(5) { create_export_doc(db, domain, dt, %({"label": "x"})) }

        rows = CSV.parse(run_export(db, domain, dt, "csv", batch_size: 2))
        rows.size.should eq(6)
        rows[1..].map(&.first).should eq(ids)
      end
    end
  end

  describe "view export — column selection" do
    it "writes the requested columns as the header and one cell per column, in order" do
      with_temp_doctype("expview") do |db, domain, dt|
        create_export_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "amount": {"type": "integer"}, "price": {"type": "money"}, "active": {"type": "boolean"}}))
        id = create_export_doc(db, domain, dt,
          %({"label": "first", "amount": 7, "price": {"value": "1.5", "currency": "USD"}, "active": true}))

        text = run_export(db, domain, dt, "csv",
          columns: ["amount", "label", "created_at", "price", "active"])
        rows = CSV.parse(text)
        rows.size.should eq(2)
        rows.first.should eq(["amount", "label", "created_at", "price", "active"])
        rows[1][0].should eq("7")
        rows[1][1].should eq("first")
        rows[1][2].should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
        rows[1][3].should eq("USD 1.5")
        rows[1][4].should eq("true")
        # The row id is absent unless the caller asks for it.
        rows[1].size.should eq(5)
        rows[1].should_not contain(id)
      end
    end

    it "carries the id column when the caller names it" do
      with_temp_doctype("expviewid") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        id = create_export_doc(db, domain, dt, %({"label": "x"}))

        rows = CSV.parse(run_export(db, domain, dt, "csv", columns: ["id", "label"]))
        rows.first.should eq(["id", "label"])
        rows[1].should eq([id, "x"])
      end
    end

    it "renders timestamp cells in the export timezone as YYYY-MM-DD HH:MM:SS" do
      with_temp_doctype("expviewtz") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_export_doc(db, domain, dt, %({"label": "x"}))

        rows = CSV.parse(run_export(db, domain, dt, "csv",
          columns: ["label", "created_at", "updated_at"], timezone: "Europe/Paris"))
        rows[1][1].should match(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
        rows[1][2].should match(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
      end
    end

    it "shifts a datetime field cell into the export timezone; a malformed stored value stays verbatim" do
      with_temp_doctype("expviewdt") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"when": {"type": "datetime"}}))
        create_export_doc(db, domain, dt, %({"when": "2025-06-15T10:30:00+02:00"}))

        rows = CSV.parse(run_export(db, domain, dt, "csv", columns: ["when"], timezone: "Europe/Paris"))
        rows[1][0].should eq("2025-06-15 10:30:00")

        # No timezone — the stored UTC RFC-3339 text passes through.
        rows = CSV.parse(run_export(db, domain, dt, "csv", columns: ["when"]))
        rows[1][0].should eq("2025-06-15T08:30:00Z")
      end
    end

    it "answers an empty cell for an unknown column key (the route validates; this is the defensive fallback)" do
      with_temp_doctype("expviewunk") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        create_export_doc(db, domain, dt, %({"label": "x"}))

        rows = CSV.parse(run_export(db, domain, dt, "csv", columns: ["label", "ghost"]))
        rows.first.should eq(["label", "ghost"])
        rows[1][0].should eq("x")
        rows[1][1].should eq("")
      end
    end

    it "answers 422 for columns with a non-csv format" do
      with_temp_doctype("expviewjson") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        result = Export.call(db, domain, dt, "json", columns: ["label"])
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.to_s.should contain("csv")
      end
    end

    it "answers 422 for an unloadable timezone" do
      with_temp_doctype("expviewbadtz") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        result = Export.call(db, domain, dt, "csv", columns: ["label"], timezone: "Mars/Olympus")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end
  end

  describe "view export — sort" do
    it "orders the run by the requested sort, across OFFSET batch boundaries" do
      with_temp_doctype("expsorted") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}, "amount": {"type": "integer"}}))
        create_export_doc(db, domain, dt, %({"label": "a", "amount": 30}))
        create_export_doc(db, domain, dt, %({"label": "b", "amount": 10}))
        create_export_doc(db, domain, dt, %({"label": "c", "amount": 20}))
        create_export_doc(db, domain, dt, %({"label": "d"})) # null amount — NULLS LAST on ASC
        create_export_doc(db, domain, dt, %({"label": "e", "amount": 5}))

        rows = CSV.parse(run_export(db, domain, dt, "csv",
          columns: ["label"], sort: ["amount"], batch_size: 2))
        rows[1..].map(&.first).should eq(["e", "b", "c", "a", "d"])

        # A `-` prefix sorts descending; the OFFSET pages stay disjoint.
        # The null row leads — the list operation runs the identical
        # expression with the identical plain ORDER BY, so the export
        # inherits PostgreSQL's NULLS FIRST on DESC verbatim (that is the
        # "what I see" contract: same expression, same defaults).
        rows = CSV.parse(run_export(db, domain, dt, "csv",
          columns: ["label"], sort: ["-amount"], batch_size: 2))
        rows[1..].map(&.first).should eq(["d", "a", "c", "b", "e"])
      end
    end

    it "answers 422 for a sort entry the definition cannot serve (B-158)" do
      with_temp_doctype("expsortdrop") do |db, domain, dt|
        create_export_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "blob": {"type": "object"}}))
        3.times { |i| create_export_doc(db, domain, dt, %({"label": "x#{i}", "blob": {"k": #{i}}})) }

        # An unknown field refuses the run instead of silently keeping the
        # id-order keyset.
        result = Export.call(db, domain, dt, "csv", columns: ["id"], sort: ["nonexistent"])
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should eq("Unknown sort field 'nonexistent'")
        err.details.not_nil!.first.code.should eq("unknown_sort_field")

        # A non-scalar type cannot sort either.
        result = Export.call(db, domain, dt, "csv", columns: ["id"], sort: ["blob"])
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.first.code.should eq("unsortable_field")
      end
    end
  end

  describe "view export — RBAC" do
    it "exports only in-scope rows, and a read-masked column's cell is empty" do
      with_temp_doctype("expviewmask") do |db, domain, dt|
        ensure_iam_account(db, "exp_vmask_owner")
        ensure_iam_account(db, "exp_vmask_other")
        create_role_projection(db, "exp_vmask_role", [permission_json("read", "#{domain}.#{dt}", "$mine")])
        create_account_projection(db, "exp_vmask_owner", ["exp_vmask_role"])
        ctx = caller_with_role(db, "exp_vmask_owner", "exp_vmask_role")

        create_export_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "iam.Account"}, "label": {"type": "string"}, "salary": {"type": "integer", "tags": ["confidential"]}}),
          %({"mine": {"where": {"owner": "$self"}}}))
        create_export_doc(db, domain, dt, %({"owner": "iam.Account.exp_vmask_owner", "label": "mine", "salary": 99}))
        create_export_doc(db, domain, dt, %({"owner": "iam.Account.exp_vmask_other", "label": "theirs", "salary": 1}))

        rows = CSV.parse(run_export(db, domain, dt, "csv",
          columns: ["label", "salary"], auth_context: ctx))
        rows.size.should eq(2) # header + the one in-scope row
        rows.first.should eq(["label", "salary"])
        rows[1][0].should eq("mine")
        rows[1][1].should eq("") # masked → empty cell, header stays
      end
    end
  end

  describe "purity" do
    it "touches mutations not at all and emits no document events" do
      with_temp_doctype("expnowrite") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))
        2.times { create_export_doc(db, domain, dt, %({"label": "x"})) }

        before = db.query_one("SELECT COUNT(*) FROM mutations", as: Int64)

        mgr = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
        Facet::Event::Publisher.flush
        mgr.clear!

        run_export(db, domain, dt, "csv")
        run_export(db, domain, dt, "json")
        run_export(db, domain, dt, "csv", columns: ["label"], sort: ["-created_at"], timezone: "Europe/Paris")

        db.query_one("SELECT COUNT(*) FROM mutations", as: Int64).should eq(before)
        mgr.events_for("FACET:RESOURCE:#{domain}:#{dt}").size.should eq(0)
      end
    end
  end

  describe "input validation" do
    it "answers 422 for an unknown format" do
      with_temp_doctype("expformat") do |db, domain, dt|
        create_export_doctype(db, domain, dt, %({"label": {"type": "string"}}))

        result = Export.call(db, domain, dt, "yaml")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)
      end
    end

    it "answers 404 for an unknown doctype" do
      with_db do |db|
        result = Export.call(db, "expnone", "Nobody", "csv")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end
  end
end
