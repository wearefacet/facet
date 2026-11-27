# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# B-145: `Audit::List.call` validates the filter map at the service level —
# an unknown field or an unsupported operator answers 422 (the document
# list's B-20 contract), never a silent unfiltered result. The specs pin
# the loud failures and every documented filter path that must keep
# working: plain mode, aggregate mode, and document-history mode.

LF_DOMAIN = "auditflt"

# The message names the full filterable set (B-20 message contract).
EXPECTED_FILTERABLE = "filterable: domain, doc_type, doc_id, action, actioner_id, app, channel, kind, trace, emitted_at"

# Namespaced so the helpers stay collision-free with the other spec files
# compiled into the same binary.
module ListFilters
  # Creates one document of an already-registered doctype.
  def self.create_document(db, doctype : String, content : String = %({"name": "initial"})) : Facet::Document::Create::Result
    expect_create_success(Facet::Document::Create.call(db, LF_DOMAIN, doctype, content, Facet::RBAC::AuthContext.system))
  end

  # Registers one doctype on the auditflt domain and creates one document.
  # Returns the create result (projection id + mutation id).
  def self.create_doc(db, doctype : String, content : String = %({"name": "initial"})) : Facet::Document::Create::Result
    ensure_domain(db, LF_DOMAIN)
    defn = %({"doctype": "#{doctype}", "domain": "#{LF_DOMAIN}", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
    expect_create_success(Facet::Document::Create.call(db, LF_DOMAIN, doctype, content, Facet::RBAC::AuthContext.system))
  end

  # Reads the stamping values of one document's create row, so the specs
  # filter by the row's own values and not by assumed constants.
  def self.create_row_stamps(db, doc_id : String) : {String, String, String}
    db.query_one(
      "SELECT channel, cause_kind, cause_trace FROM mutations WHERE doc_id = $1 AND action = 'create'",
      doc_id, as: {String, String, String}
    )
  end

  # Registers one parent doctype with one child relationship for the
  # aggregate-mode specs. Returns `{parent, child}` doctype names.
  def self.register_pair(db) : {String, String}
    ensure_domain(db, LF_DOMAIN)
    parent = "FP#{unique_suffix}"
    child = "FC#{unique_suffix}"

    parent_defn = %({"doctype": "#{parent}", "domain": "#{LF_DOMAIN}", "aggregate_root": true, "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
    child_defn = %({"doctype": "#{child}", "domain": "#{LF_DOMAIN}", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))
    {parent, child}
  end

  # Creates a child document the way the nested route does (meta_overrides).
  def self.create_child(db, child_dt : String, parent_id : String, name : String) : Facet::Document::Create::Result
    expect_create_success(Facet::Document::Create.call(
      db, LF_DOMAIN, child_dt, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    ))
  end

  # Formats a UTC instant as an ISO-8601 string with the given hour
  # offset: the wall clock moves by the offset and the label names it, so
  # the instant is unchanged (12:00+02:00 is 10:00Z).
  def self.with_offset(instant : Time, hours : Int32) : String
    sign = hours >= 0 ? "+" : "-"
    offset = "%02d:00" % hours.abs
    (instant + hours.hours).to_rfc3339.sub("Z", "#{sign}#{offset}")
  end
end

describe "Audit::List filter validation (B-145)" do
  # ── Loud failures ──────────────────────────────────────────────────

  it "answers 422 for an unknown filter field, naming the filterable set" do
    with_db do |db|
      ListFilters.create_doc(db, "LFUnk")
      result = Facet::Audit::List.call(db, filters: {"bogus__eq" => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Unknown filter field 'bogus'")
      error.message.should contain(EXPECTED_FILTERABLE)

      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.try(&.field).should eq("bogus__eq")
      detail.try(&.code).should eq("unknown_filter_field")
    end
  end

  it "answers 422 for an unknown bare filter key (no operator suffix)" do
    with_db do |db|
      ListFilters.create_doc(db, "LFUnkBare")
      result = Facet::Audit::List.call(db, filters: {"nonsense" => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Unknown filter field 'nonsense'")
      detail = error.details.try(&.first?)
      detail.try(&.code).should eq("unknown_filter_field")
    end
  end

  it "answers 422 for a known field with an unsupported operator" do
    with_db do |db|
      ListFilters.create_doc(db, "LFLike")
      result = Facet::Audit::List.call(db, filters: {"doc_type__like" => JSON::Any.new("LF")}, auth_context: Facet::RBAC::AuthContext.system)

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Filter operator 'like' is not served for field 'doc_type'")
      error.message.should contain("allowed: eq")

      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.try(&.field).should eq("doc_type__like")
      detail.try(&.code).should eq("unsupported_filter_operator")
    end
  end

  it "answers 422 for an emitted_at operator outside its set" do
    with_db do |db|
      ListFilters.create_doc(db, "LFTzOp")
      result = Facet::Audit::List.call(db, filters: {"emitted_at__gt" => JSON::Any.new("2026-01-01T00:00:00Z")}, auth_context: Facet::RBAC::AuthContext.system)

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Filter operator 'gt' is not served for field 'emitted_at'")
      error.message.should contain("allowed: gte, lte")
      detail = error.details.try(&.first?)
      detail.try(&.code).should eq("unsupported_filter_operator")
    end
  end

  it "answers 422 for the operator forms the strict grammar removed" do
    with_db do |db|
      ListFilters.create_doc(db, "LFStrict")

      # `emitted_at__eq` and `__ne` on the doc pins are outside the
      # documented grammar — each answers 422 naming the allowed set.
      cases = {
        "emitted_at__eq" => "allowed: gte, lte",
        "domain__ne"     => "allowed: eq",
        "doc_type__ne"   => "allowed: eq",
        "doc_id__ne"     => "allowed: eq",
      }
      cases.each do |key, allowed_text|
        result = Facet::Audit::List.call(db, filters: {key => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("is not served for field")
        error.message.should contain(allowed_text)
        detail = error.details.try(&.first?)
        detail.try(&.code).should eq("unsupported_filter_operator")
        detail.try(&.field).should eq(key)
      end
    end
  end

  # ── Documented filters keep filtering ──────────────────────────────

  it "filters by domain__eq" do
    with_db do |db|
      ListFilters.create_doc(db, "LFDom")
      result = Facet::Audit::List.call(db, filters: {"domain__eq" => JSON::Any.new(LF_DOMAIN)}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.domain == LF_DOMAIN }.should be_true
    end
  end

  it "filters by doc_type__eq" do
    with_db do |db|
      ListFilters.create_doc(db, "LFDt")
      result = Facet::Audit::List.call(db, filters: {"doc_type__eq" => JSON::Any.new("LFDt")}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.doc_type == "LFDt" }.should be_true
    end
  end

  it "filters by a qualified doc_type__eq (domain + doctype in one conjunct)" do
    with_db do |db|
      ListFilters.create_doc(db, "LFQdt")

      # The same bare doctype name in a second domain: the qualified form
      # must pick one domain, where the bare form matches both.
      ensure_domain(db, "auditflt2")
      defn = %({"doctype": "LFQdt", "domain": "auditflt2", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, "auditflt2", "LFQdt", %({"name": "initial"}), Facet::RBAC::AuthContext.system))

      qualified = Facet::Audit::List.call(db, filters: {"doc_type__eq" => JSON::Any.new("#{LF_DOMAIN}.LFQdt")}, auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      qualified.total.should be >= 1
      qualified.items.all? { |m| m.domain == LF_DOMAIN && m.doc_type == "LFQdt" }.should be_true

      other = Facet::Audit::List.call(db, filters: {"doc_type__eq" => JSON::Any.new("auditflt2.LFQdt")}, auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      other.total.should be >= 1
      other.items.all? { |m| m.domain == "auditflt2" && m.doc_type == "LFQdt" }.should be_true

      # A qualified value whose domain holds no such doctype answers nothing.
      miss = Facet::Audit::List.call(db, filters: {"doc_type__eq" => JSON::Any.new("nope.LFQdt")}, auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      miss.total.should eq(0)
    end
  end

  it "filters by doc_id__eq" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFId")
      result = Facet::Audit::List.call(db, filters: {"doc_id__eq" => JSON::Any.new(doc.projection.id)}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.doc_id == doc.projection.id }.should be_true
    end
  end

  it "filters by action__eq" do
    with_db do |db|
      ListFilters.create_doc(db, "LFAct")
      result = Facet::Audit::List.call(db, filters: {"action__eq" => JSON::Any.new("create")}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.action == "create" }.should be_true
    end
  end

  it "filters by action__ne" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFActNe")
      Facet::Document::Update.call(db, LF_DOMAIN, "LFActNe", doc.projection.id, %({"name": "v2"}), Facet::RBAC::AuthContext.system)
        .should be_a(Facet::Document::Update::Result)

      result = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"action__ne" => JSON::Any.new("create")}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be >= 1
      list.items.all? { |m| m.action != "create" }.should be_true
    end
  end

  it "filters by actioner_id__eq" do
    with_db do |db|
      ListFilters.create_doc(db, "LFActor")
      result = Facet::Audit::List.call(db, filters: {"actioner_id__eq" => JSON::Any.new("system")}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.actioner_id == "system" }.should be_true
    end
  end

  it "filters by app__eq and app__ne" do
    with_db do |db|
      ListFilters.create_doc(db, "LFApp")

      # System-tier mutations carry no app attribution: an exact match on
      # any app id answers nothing, and __ne keeps the unattributed rows
      # (IS DISTINCT FROM semantics).
      eq = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"app__eq" => JSON::Any.new("no-such-app")}, auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      eq.total.should eq(0)

      ne = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"app__ne" => JSON::Any.new("no-such-app")}, auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      ne.total.should be >= 1
    end
  end

  it "filters by channel__eq" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFChan")
      channel, _kind, _trace = ListFilters.create_row_stamps(db, doc.projection.id)

      result = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"channel__eq" => JSON::Any.new(channel)}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.channel == channel }.should be_true
    end
  end

  it "filters by kind__eq" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFKind")
      _channel, kind, _trace = ListFilters.create_row_stamps(db, doc.projection.id)

      result = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"kind__eq" => JSON::Any.new(kind)}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should be > 0
      list.items.all? { |m| m.cause_kind == kind }.should be_true
    end
  end

  it "filters by trace__eq" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFTrace")
      doc_id = doc.projection.id
      _channel, _kind, trace = ListFilters.create_row_stamps(db, doc_id)

      result = Facet::Audit::List.call(db, domain: LF_DOMAIN, filters: {"trace__eq" => JSON::Any.new(trace)}, auth_context: Facet::RBAC::AuthContext.system)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should eq(1)
      list.items.first.doc_id.should eq(doc_id)
    end
  end

  it "converts an emitted_at__gte bound with a +02:00 offset to UTC" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFTzGte")
      doc_id = doc.projection.id

      # One hour before now (as an instant), carried as +02:00 — matches.
      before = ListFilters.with_offset(Time.utc - 1.hour, 2)
      hit = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFTzGte", doc_id: doc_id,
        filters: {"emitted_at__gte" => JSON::Any.new(before)}, auth_context: Facet::RBAC::AuthContext.system)
      hit.as(Facet::Audit::List::Result).total.should eq(1)

      # One hour after now (as an instant), carried as +02:00 — no match.
      after = ListFilters.with_offset(Time.utc + 1.hour, 2)
      miss = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFTzGte", doc_id: doc_id,
        filters: {"emitted_at__gte" => JSON::Any.new(after)}, auth_context: Facet::RBAC::AuthContext.system)
      miss.as(Facet::Audit::List::Result).total.should eq(0)
    end
  end

  it "converts an emitted_at__lte bound with a +02:00 offset to UTC" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFTzLte")
      doc_id = doc.projection.id

      # One hour after now (as an instant), carried as +02:00 — matches.
      after = ListFilters.with_offset(Time.utc + 1.hour, 2)
      hit = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFTzLte", doc_id: doc_id,
        filters: {"emitted_at__lte" => JSON::Any.new(after)}, auth_context: Facet::RBAC::AuthContext.system)
      hit.as(Facet::Audit::List::Result).total.should eq(1)

      # One hour before now (as an instant), carried as +02:00 — no match.
      before = ListFilters.with_offset(Time.utc - 1.hour, 2)
      miss = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFTzLte", doc_id: doc_id,
        filters: {"emitted_at__lte" => JSON::Any.new(before)}, auth_context: Facet::RBAC::AuthContext.system)
      miss.as(Facet::Audit::List::Result).total.should eq(0)
    end
  end

  it "filters emitted_at by a relative date" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFRel")
      doc_id = doc.projection.id

      # A fresh mutation is inside the last day.
      recent = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFRel", doc_id: doc_id,
        filters: {"emitted_at__gte" => JSON::Any.new("-1d")}, auth_context: Facet::RBAC::AuthContext.system)
      recent.as(Facet::Audit::List::Result).total.should be >= 1

      # A future bound matches nothing.
      future = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFRel", doc_id: doc_id,
        filters: {"emitted_at__gte" => JSON::Any.new("+1d")}, auth_context: Facet::RBAC::AuthContext.system)
      future.as(Facet::Audit::List::Result).total.should eq(0)
    end
  end

  # ── Aggregate mode ─────────────────────────────────────────────────

  it "aggregate mode still merges child rows when filters are valid" do
    with_db do |db|
      parent_dt, child_dt = ListFilters.register_pair(db)
      parent = ListFilters.create_document(db, parent_dt)
      parent_id = parent.projection.id
      child = ListFilters.create_child(db, child_dt, parent_id, "kid-1")

      list = Facet::Audit::List.call(
        db, domain: LF_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        filters: {"action__eq" => JSON::Any.new("create")},
        auth_context: Facet::RBAC::AuthContext.system, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      list.items.size.should eq(2)
      list.total.should eq(2)
      # Newest first: the child create rides its own branch, the parent
      # create the parent branch; both pass the shared filter clause.
      list.items.map(&.doc_id).should eq([child.projection.id, parent_id])
      list.items.map(&.action).should eq(["create", "create"])
      # Aggregate mode labels every row with the target document's label.
      list.items.all? { |m| m.display_name == "kid-1" || m.display_name == "initial" }.should be_true
    end
  end

  it "aggregate mode applies doc_type filters inside the child branches" do
    with_db do |db|
      parent_dt, child_dt = ListFilters.register_pair(db)
      parent = ListFilters.create_document(db, parent_dt)
      parent_id = parent.projection.id
      child = ListFilters.create_child(db, child_dt, parent_id, "kid-1")

      # The doc_type filter names the child doctype: the parent branch
      # answers nothing, the child branch still resolves.
      list = Facet::Audit::List.call(
        db, domain: LF_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        filters: {"doc_type__eq" => JSON::Any.new(child_dt), "action__eq" => JSON::Any.new("create")},
        auth_context: Facet::RBAC::AuthContext.system, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      list.total.should eq(1)
      list.items.map(&.doc_id).should eq([child.projection.id])
    end
  end

  it "aggregate mode applies a qualified doc_type filter inside the child branches" do
    with_db do |db|
      parent_dt, child_dt = ListFilters.register_pair(db)
      parent = ListFilters.create_document(db, parent_dt)
      parent_id = parent.projection.id
      child = ListFilters.create_child(db, child_dt, parent_id, "kid-1")

      # The qualified value binds two params; the shared filter clauses are
      # re-referenced inside the child branch, so the placeholder order must
      # survive the split.
      list = Facet::Audit::List.call(
        db, domain: LF_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        filters: {"doc_type__eq" => JSON::Any.new("#{LF_DOMAIN}.#{child_dt}"), "action__eq" => JSON::Any.new("create")},
        auth_context: Facet::RBAC::AuthContext.system, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      list.total.should eq(1)
      list.items.map(&.doc_id).should eq([child.projection.id])
      list.items.all? { |m| m.domain == LF_DOMAIN && m.doc_type == child_dt }.should be_true
    end
  end

  # ── Document-history mode ──────────────────────────────────────────

  it "document-history mode still scopes by the doc pins and applies valid filters" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFHist")
      doc_id = doc.projection.id
      Facet::Document::Update.call(db, LF_DOMAIN, "LFHist", doc_id, %({"name": "v2"}), Facet::RBAC::AuthContext.system)
        .should be_a(Facet::Document::Update::Result)

      list = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFHist", doc_id: doc_id,
        filters: {"action__eq" => JSON::Any.new("create")}, auth_context: Facet::RBAC::AuthContext.system)
        .should be_a(Facet::Audit::List::Result)
      list.total.should eq(1)
      list.items.first.action.should eq("create")
      list.items.first.doc_id.should eq(doc_id)
    end
  end

  it "document-history mode applies the same 422 filter contract" do
    with_db do |db|
      doc = ListFilters.create_doc(db, "LFHistErr")
      doc_id = doc.projection.id

      result = Facet::Audit::List.call(db, domain: LF_DOMAIN, doc_type: "LFHistErr", doc_id: doc_id,
        filters: {"bogus__eq" => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Unknown filter field 'bogus'")
    end
  end
end
