# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Duplicate guard on the direct `core.Domain` create path (B-33).
#
# `POST /Api/core/Domain` names the domain in the body (`id` field). A
# repeated POST for a live domain used to append a second `create` mutation
# and silently overwrite the document — 201 with the caller's content,
# every other key gone. The create path now rejects a re-POST of a live
# domain with 409, leaves the content untouched, and appends nothing.
# A tombstoned (dropped) domain may be re-created — the create projection
# trigger resurrects the row.
#
# Coverage:
# 1. HTTP — re-POST of a live domain answers 409, content untouched, one
#    `create` mutation total.
# 2. Service — `Document::Create.call` twice, second attempt is a 409.
# 3. Re-create after the domain is dropped succeeds.

private def post_domain(body : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("POST", "/Api/core/Domain", headers: HTTP::Headers{
    "Content-Type"     => "application/json",
    "X-Requested-With" => "XMLHttpRequest",
  }, body: body))
end

private def get_domain(id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/core/Domain/#{id}"))
end

# Re-registers the core.DocType definition for `core.Domain` — the flat
# GET route resolves the doctype definition and answers 404 without it
# (the per-example TRUNCATE wipes the seeded projection).
private def seed_core_domain_doctype(db : DB::Connection) : Nil
  defn_path = File.join(__DIR__, "..", "..", "data", "seeds", "core.Domain", "definition.yml")
  yaml = YAML.parse(File.read(defn_path))
  defn = Facet::Doctype::DoctypeDefinition.from_json(Facet::Doctype::YamlHelper.to_json_any(yaml))
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "core.Domain",
    content: defn.to_json,
    actioner_id: "system",
  )
  Facet::Doctype::DefinitionStore.invalidate("core.Domain")
end

module Facet
  module Document
    describe Create do
      it "rejects a repeated POST for a live domain (HTTP)" do
        seed_core_domain_doctype(with_db { |db| db })
        name = "crm-#{unique_suffix}"
        first = post_domain(%({"id": "#{name}", "name": "#{name}", "description": "original", "color": "#123456"}))
        assert_http_status(first, 201)

        second = post_domain(%({"id": "#{name}", "name": "#{name}", "description": "overwritten"}))
        assert_http_status(second, 409)
        JSON.parse(second.body)["error"].as_s.should eq("Domain '#{name}' already exists")

        # Content is untouched: the original keys survive.
        fetched = get_domain(name)
        assert_http_status(fetched, 200)
        content = JSON.parse(fetched.body)["data"].as_h
        content["description"].as_s.should eq("original")
        content["color"].as_s.should eq("#123456")

        # History carries exactly one create mutation.
        with_db do |db|
          count = db.query_one(
            "SELECT COUNT(*) FROM mutations WHERE domain = 'core' AND doc_type = 'Domain' AND doc_id = $1",
            name, as: Int64)
          count.should eq(1)
        end
      end

      it "rejects a repeated create through the service layer" do
        with_db do |db|
          name = "crm-#{unique_suffix}"
          result = Database.with_transaction do |txn|
            Create.call(txn, "core", "Domain", %({"id": "#{name}", "name": "#{name}"}), RBAC::AuthContext.system)
          end
          result.should be_a(Create::Result)

          again = Database.with_transaction do |txn|
            Create.call(txn, "core", "Domain", %({"id": "#{name}", "name": "#{name}", "description": "again"}), RBAC::AuthContext.system)
          end
          again.should be_a(ServiceError)
          err = again.as(ServiceError)
          err.status.should eq(409)
          err.message.should eq("Domain '#{name}' already exists")

          # The first create's content stands.
          content = Mutation::Client.fetch_content(db, "core", "Domain", name)
          content.as_h["description"]?.should be_nil
        end
      end

      it "rejects a draft key on the generic create route (B-177)" do
        with_db do |db|
          name = "draftdoor-#{unique_suffix}"

          # HTTP: the caller-chosen-id draft door is closed with a 422.
          resp = post_domain(%({"id": "#{name}", "draft": true}))
          assert_http_status(resp, 422)
          JSON.parse(resp.body)["error"].as_s.should contain("draft")

          # Service: nothing was created and no mutation was appended.
          Util::Projections.exists?(db, "core", "Domain", name).should be_false
          count = db.query_one(
            "SELECT COUNT(*) FROM mutations WHERE domain = 'core' AND doc_type = 'Domain' AND doc_id = $1",
            name, as: Int64)
          count.should eq(0)
        end
      end

      it "allows re-creating a dropped (tombstoned) domain" do
        with_db do |db|
          name = "crm-#{unique_suffix}"
          result = Database.with_transaction do |txn|
            Create.call(txn, "core", "Domain", %({"id": "#{name}", "name": "#{name}"}), RBAC::AuthContext.system)
          end
          result.should be_a(Create::Result)

          dropped = Domain::Drop.call(db, name, "system:test")
          dropped.should be_a(Domain::Drop::Result)

          recreated = Database.with_transaction do |txn|
            Create.call(txn, "core", "Domain", %({"id": "#{name}", "name": "#{name}", "description": "back"}), RBAC::AuthContext.system)
          end
          recreated.should be_a(Create::Result)

          # The projection row is live again with the new content.
          Util::Projections.exists?(db, "core", "Domain", name).should be_true
          content = Mutation::Client.fetch_content(db, "core", "Domain", name)
          content.as_h["description"].as_s.should eq("back")
        end
      end
    end
  end
end
