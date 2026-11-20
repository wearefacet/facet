# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

require "../../../src/domain"
require "../../../src/domain/portable"
require "../../../src/doctype"
require "../../../src/doctype/seed"
require "../../../src/document"
require "../../../src/mutation/client"
require "../../../src/rbac"

# Specs for the replication invariant gate on the portable-domain import
# door (B-164). `Doctype::Create` and `Doctype::Update` refuse a replicate
# field whose source is a `secret` (422); the import must refuse the same
# shape, because a hand-crafted bundle bypasses the authoring gate.
#
# Each example re-seeds the core doctypes (the global per-spec truncation
# wipes them) and builds its bundle in memory — no fixture files.

# Re-registers the core doctypes that the global truncation wiped.
def import_invariants_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Wraps raw content into a bundle entry (empty meta — doctype entries
# carry no parent linkage; the import rewrites the domain field itself).
def import_invariants_entry(content : String) : Facet::Domain::Portable::Archive::Entry
  Facet::Domain::Portable::Archive::Entry.new(JSON.parse(content), JSON.parse(%({})))
end

# Builds an in-memory bundle for `domain` whose doctype entries appear in
# the given order — the order matters for the consumer-before-producer
# case, so it is part of the input, not an implementation detail.
def import_invariants_bundle(domain : String, doctype_contents : Array(String)) : Facet::Domain::Portable::Archive::Bundle
  doctypes = doctype_contents.map do |content|
    parsed = JSON.parse(content)
    {doctype: "#{domain}.#{parsed["doctype"].as_s}", entry: import_invariants_entry(content)}
  end
  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: domain,
    exported_at: "2026-01-01T00:00:00Z",
    facet_version: "test",
    domain: import_invariants_entry(%({"description": "invariant gate bundle", "color": "#123456"})),
    doctypes: doctypes,
    document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
    collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
  )
end

# Producer carrying a secret field (the leak source).
IMPORT_INVARIANTS_SECRET_PRODUCER = %({
  "doctype": "Vault",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "ssn": {"type": "secret", "mode": "hash"}
  }
})

# Same producer with a plain string — the legitimate control.
IMPORT_INVARIANTS_STRING_PRODUCER = %({
  "doctype": "Vault",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ ssn }}",
  "fields": {
    "ssn": {"type": "string"}
  }
})

# Producer whose plain field carries a sensitivity tag — the B-271 leak
# source when the replica field is tag-less.
IMPORT_INVARIANTS_TAGGED_PRODUCER = %({
  "doctype": "Vault",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "ssn": {"type": "string", "tags": ["pay"]}
  }
})

# Consumer v1: reference only, no replicate field (merge base).
IMPORT_INVARIANTS_CONSUMER_V1 = %({
  "doctype": "Employee",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "vault_ref": {"type": "reference", "doctype": "leaksrc.Vault"}
  }
})

# Consumer replicating from the producer's `ssn` field. The refusal and
# the control case share it — what changes is the source field's type.
IMPORT_INVARIANTS_CONSUMER = %({
  "doctype": "Employee",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "vault_ref": {"type": "reference", "doctype": "leaksrc.Vault"},
    "vault_ssn": {"type": "string", "replicate": {"via": "vault_ref", "field": "ssn"}}
  }
})

# The tagged-source pair: the tag-less replica leaks, the tagged replica
# carries the source's tag and is the legitimate control.
IMPORT_INVARIANTS_TAGGED_CONSUMER = %({
  "doctype": "Employee",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "vault_ref": {"type": "reference", "doctype": "leaksrc.Vault"},
    "vault_ssn": {"type": "string", "replicate": {"via": "vault_ref", "field": "ssn"}}
  }
})

IMPORT_INVARIANTS_TAGGED_CONSUMER_CARRYING = %({
  "doctype": "Employee",
  "domain": "leaksrc",
  "schema_version": 1,
  "search": "{{ display_name }}",
  "fields": {
    "vault_ref": {"type": "reference", "doctype": "leaksrc.Vault"},
    "vault_ssn": {"type": "string", "tags": ["pay"], "replicate": {"via": "vault_ref", "field": "ssn"}}
  }
})

describe "Domain::Portable import replication invariant gate (B-164)" do
  it "refuses a fresh import whose consumer replicates from a secret source (422, all-or-nothing)" do
    with_db do |db|
      import_invariants_reseed_core(db)

      # Consumer ordered before its producer: a per-doctype check would
      # silently skip the not-yet-landed source, so the gate must run
      # after the whole loop.
      bundle = import_invariants_bundle("leaksrc", [
        IMPORT_INVARIANTS_CONSUMER,
        IMPORT_INVARIANTS_SECRET_PRODUCER,
      ])

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("leaksrc.Employee")
      err.message.should contain("secret")

      # The transaction rolled back — no doctype row, no domain row.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'leaksrc.%'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'leaksrc'",
        as: Int64
      ).should eq(0)
    end
  end

  it "refuses a merge import that adds a replicate-from-secret field (422)" do
    with_db do |db|
      import_invariants_reseed_core(db)

      # Land the clean pair first: producer with the secret, consumer
      # without a replicate field.
      clean = import_invariants_bundle("leaksrc", [
        IMPORT_INVARIANTS_SECRET_PRODUCER,
        IMPORT_INVARIANTS_CONSUMER_V1,
      ])
      clean_result = Facet::Domain::Portable::Import.call(db, clean)
      clean_result.should be_a(Facet::Domain::Portable::Import::Result)

      # Merge a bundle that adds the replicate field at the same version —
      # an additive edit the version gate accepts, so only the invariant
      # gate can stop it.
      bundle = import_invariants_bundle("leaksrc", [IMPORT_INVARIANTS_CONSUMER])
      result = Facet::Domain::Portable::Import.call(db, bundle, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("leaksrc.Employee")
      err.message.should contain("secret")

      # The rolled-back merge left the stored consumer at v1 — no
      # replicate field on the target.
      consumer = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", "leaksrc.Employee")
      consumer.content["fields"].as_h.has_key?("vault_ssn").should be_false
    end
  end

  it "refuses a bundle whose consumer's via target is unqualified (422, all-or-nothing)" do
    with_db do |db|
      import_invariants_reseed_core(db)

      # `doctype: Vault` is unqualified. The schema gate refuses the bare
      # reference target at the import authoring gate (F02-01); behind it,
      # the F09-02 replication invariant stays armed — an unqualified via
      # target can never resolve a source, so the gate fails closed
      # instead of skipping the secret check.
      unqualified = %({
        "doctype": "Employee",
        "domain": "leaksrc",
        "schema_version": 1,
        "search": "{{ display_name }}",
        "fields": {
          "vault_ref": {"type": "reference", "doctype": "Vault"},
          "vault_ssn": {"type": "string", "replicate": {"via": "vault_ref", "field": "ssn"}}
        }
      })

      bundle = import_invariants_bundle("leaksrc", [unqualified])
      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("leaksrc.Employee")
      err.message.should contain("schema validation failed")
      err.details.not_nil!.any? { |d| d.message.includes?("bare reference target 'Vault'") }.should be_true

      # The transaction rolled back — no doctype row, no domain row.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'leaksrc.%'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'leaksrc'",
        as: Int64
      ).should eq(0)
    end
  end

  it "still imports a clean bundle with a legitimate replicate edge" do
    with_db do |db|
      import_invariants_reseed_core(db)

      # Same ordering as the refusal case (consumer first) to prove the
      # gate does not fire on a resolvable, non-secret source.
      bundle = import_invariants_bundle("leaksrc", [
        IMPORT_INVARIANTS_CONSUMER,
        IMPORT_INVARIANTS_STRING_PRODUCER,
      ])

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      res = result.as(Facet::Domain::Portable::Import::Result)
      res.doctypes_created.should eq(2)

      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'leaksrc.%'",
        as: Int64
      ).should eq(2)
    end
  end

  it "refuses an import whose consumer replicates a tagged source into an untagged replica (422, all-or-nothing)" do
    with_db do |db|
      import_invariants_reseed_core(db)

      # Same-domain edge — no grant is involved, so the refusal proves
      # the tag invariant is domain-agnostic.
      bundle = import_invariants_bundle("leaksrc", [
        IMPORT_INVARIANTS_TAGGED_CONSUMER,
        IMPORT_INVARIANTS_TAGGED_PRODUCER,
      ])

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("leaksrc.Employee")
      err.message.should contain("pay")

      # The transaction rolled back — no doctype row, no domain row.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'leaksrc.%'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'leaksrc'",
        as: Int64
      ).should eq(0)
    end
  end

  it "still imports a bundle whose replica carries the source field's tags" do
    with_db do |db|
      import_invariants_reseed_core(db)

      bundle = import_invariants_bundle("leaksrc", [
        IMPORT_INVARIANTS_TAGGED_CONSUMER_CARRYING,
        IMPORT_INVARIANTS_TAGGED_PRODUCER,
      ])

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      res = result.as(Facet::Domain::Portable::Import::Result)
      res.doctypes_created.should eq(2)

      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id LIKE 'leaksrc.%'",
        as: Int64
      ).should eq(2)
    end
  end
end
