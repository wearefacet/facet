# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-199 — the rollback 404 names the retention window with the correct
# singular/plural form: a 1-day window reads "1 day", not "1 days". Both
# message branches carry the fix — the global route (base window) and
# the document-scoped route (effective window).

require "../spec_helper"
require "json"
require "../../src/audit"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Seeds the doctype the document-scoped route names in its 404.
private def rmw_seed_doctype(db, doctype : String) : Nil
  ensure_domain(db, "auditrm")

  defn = %({
    "doctype": "#{doctype}",
    "domain": "auditrm",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {"name": {"type": "string"}}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

private def rmw_global_rollback_404(mutation_id : String) : String
  resp = call_api(HTTP::Request.new("POST", "/Api/Audit/#{mutation_id}/rollback"))
  assert_http_status(resp, 404)
  JSON.parse(resp.body)["error"].as_s
end

private def rmw_document_rollback_404(doc_id : String, mutation_id : String) : String
  request = HTTP::Request.new(
    "POST",
    "/Api/auditrm/Task/#{doc_id}/rollback",
    HTTP::Headers{"Content-Type" => "application/json"},
    body: %({"mutation_id": "#{mutation_id}"}),
  )
  resp = call_api(request)
  assert_http_status(resp, 404)
  JSON.parse(resp.body)["error"].as_s
end

describe "Rollback 404 window message singular/plural (B-199)" do
  {1, 30}.each do |days|
    plural = days == 1 ? "day" : "days"

    it "window #{days} reads '#{days} #{plural}' on the global route" do
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"mutations": {"retention_days": #{days}}}))
        begin
          rmw_seed_doctype(db, "Task")
          unknown = "01" + "9" * 24

          body = rmw_global_rollback_404(unknown)
          # B-332 — the global route does not know the target doctype, so it
          # words the clause as the base window.
          body.should contain("base retention window (#{days} #{plural})")
          body.should_not contain("#{days} days") if days == 1
        ensure
          pin_settings(db, %({"mutations": {"retention_days": null}}))
        end
      end
    end

    it "window #{days} reads '#{days} #{plural}' on the document-scoped route" do
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"mutations": {"retention_days": #{days}}}))
        begin
          rmw_seed_doctype(db, "Task")
          doc_id = create_doc_id_http("auditrm", "Task", %({"name": "live"}))
          unknown = "01" + "8" * 24

          body = rmw_document_rollback_404(doc_id, unknown)
          body.should contain("retention window (#{days} #{plural} for auditrm.Task)")
          body.should_not contain("#{days} days") if days == 1
        ensure
          pin_settings(db, %({"mutations": {"retention_days": null}}))
        end
      end
    end
  end
end
