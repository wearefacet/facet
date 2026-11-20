# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Audit pager contract (B-297, superseding B-198): `meta.count` is the real
# number of matching mutations from the page offset, counted up to
# `COUNT_CAP`; `meta.more` is true only when counting was truncated. The
# history routes share the response writer, so the global route and the
# document history must agree.

require "../spec_helper"
require "json"
require "../../src/audit"
require "../../src/document"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Seeds one doctype and `count` documents of it — one create mutation per
# document.
private def pgr_seed_docs(db, doctype : String, count : Int32) : Nil
  ensure_domain(db, "audit")

  defn = %({"doctype": "#{doctype}", "domain": "audit", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  count.times do |i|
    r = Facet::Document::Create.call(db, "audit", doctype, %({"name": "row #{i}"}), Facet::RBAC::AuthContext.system)
    r.should be_a(Facet::Document::Create::Result)
  end
end

describe "Audit list capped count (B-297)" do
  # ── Service level ────────────────────────────────────────────────────

  it "counts every matching row from the page offset" do
    with_db do |db|
      pgr_seed_docs(db, "PgSmall", 3)

      result = Facet::Audit::List.call(db, domain: "audit", doc_type: "PgSmall", page: 1, items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::List::Result)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should eq(2)
      list.total.should eq(3)
      list.more.should be_false
    end
  end

  it "reports the remaining count on the last page" do
    with_db do |db|
      pgr_seed_docs(db, "PgLast", 3)

      result = Facet::Audit::List.call(db, domain: "audit", doc_type: "PgLast", page: 2, items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::List::Result)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should eq(1)
      list.total.should eq(1)
      list.more.should be_false
    end
  end

  it "keeps more false when the page covers the total" do
    with_db do |db|
      pgr_seed_docs(db, "PgOne", 3)

      result = Facet::Audit::List.call(db, domain: "audit", doc_type: "PgOne", page: 1, items_per_page: 100,
        auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::List::Result)
      list = result.as(Facet::Audit::List::Result)
      list.items.size.should eq(3)
      list.total.should eq(3)
      list.more.should be_false
    end
  end

  it "keeps more false on an empty list" do
    with_db do |db|
      pgr_seed_docs(db, "PgEmpty", 0)

      result = Facet::Audit::List.call(db, domain: "audit", doc_type: "PgEmpty", page: 1, items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::List::Result)
      list = result.as(Facet::Audit::List::Result)
      list.items.should be_empty
      list.total.should eq(0)
      list.more.should be_false
    end
  end

  # ── HTTP level ───────────────────────────────────────────────────────

  it "caps the global route count at 1000 and flags more" do
    with_db do |db|
      # Synthesized mutation rows: the global list reads the `mutations`
      # table directly, so no projections are needed. Each row carries a
      # distinct doc_id — one shared doc_id would drive the projection's
      # version up and the periodic-snapshot trigger would add snapshot
      # rows on top of the fixture.
      db.exec(<<-SQL)
        INSERT INTO mutations (domain, doc_type, doc_id, idx, action, actioner_id, channel, cause_kind, cause_trace)
        SELECT 'audit', 'PgBulk', 'bulk-' || lpad(g::text, 6, '0'), 0, 'create', 'system:test', 'internal', 'request', 'spec'
        FROM generate_series(1, 1001) AS g
      SQL

      first = call_api(HTTP::Request.new("GET", "/Api/Audit?page=1&items=100"))
      assert_http_status(first, 200)
      meta = JSON.parse(first.body)["meta"]
      meta["count"].as_i.should eq(1000)
      meta["more"].as_bool.should be_true

      # Page 11 starts at offset 1000: one row remains there, so the count
      # is the real 1 and counting was not truncated.
      last = call_api(HTTP::Request.new("GET", "/Api/Audit?page=11&items=100"))
      assert_http_status(last, 200)
      last_meta = JSON.parse(last.body)["meta"]
      last_meta["count"].as_i.should eq(1)
      last_meta["more"].as_bool.should be_false
      JSON.parse(last.body)["data"].as_a.size.should eq(1)
    end
  end

  it "keeps more false on the global route below the cap" do
    with_db do |db|
      pgr_seed_docs(db, "PgHttp", 3)

      resp = call_api(HTTP::Request.new("GET", "/Api/Audit?filters[doc_type__eq]=PgHttp&page=1&items=2"))
      assert_http_status(resp, 200)
      meta = JSON.parse(resp.body)["meta"]
      meta["count"].as_i.should eq(3)
      meta["more"].as_bool.should be_false

      resp2 = call_api(HTTP::Request.new("GET", "/Api/Audit?filters[doc_type__eq]=PgHttp&page=2&items=2"))
      assert_http_status(resp2, 200)
      page2_meta = JSON.parse(resp2.body)["meta"]
      page2_meta["count"].as_i.should eq(1)
      page2_meta["more"].as_bool.should be_false
    end
  end

  it "keeps the document history route on the same writer" do
    with_db do |db|
      pgr_seed_docs(db, "PgHist", 0)
      created = Facet::Document::Create.call(db, "audit", "PgHist", %({"name": "v1"}), Facet::RBAC::AuthContext.system)
      created.should be_a(Facet::Document::Create::Result)
      doc_id = created.as(Facet::Document::Create::Result).projection.id
      Facet::Document::Update.call(db, "audit", "PgHist", doc_id, %({"name": "v2"}), Facet::RBAC::AuthContext.system)
        .should be_a(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, "audit", "PgHist", doc_id, %({"name": "v3"}), Facet::RBAC::AuthContext.system)
        .should be_a(Facet::Document::Update::Result)

      first = call_api(HTTP::Request.new("GET", "/Api/audit/PgHist/#{doc_id}/history?page=1&items=2"))
      assert_http_status(first, 200)
      meta = JSON.parse(first.body)["meta"]
      meta["count"].as_i.should eq(3)
      meta["more"].as_bool.should be_false

      last = call_api(HTTP::Request.new("GET", "/Api/audit/PgHist/#{doc_id}/history?page=2&items=2"))
      assert_http_status(last, 200)
      last_meta = JSON.parse(last.body)["meta"]
      last_meta["count"].as_i.should eq(1)
      last_meta["more"].as_bool.should be_false
    end
  end
end
