# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-342 — the lazy-migration failure marker (`meta.migration_error`) must
# reach the REST read and list responses. The write path stores the marker
# in `projections.meta` (`Document::Migrate.write_migration_error_marker`);
# the response builder (`Responders.document_meta`) emits it when present,
# next to the `parent_id` conditional.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

private def mme_seed_doctype(db) : String
  ensure_domain(db, "mmest")
  doctype = "Task#{unique_suffix(6)}"

  defn = %({
    "doctype": "#{doctype}",
    "domain": "mmest",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {"name": {"type": "string"}}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  doctype
end

# Writes the marker the migration failure path would write, without
# running a real failing migration.
private def mme_write_marker(db, doc_id : String, message : String) : Nil
  db.exec(
    "UPDATE projections SET meta = jsonb_set(meta, '{migration_error}', $1) WHERE id = $2",
    JSON::Any.new(message).to_json, doc_id,
  )
end

describe "meta.migration_error on REST responses (B-342)" do
  it "surfaces migration_error on the read response" do
    with_db do |db|
      doctype = mme_seed_doctype(db)
      doc_id = create_doc_id_http("mmest", doctype, %({"name": "stale"}))
      mme_write_marker(db, doc_id, "migration failed: field rewrite exploded")

      resp = call_api(HTTP::Request.new("GET", "/Api/mmest/#{doctype}/#{doc_id}"))
      assert_http_status(resp, 200)
      meta = JSON.parse(resp.body)["meta"].as_h
      meta["migration_error"]?.try(&.as_s).should eq("migration failed: field rewrite exploded")
    end
  end

  it "surfaces migration_error on the list response" do
    with_db do |db|
      doctype = mme_seed_doctype(db)
      doc_id = create_doc_id_http("mmest", doctype, %({"name": "stale row"}))
      mme_write_marker(db, doc_id, "migration failed: bad cast")

      resp = call_api(HTTP::Request.new("GET", "/Api/mmest/#{doctype}"))
      assert_http_status(resp, 200)
      row = JSON.parse(resp.body)["data"].as_a.find! { |r| r["meta"]["id"].as_s == doc_id }
      row["meta"]["migration_error"]?.try(&.as_s).should eq("migration failed: bad cast")
    end
  end

  it "keeps migration_error absent when no marker exists" do
    with_db do |db|
      doctype = mme_seed_doctype(db)
      doc_id = create_doc_id_http("mmest", doctype, %({"name": "healthy"}))

      resp = call_api(HTTP::Request.new("GET", "/Api/mmest/#{doctype}/#{doc_id}"))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["meta"].as_h["migration_error"]?.should be_nil
    end
  end
end
