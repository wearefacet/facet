# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "http"
require "json"
require "../../src/doctype"
require "../../src/document"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# B-349 — `core.DomainGrant` create and the read-only `active` flag.
#
# The seed definition declares `active` as `{type: boolean, default: false,
# read_only: true}`. The create pipeline applies declared defaults before
# validation. The read-only gate used to run after that step, so every
# create answered 422 for a field the caller never sent. The gate now runs
# on the raw caller body, before defaults are applied; the stored document
# still carries `active: false`.
#
# The activate route (`Grants::Routes`) flips `active` through a reentrant
# system write. The reentrant flag sets `allow_system_writes`, which lifts
# the gate. The route stays the only document-facing writer of the field.

# Registers the seed definitions after the per-example truncation: the
# grant definition, plus the `core.Domain` definition the `consumer_domain`
# reference check resolves against.
private def spec_seed_grant_doctype(db : DB::Connection) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "DomainGrant")
  Facet::Doctype::Seed.ensure_doctype(db, "core", "Domain")
  Facet::Doctype::DefinitionStore.invalidate("core.DomainGrant")
  Facet::Doctype::DefinitionStore.invalidate("core.Domain")
end

# Creates a live domain through the direct path (`POST /Api/core/Domain`).
private def spec_create_domain(db : DB::Connection, name : String) : Nil
  result = Facet::Document::Create.call(
    db, "core", "Domain", %({"id": "#{name}", "name": "#{name}"}),
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Create::Result)
end

# Creates a grant under the producer through the document create pipeline.
# `active` appends an explicit `active` key to the body when set.
private def spec_create_grant(db : DB::Connection, producer : String, consumer : String, active : Bool? = nil) : Facet::Document::Create::Result | Facet::ServiceError
  active_fragment = active.nil? ? "" : ", \"active\": #{active}"
  body = %({"consumer_domain": "core.Domain.#{consumer}", "resources": [{"doctype": "Thing", "tags": ["default"]}]#{active_fragment}})
  Facet::Document::Create.call(
    db, "core", "DomainGrant", body,
    Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(producer)},
  )
end

# Reads the stored grant content under the producer, or nil.
private def spec_fetch_grant(db : DB::Connection, producer : String) : JSON::Any?
  db.query_one?(
    "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant' " \
    "AND deleted_at IS NULL AND meta->>'parent_id' = $1",
    producer,
    as: JSON::Any,
  )
end

HTTPTest.init

module Facet
  module Grants
    describe "core.DomainGrant create pipeline" do
      it "creates a grant without `active` and stores the default (B-349)" do
        with_db do |db|
          spec_seed_grant_doctype(db)
          producer = "b349prod#{unique_suffix}"
          consumer = "b349cons#{unique_suffix}"
          spec_create_domain(db, producer)
          spec_create_domain(db, consumer)

          result = spec_create_grant(db, producer, consumer)
          result.should be_a(Facet::Document::Create::Result)
          proj = result.as(Facet::Document::Create::Result).projection

          proj.content["active"].as_bool.should be_false

          grant = spec_fetch_grant(db, producer)
          grant.should_not be_nil
          grant.not_nil!.as_h["active"].as_bool.should be_false
        end
      end

      it "rejects an explicit `active` key on create (B-349)" do
        with_db do |db|
          spec_seed_grant_doctype(db)
          producer = "b349prod#{unique_suffix}"
          consumer = "b349cons#{unique_suffix}"
          spec_create_domain(db, producer)
          spec_create_domain(db, consumer)

          result = spec_create_grant(db, producer, consumer, active: true)
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.details.not_nil!.any? { |e| e.field == "active" && e.code == "read_only" }.should be_true
        end
      end

      it "still refuses an explicit `active` write on a plain update (B-349)" do
        with_db do |db|
          spec_seed_grant_doctype(db)
          producer = "b349prod#{unique_suffix}"
          consumer = "b349cons#{unique_suffix}"
          spec_create_domain(db, producer)
          spec_create_domain(db, consumer)

          created = spec_create_grant(db, producer, consumer)
          created.should be_a(Facet::Document::Create::Result)
          grant_id = created.as(Facet::Document::Create::Result).projection.id

          patched = Facet::Document::Update.call(
            db, "core", "DomainGrant", grant_id, %({"active": true}),
            Facet::RBAC::AuthContext.system,
          )
          patched.should be_a(Facet::ServiceError)
          err = patched.as(Facet::ServiceError)
          err.status.should eq(422)
          err.details.not_nil!.any? { |e| e.field == "active" && e.code == "read_only" }.should be_true
        end
      end

      it "activates the grant through the dedicated route" do
        with_db do |db|
          spec_seed_grant_doctype(db)
          producer = "b349prod#{unique_suffix}"
          consumer = "b349cons#{unique_suffix}"
          spec_create_domain(db, producer)
          spec_create_domain(db, consumer)

          created = spec_create_grant(db, producer, consumer)
          created.should be_a(Facet::Document::Create::Result)
          grant_id = created.as(Facet::Document::Create::Result).projection.id

          request = ::HTTP::Request.new("POST", "/Api/core/DomainGrant/#{grant_id}/activate")
          response = call_api(request)
          assert_http_status(response, 200)

          grant = spec_fetch_grant(db, producer)
          grant.should_not be_nil
          grant.not_nil!.as_h["active"].as_bool.should be_true
        end
      end
    end
  end
end
