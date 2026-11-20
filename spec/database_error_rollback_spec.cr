# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "json"
require "pg"
require "../src/doctype"
require "../src/document"
require "../src/rbac"

# B-109: an error return rolls the transaction back.
#
# A `Database.with_transaction` block that returns an error value — any
# value whose type includes `Facet::ErrorResult` — has produced nothing
# worth keeping. The wrapper rolls back and returns the error unchanged.
# On the top-level rollback it also discards the fiber's pending event
# queue, so the buffered events of a failed transaction never ride a
# later flush. A savepoint rollback leaves that decision to the
# outermost frame.

# A test error type that is NOT a `Facet::ServiceError`. It pins the
# marker-based rule: the wrapper reacts to the module, not to one class.
private class ProbeRefusal
  include Facet::ErrorResult
  getter message : String

  def initialize(@message : String); end
end

private def table_exists?(db : DB::Connection, name : String) : Bool
  found = db.query_one?(
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    name,
    as: Int32
  )
  !found.nil?
end

describe "Database.with_transaction error rollback" do
  it "marks ServiceError and ValidationError as error results" do
    Facet::ServiceError.new(422, "refused").should be_a(Facet::ErrorResult)
    Facet::ValidationError.new("bad field").should be_a(Facet::ErrorResult)
  end

  it "rolls back a compound create when a child fails validation" do
    with_temp_doctype("txnerr") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string", "required": true}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Valid"}, {"not_the_label": "oops"}]}})
      result = Facet::Database.with_transaction do |txn|
        Facet::Document::CreateWithChildren.call(txn, domain, doctype, body, Facet::RBAC::AuthContext.system)
      end
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)

      # The parent and the valid first child never reached the store.
      # The doctype rows live in the core domain, so a domain count of
      # the test domain covers exactly the failed compound create.
      proj_count = db.query_one("SELECT count(*) FROM projections WHERE domain = $1", domain, as: Int64)
      proj_count.should eq(0)
      mut_count = db.query_one("SELECT count(*) FROM mutations WHERE domain = $1", domain, as: Int64)
      mut_count.should eq(0)
    end
  end

  it "discards the buffered events of a failed compound create" do
    with_temp_doctype("txnevt") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string", "required": true}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
      Facet::Event::Publisher.discard # drop the setup events — clean baseline

      enqueued_inside = 0
      body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Valid"}, {"not_the_label": "oops"}]}})
      result = Facet::Database.with_transaction do |txn|
        r = Facet::Document::CreateWithChildren.call(txn, domain, doctype, body, Facet::RBAC::AuthContext.system)
        enqueued_inside = Facet::Event::Publisher.pending_count
        r
      end
      result.should be_a(Facet::ServiceError)

      # The half-created parent and child buffered their events; the
      # rollback discarded them, so no later flush can publish them.
      enqueued_inside.should be > 0
      Facet::Event::Publisher.pending_count.should eq(0)
    end
  end

  it "rolls back when the block returns a custom error type that includes the marker" do
    with_db do |db|
      table = "probe_marker_mode_#{unique_suffix(6).downcase}"
      result = Facet::Database.with_transaction do |txn|
        txn.exec("CREATE TABLE #{table} (id integer)")
        ProbeRefusal.new("refused by policy")
      end
      result.should be_a(ProbeRefusal)
      result.as(ProbeRefusal).message.should eq("refused by policy")
      # The DDL went away with the transaction.
      table_exists?(db, table).should be_false
    end
  end

  it "rolls back on the connection overload too" do
    with_db do |db|
      table = "probe_marker_conn_#{unique_suffix(6).downcase}"
      result = Facet::Database.with_transaction(db) do |txn|
        txn.exec("CREATE TABLE #{table} (id integer)")
        ProbeRefusal.new("refused by policy")
      end
      result.should be_a(ProbeRefusal)
      table_exists?(db, table).should be_false
    end
  end

  it "propagates a savepoint error to the outermost frame and discards there" do
    with_db do |db|
      table = "probe_savept_#{unique_suffix(6).downcase}"
      enqueued_inside = 0
      result = Facet::Database.with_transaction(db) do |txn|
        txn.exec("CREATE TABLE #{table} (id integer)")
        Facet::Event::Publisher.enqueue(domain: "core", doc_type: "DocType", doc_id: "probe-outer", event: "created")
        inner = Facet::Database.with_transaction(txn) do
          Facet::Event::Publisher.enqueue(domain: "core", doc_type: "DocType", doc_id: "probe-inner", event: "created")
          ProbeRefusal.new("inner refused")
        end
        enqueued_inside = Facet::Event::Publisher.pending_count
        inner
      end

      # The savepoint frame rolled back without a discard; the outermost
      # frame saw the error value, ran the top-level ROLLBACK, and
      # discarded the whole queue.
      result.should be_a(ProbeRefusal)
      enqueued_inside.should eq(2)
      Facet::Event::Publisher.pending_count.should eq(0)
      table_exists?(db, table).should be_false
    end
  end

  it "keeps the ignore_if_set join path outside the rollback decision" do
    with_db do |db|
      table = "probe_join_#{unique_suffix(6).downcase}"
      result = Facet::Database.with_transaction(db) do |txn|
        txn.exec("CREATE TABLE #{table} (id integer)")
        Facet::Database.with_transaction(txn, ignore_if_set: true) do
          ProbeRefusal.new("joined frame refuses")
        end
        # The outer frame swallows the joined refusal and keeps its own
        # writes — the outermost frame decides.
        nil
      end

      result.should be_nil
      table_exists?(db, table).should be_true
    end
  end

  it "commits a successful compound create" do
    with_temp_doctype("txnok") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
      Facet::Event::Publisher.discard # drop the setup events — clean baseline

      body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Child A"}, {"label": "Child B"}]}})
      result = Facet::Database.with_transaction do |txn|
        Facet::Document::CreateWithChildren.call(txn, domain, doctype, body, Facet::RBAC::AuthContext.system)
      end
      result.should be_a(Facet::Document::CreateWithChildren::Result)
      cwc = result.as(Facet::Document::CreateWithChildren::Result)
      cwc.projection.content["name"].as_s.should eq("Parent")
      cwc.children["items"].size.should eq(2)

      # The success path committed: one parent, two children.
      proj_count = db.query_one("SELECT count(*) FROM projections WHERE domain = $1", domain, as: Int64)
      proj_count.should eq(3)
      mut_count = db.query_one("SELECT count(*) FROM mutations WHERE domain = $1", domain, as: Int64)
      mut_count.should eq(3)

      # The success path keeps the events buffered for the post-commit
      # flush — no discard on commit.
      Facet::Event::Publisher.pending_count.should be > 0
      Facet::Event::Publisher.discard
    end
  end
end
