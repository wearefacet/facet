# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/domain"
require "../../src/doctype"
require "../../src/document"

# Publish-time grant ticket filing (`Grants::PublishTickets.file`) — B-34.
#
# The scan files one ticket per live foreign producer domain reached from
# the consumer's replicate edges. The liveness predicate must treat a
# `core.Domain` document with an **absent `draft` key** as live: domains
# created through the direct path (`POST /Api/core/Domain`) carry no
# `draft` key, while draft-published producers carry `draft: false`.
# Both are live; only `draft: true` (and tombstones) exclude a producer.
#
# Coverage:
# 1. Direct-path producer (no `draft` key) — ticket files (the B-34 bug).
# 2. Draft-published producer (`draft: false`) — control, ticket files.
# 3. Producer still a draft — no ticket (draft producers surface as
#    `/check` diagnostics instead).
# 4. Producer tombstoned — no ticket.
# 5. Producer already holding two grants (one per other consumer) — the
#    third ticket still files (the B-44 bug: the grant lookup read one
#    row while the producer's subtree returns one grant per consumer).

# Persists a doctype definition under the given domain by writing directly
# to core.DocType. Works for draft (`_`-prefixed) and live domains alike.
private def spec_create_doctype(db : DB::Connection, domain : String, doctype : String, fields : String) : String
  content = %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "fields": #{fields}})
  doc_id = "#{domain}.#{doctype}"
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate(doc_id)
  doc_id
end

# Creates a live producer domain through the direct path (`POST
# /Api/core/Domain` → `Document::Create`) — the content carries no
# `draft` key.
private def spec_create_direct_domain(db : DB::Connection, name : String) : Nil
  result = Facet::Document::Create.call(
    db, "core", "Domain", %({"id": "#{name}", "name": "#{name}"}),
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Create::Result)
end

# Creates an empty draft and returns its name.
private def spec_create_draft(db : DB::Connection) : String
  result = Facet::Domain::Draft.create(db, "{}", "system:test")
  result.should be_a(Facet::Domain::Draft::Result)
  result.as(Facet::Domain::Draft::Result).projection.id
end

# Adds a replicate edge to the consumer draft and publishes it. Returns the
# publish result.
private def spec_publish_consumer(db : DB::Connection, producer : String, producer_doctype : String, target : String) : Facet::Domain::Publish::Result
  draft = spec_create_draft(db)
  spec_create_doctype(db, draft, "Haul", %({
    "ref": {"type": "reference", "doctype": "#{producer}.#{producer_doctype}", "required": true},
    "ref_name": {"type": "string", "replicate": {"via": "ref", "field": "name"}}
  }))
  result = Facet::Domain::Publish.call(db, draft, target, actioner_id: "system:test")
  result.should be_a(Facet::Domain::Publish::Result)
  result.as(Facet::Domain::Publish::Result)
end

# Reads the grant document filed under the producer's subtree, or nil.
private def spec_fetch_grant(db : DB::Connection, producer : String) : JSON::Any?
  db.query_one?(
    "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant' " \
    "AND deleted_at IS NULL AND meta->>'parent_id' = $1",
    producer,
    as: JSON::Any,
  )
end

# Reads one grant under the producer admitting the given consumer, or nil.
private def spec_fetch_grant_for(db : DB::Connection, producer : String, consumer : String) : JSON::Any?
  db.query_one?(
    "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant' " \
    "AND deleted_at IS NULL AND meta->>'parent_id' = $1 AND content->>'consumer_domain' = $2",
    producer, "core.Domain.#{consumer}",
    as: JSON::Any,
  )
end

# Writes one grant document straight into the producer's subtree (no
# validation pass — the fixture only needs the rows to exist). Unlike
# `upsert_grant` (spec/support/doctype_helper.cr) this accepts a producer
# that already holds grants — the shared helper assumes one grant per
# producer and reads the subtree with a single-row query.
private def spec_seed_grant(db : DB::Connection, producer : String, consumer : String) : Nil
  content = %({"consumer_domain": "core.Domain.#{consumer}", "resources": [{"doctype": "Thing", "tags": ["default"]}], "active": false})
  Facet::Mutation::Client.create(
    db, "core", "DomainGrant",
    doc_id: Facet::Util::ScriptHelpers.ulid,
    content: content,
    meta: %({"parent_id": #{producer.to_json}}),
    actioner_id: "system:test",
  )
end

module Facet
  module Grants
    describe PublishTickets do
      it "files a ticket for a direct-path producer (no draft key)" do
        with_db do |db|
          producer = "dirprod-#{unique_suffix}"
          target = "depot-#{unique_suffix}"
          result = Facet::Database.with_transaction do |txn|
            spec_create_direct_domain(txn, producer)
            spec_create_doctype(txn, producer, "Thing", %({"name": {"type": "string", "required": true}}))
            spec_publish_consumer(txn, producer, "Thing", target)
          end

          tickets = result.grant_tickets
          tickets.size.should eq(1)
          ticket = tickets.first
          ticket.producer.should eq(producer)
          ticket.filed.should be_true
          ticket.edges.size.should eq(1)
          ticket.edges.first.doctype.should eq("Thing")

          # The filed ticket is inert until accepted (system publisher).
          grant = spec_fetch_grant(db, producer)
          grant.should_not be_nil
          grant.not_nil!.as_h["active"].as_bool.should be_false
          grant.not_nil!.as_h["consumer_domain"].as_s.should eq("core.Domain.#{target}")
        end
      end

      it "files a ticket for a draft-published producer (draft: false)" do
        with_db do |db|
          producer = "fleetd-#{unique_suffix}"
          target = "depot-#{unique_suffix}"
          result = Facet::Database.with_transaction do |txn|
            producer_draft = spec_create_draft(txn)
            spec_create_doctype(txn, producer_draft, "Vehicle", %({"name": {"type": "string", "required": true}}))
            Facet::Domain::Publish.call(txn, producer_draft, producer, actioner_id: "system:test")
              .should be_a(Facet::Domain::Publish::Result)
            spec_publish_consumer(txn, producer, "Vehicle", target)
          end

          tickets = result.grant_tickets
          tickets.size.should eq(1)
          tickets.first.producer.should eq(producer)
          tickets.first.filed.should be_true
          spec_fetch_grant(db, producer).should_not be_nil
        end
      end

      it "skips a producer that is still a draft" do
        with_db do |db|
          producer_draft = spec_create_draft(db)
          spec_create_doctype(db, producer_draft, "Thing", %({"name": {"type": "string"}}))

          target = "depot-#{unique_suffix}"
          result = spec_publish_consumer(db, producer_draft, "Thing", target)

          result.grant_tickets.size.should eq(0)
          spec_fetch_grant(db, producer_draft).should be_nil
        end
      end

      it "files a ticket when the producer already holds two grants (B-44)" do
        with_db do |db|
          producer = "multig-#{unique_suffix}"
          holder_a = "holda-#{unique_suffix}"
          holder_b = "holdb-#{unique_suffix}"
          target = "depot-#{unique_suffix}"

          result = Facet::Database.with_transaction do |txn|
            spec_create_direct_domain(txn, producer)
            spec_create_doctype(txn, producer, "Thing", %({"name": {"type": "string", "required": true}}))
            spec_seed_grant(txn, producer, holder_a)
            spec_seed_grant(txn, producer, holder_b)
            spec_publish_consumer(txn, producer, "Thing", target)
          end

          tickets = result.grant_tickets
          tickets.size.should eq(1)
          tickets.first.producer.should eq(producer)
          tickets.first.filed.should be_true

          grant = spec_fetch_grant_for(db, producer, target)
          grant.should_not be_nil
          grant.not_nil!.as_h["active"].as_bool.should be_false
          grant.not_nil!.as_h["consumer_domain"].as_s.should eq("core.Domain.#{target}")
        end
      end

      it "skips a tombstoned producer" do
        with_db do |db|
          producer = "dirprod-#{unique_suffix}"
          spec_create_direct_domain(db, producer)
          spec_create_doctype(db, producer, "Thing", %({"name": {"type": "string"}}))
          dropped = Facet::Domain::Drop.call(db, producer, "system:test")
          dropped.should be_a(Facet::Domain::Drop::Result)

          target = "depot-#{unique_suffix}"
          result = spec_publish_consumer(db, producer, "Thing", target)

          result.grant_tickets.size.should eq(0)
          spec_fetch_grant(db, producer).should be_nil
        end
      end
    end
  end
end
