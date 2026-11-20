# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

describe "GET /Api/core/DocType/:id/check" do
  before_each do
    with_db do |db|
      ensure_domain(db, "orders")
    end
  end

  it "returns 200 with an empty issues list for a doctype with no broken references" do
    with_db do |db|
      defn = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Widget",
        "domain": "orders",
        "schema_version": 1,
        "aggregate_root": true,
        "fields": {"name": {"type": "string", "required": true}},
        "search": "{{ name }}",
        "display_name": "{{ name }}"
      }))
      Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
      # Ship the standard views so the doctype stays clean — a missing
      # standard kind surfaces as a `:view` warning.
      %w[view form quickView inline card].each do |kind|
        Facet::Mutation::Client.create(
          db, "core", "DocumentView",
          doc_id: "orders.Widget.document_view.#{kind}",
          content: %({"parent_doctype": "orders.Widget", "kind": "#{kind}"}),
          meta: %({"parent_id": "orders.Widget"}),
          actioner_id: "system:test",
        )
      end
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/orders.Widget/check"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["data"]["doctype_id"].as_s.should eq("orders.Widget")
    body["data"]["issues"].as_a.should be_empty
  end

  it "returns 200 with :defaults findings when search and display_name are not declared" do
    # Written straight to the projection: the authoring gate refuses this
    # shape (B-296), and the check must still describe it for definitions
    # created before the gate existed.
    with_db do |db|
      defn = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Bare",
        "domain": "orders",
        "schema_version": 1,
        "aggregate_root": true,
        "fields": {"name": {"type": "string", "required": true}}
      }))
      Facet::Mutation::Client.create(
        db, "core", "DocType",
        doc_id: "orders.Bare",
        content: defn.to_json,
        actioner_id: "system:test",
      )
      Facet::Doctype::DefinitionStore.invalidate("orders.Bare")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/orders.Bare/check"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    issues = body["data"]["issues"].as_a
    defaults = issues.select { |i| i["category"].as_s == "defaults" }
    # Both templates absent (B-296): the aggregate root is an :error — the
    # authoring gate refuses to create it — plus the display_name :info.
    defaults.size.should eq(2)
    errors = defaults.select { |i| i["severity"].as_s == "error" }
    errors.size.should eq(1)
    errors[0]["message"].as_s.should contain("No display_name and no search template")
    infos = defaults.select { |i| i["severity"].as_s == "info" }
    infos.size.should eq(1)
  end

  it "returns 200 with reference issues when the target doctype is not registered" do
    with_db do |db|
      defn = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Order",
        "domain": "orders",
        "schema_version": 1,
        "search": "{{ name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "customer": {"type": "reference", "doctype": "identity.Person"}
        }
      }))
      Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/orders.Order/check"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    issues = body["data"]["issues"].as_a
    ref_issues = issues.select { |i| i["category"].as_s == "reference" }
    ref_issues.size.should eq(1)
    ref_issues[0]["field"].as_s.should eq("customer")
    ref_issues[0]["message"].as_s.should contain("identity.Person")
  end

  it "returns 404 for an unknown doctype" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/orders.Nonexistent/check"))
    assert_http_status(resp, 404)
    body = JSON.parse(resp.body)
    body["error"].as_s.should contain("not found")
  end

  it "includes the field key only when a field is associated with the issue" do
    with_db do |db|
      defn = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Order",
        "domain": "orders",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "customer": {"type": "reference", "doctype": "identity.Person"}
        }
      }))
      Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/core/DocType/orders.Order/check"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    issues = body["data"]["issues"].as_a
    # Reference issue on `customer` should include "field": "customer".
    issues.any? { |i| i["field"]?.try(&.as_s) == "customer" }.should be_true
  end
end
