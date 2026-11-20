# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/domain/drop"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"

HTTPTest.init

# Seeds the core doctype definitions, a live `hr` domain with one doctype
# definition and one data document. The global per-example TRUNCATE wipes the
# seeded rows, so every example re-establishes the baseline.
#
# The doctype definition is persisted via `Mutation::Client.create` directly —
# the same pattern `spec/http/domain_draft_http_spec.cr` uses.
def seed_live_domain_with_data(db : DB::Connection) : Nil
  restore_seeded_baseline(db)
  ensure_domain(db, "hr")

  content = %({"doctype": "Employee", "domain": "hr", "schema_version": 1, "fields": {"name": {"type": "string"}}})
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "hr.Employee",
    content: content,
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "hr", "Employee",
    doc_id: "e1",
    content: %({"name": "Ada"}),
    actioner_id: "system:test",
  )
end

def drop_via_api(id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new(
    "POST",
    "/Api/core/Domain/#{id}/drop",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
  ))
end

describe "POST /Api/core/Domain/:id/drop" do
  before_each do
    with_db { |db| seed_live_domain_with_data(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  it "tears down the whole domain and records a delete mutation" do
    resp = drop_via_api("hr")
    assert_http_status(resp, 200)
    data = JSON.parse(resp.body)["data"].as_h
    data["domain"].as_s.should eq("hr")
    data["deleted"].raw.should be_true

    with_db do |db|
      # The core.Domain document is tombstoned.
      domain_row = db.query_one?(
        "SELECT deleted_at FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'hr'",
        as: Time?
      )
      domain_row.nil?.should be_false

      # The doctype definition (lives under core, keyed by content domain) is
      # tombstoned, and the domain's data rows are tombstoned.
      doctype_alive = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' " \
        "AND id = 'hr.Employee' AND deleted_at IS NULL",
        as: Int32
      )
      doctype_alive.nil?.should be_true

      data_alive = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'hr' AND deleted_at IS NULL",
        as: Int32
      )
      data_alive.nil?.should be_true

      # Index tracking rows are hard-deleted.
      index_count = db.query_one(
        "SELECT COUNT(*) FROM doctype_indexes WHERE domain = 'hr'",
        as: Int64
      )
      index_count.should eq(0)

      # The audit record: a delete mutation on the core.Domain document.
      audit = db.query_one?(
        "SELECT 1 FROM mutations WHERE domain = 'core' AND doc_type = 'Domain' " \
        "AND doc_id = 'hr' AND action = 'delete'",
        as: Int32
      )
      audit.nil?.should be_false
    end
  end

  it "discards a draft domain" do
    draft = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/draft",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(draft, 201)
    draft_id = JSON.parse(draft.body)["meta"]["id"].as_s

    resp = drop_via_api(draft_id)
    assert_http_status(resp, 200)

    with_db do |db|
      alive = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' " \
        "AND id = $1 AND deleted_at IS NULL",
        draft_id,
        as: Int32
      )
      alive.nil?.should be_true
    end
  end

  it "rejects with 404 when the domain does not exist" do
    resp = drop_via_api("_ghost")
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("not found")
  end

  it "rejects with 422 for the protected system domains" do
    ["core", "iam", "app"].each do |name|
      resp = drop_via_api(name)
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("system domain")
    end
  end

  it "rejects with 409 while a draft branched from the domain is live" do
    draft = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/hr/draft",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(draft, 201)

    resp = drop_via_api("hr")
    assert_http_status(resp, 409)
    JSON.parse(resp.body)["error"].as_s.should contain("discard it first")

    # The domain is untouched after the refusal.
    with_db do |db|
      alive = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' " \
        "AND id = 'hr' AND deleted_at IS NULL",
        as: Int32
      )
      alive.nil?.should be_false
    end
  end
end

describe "DELETE /Api/core/Domain/:id (generic document route)" do
  before_each do
    with_db { |db| seed_live_domain_with_data(db) }
    Facet::Event::Publisher.flush
    Facet::Doctype::DefinitionStore.cache.clear
  end

  it "is refused with 422 — a lone Domain tombstone would orphan the domain" do
    resp = call_api(HTTP::Request.new("DELETE", "/Api/core/Domain/hr"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("drop")

    with_db do |db|
      alive = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' " \
        "AND id = 'hr' AND deleted_at IS NULL",
        as: Int32
      )
      alive.nil?.should be_false
    end
  end
end
