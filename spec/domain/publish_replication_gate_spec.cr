# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/domain"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/replication"

# Specs for the publish-time replication-invariant re-check (B-374). The
# authoring-time invariant check self-skips any source it cannot resolve,
# so a replica-of-replica field authored before its source exists — the
# natural order inside a draft — lands unchecked, and publish used to copy
# it live. Publish now re-runs `Replication::Validator.validate_invariants`
# over the whole published set, after every bundled doctype has landed: a
# violation refuses the publish, a clean set still publishes.

# Re-registers the core doctypes that the global truncation wiped.
private def rrg_seed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Creates a draft domain and returns its name.
private def rrg_draft(db) : String
  result = Facet::Domain::Draft.create(db, "{}", "system:test")
  result.should be_a(Facet::Domain::Draft::Result)
  result.as(Facet::Domain::Draft::Result).projection.id
end

# Persists a doctype definition under the draft domain by writing directly
# to core.DocType — the same bypass `Domain::Copy` uses, and exactly the
# out-of-order authoring the gate exists for.
private def rrg_doctype(db, domain, doctype, fields) : Nil
  content = %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields}})
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{domain}.#{doctype}",
    content: content,
    actioner_id: "system:test",
  )
end

describe "publish re-runs the replication invariants (B-374)" do
  it "refuses a draft whose replica-of-replica field resolves only after the source lands" do
    with_db do |db|
      rrg_seed_core(db)

      result = Facet::Database.with_transaction do |txn|
        draft = rrg_draft(txn)

        # Author Fin BEFORE Mid exists: the consumer's replicate edge
        # cannot resolve, so no invariant fires at write time.
        rrg_doctype(txn, draft, "Fin", %({
          "mid": {"type": "reference", "doctype": "#{draft}.Mid"},
          "fnm": {"type": "string", "replicate": {"via": "mid", "field": "nm"}}
        }))

        # Mid's own replica field: nm replicates from a plain string field
        # on a same-draft doctype (a one-hop replica).
        rrg_doctype(txn, draft, "Src", %({"full_name": {"type": "string"}}))
        rrg_doctype(txn, draft, "Mid", %({
          "src": {"type": "reference", "doctype": "#{draft}.Src"},
          "nm": {"type": "string", "replicate": {"via": "src", "field": "full_name"}}
        }))

        Facet::Domain::Publish.call(txn, draft, "rrorders", actioner_id: "user-1")
      end

      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Cannot replicate from a replica")
      err.message.should contain("fnm")

      # Nothing landed: the copy rolled back with the refusal.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'rrorders'",
        as: Int64).should eq(0)
    end
  end

  it "publishes a set whose replicate edges are single-hop" do
    with_db do |db|
      rrg_seed_core(db)

      result = Facet::Database.with_transaction do |txn|
        draft = rrg_draft(txn)

        rrg_doctype(txn, draft, "Src", %({"full_name": {"type": "string"}}))
        rrg_doctype(txn, draft, "Mid", %({
          "src": {"type": "reference", "doctype": "#{draft}.Src"},
          "nm": {"type": "string", "replicate": {"via": "src", "field": "full_name"}},
          "code": {"type": "string"}
        }))
        # A second consumer replicating from Mid's plain (non-replicated)
        # field is a legal one-hop edge.
        rrg_doctype(txn, draft, "Other", %({
          "mid": {"type": "reference", "doctype": "#{draft}.Mid"},
          "alias": {"type": "string", "replicate": {"via": "mid", "field": "code"}}
        }))

        Facet::Domain::Publish.call(txn, draft, "rrok", actioner_id: "user-1")
      end

      result.should be_a(Facet::Domain::Publish::Result)
      res = result.as(Facet::Domain::Publish::Result)
      res.target_domain.should eq("rrok")

      published = Facet::Doctype::DefinitionStore.fetch_uncached(db, "rrok.Other").not_nil!
      published.fields["alias"].replicate.should_not be_nil
    end
  end
end
