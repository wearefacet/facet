# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the flat-PATCH dispatch on core.DocType (B-371). The flat
# document PATCH used to write the definition through the generic
# document-update pipeline, skipping every authoring gate only
# `Doctype::Update` runs — the version gate, the same-version
# destructive-edit guards, the migration-map carry — and never triggering
# `Index::Manager.sync`. The flat PATCH now merges the patch over the
# stored definition and runs `Doctype::Update.call`, the service the flat
# PUT delegates to: a same-schema_version field-type change answers the
# same 422 the PUT answers, and an accepted update converges
# `doctype_indexes`.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# One definition body per call — the doctype name and domain are unique
# per example, the field shape is shared.
private def fp_doctype_body(domain : String, doctype : String, fields : String) : String
  %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1,
     "aggregate_root": true, "search": "{{ display_name }}",
     "fields": #{fields}})
end

private def fp_create_doctype(domain : String, doctype : String, fields : String) : String
  resp = create_doctype_http(fp_doctype_body(domain, doctype, fields))
  assert_http_status(resp, 201)
  JSON.parse(resp.body)["meta"]["id"].as_s
end

private def fp_patch(doctype_id : String, body : String) : HTTP::Client::Response
  patch_document_http("core", "DocType", doctype_id, body)
end

private def fp_put(doctype_id : String, body : String) : HTTP::Client::Response
  request = HTTP::Request.new("PUT", "/Api/core/DocType/#{doctype_id}", body: body)
  call_api(request)
end

describe "flat PATCH on core.DocType dispatches through Doctype::Update (B-371)" do
  it "refuses a same-schema_version field-type change with the 422 the PUT answers" do
    with_db do |db|
      ensure_domain(db, "fpdom")

      # The PUT path: the same edit through the authoring door.
      put_id = fp_create_doctype("fpdom", "FpPut", %({"qty": {"type": "integer"}}))
      put = fp_put(put_id, fp_doctype_body("fpdom", "FpPut", %({"qty": {"type": "string"}})))
      assert_http_status(put, 422)
      put_message = JSON.parse(put.body)["error"].as_s

      # The PATCH path: the same edit through the flat document route.
      # The merge patch rides the definition's `fields` object — the same
      # shape the generic pipeline merges.
      patch_id = fp_create_doctype("fpdom", "FpPatch", %({"qty": {"type": "integer"}}))
      resp = fp_patch(patch_id, %({"fields": {"qty": {"type": "string"}}}))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should eq(put_message)

      # Both rows keep the stored definition unchanged.
      [put_id, patch_id].each do |doctype_id|
        defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id).not_nil!
        defn.fields["qty"].type.try(&.type_name).should eq("integer")
      end
    end
  end

  it "answers 422 on a same-schema_version destructive edit and 404 on an unknown row" do
    with_db do |db|
      ensure_domain(db, "fpdom")

      doctype_id = fp_create_doctype("fpdom", "FpRemove", %({"qty": {"type": "integer"}, "name": {"type": "string"}}))

      # Field removal at the same schema_version is refused, like the PUT.
      resp = fp_patch(doctype_id, %({"fields": {"qty": null}}))
      assert_http_status(resp, 422)

      missing = fp_patch("fpdom.FpGhost", %({"description": "x"}))
      assert_http_status(missing, 404)
    end
  end

  it "persists an accepted additive edit and converges doctype_indexes" do
    with_db do |db|
      ensure_domain(db, "fpdom")

      doctype_id = fp_create_doctype("fpdom", "FpGrow", %({"qty": {"type": "integer"}}))

      resp = fp_patch(doctype_id,
        %({"fields": {"qty": {"type": "integer"}, "label": {"type": "string", "filters": ["equality"]}}}))
      assert_http_status(resp, 200)

      defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id).not_nil!
      defn.fields["label"].type.try(&.type_name).should eq("string")

      # Index::Manager.sync runs on the accepted update (synchronous in
      # the suite): the new filtered field gains its tracking row.
      rows = db.query_all(
        "SELECT field_name, status FROM doctype_indexes WHERE domain = 'fpdom' AND doc_type = 'FpGrow'",
        as: {String, String})
      rows.should contain({"label", "active"})

      db.exec("DELETE FROM doctype_indexes WHERE domain = 'fpdom'")
    end
  end

  it "persists a version bump with the migration map through the flat PATCH" do
    with_db do |db|
      ensure_domain(db, "fpdom")

      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.migrate_from_1(ctx)
          ctx.root.qty = ctx.root.qty or 0
        end
        return export
        LUA

      doctype_id = fp_create_doctype("fpdom", "FpBump",
        %({"qty": {"type": "integer"}, "priority": {"type": "string"}}))

      body = %({"schema_version": 2,
                "fields": {"qty": {"type": "integer"}, "priority": {"type": "string"}},
                "migrations": {"1": "migrate_from_1"},
                "script": #{script.to_json}})
      resp = fp_patch(doctype_id, body)
      assert_http_status(resp, 200)

      defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id).not_nil!
      defn.schema_version.should eq(2)
      defn.migrations.should eq({"1" => "migrate_from_1"})
    end
  end
end
