# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype/reproject"

# Specs for `Facet::Doctype::Reproject`.
#
# Each spec creates a doctype with a `search` definition and a few documents,
# then poisons the `projections.search` column via a direct UPDATE (bypassing
# the mutation trigger) to simulate the stale-derived-column drift the
# service is designed to fix. After `Reproject.call`, the search column must
# be recomputed from the doctype's `search:` paths.

# Creates a doctype with a `search` template and *count* documents,
# then poisons every row's `projections.search` column with the sentinel
# "POISONED" so re-projection is detectable. Returns the document ids.
private def setup_doctype_with_poisoned_search(db, domain, doctype, count) : Array(String)
  ensure_domain(db, domain)
  create_schema = %({
    "doctype": "#{doctype}", "domain": "#{domain}",
    "display_name": "{{ name }}",
    "search": "{{ name }} {{ domain_name }}",
    "fields": {
      "name": {"type": "string"},
      "domain_name": {"type": "string"}
    }
  })
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

  ids = [] of String
  count.times do |i|
    r = Facet::Document::Create.call(
      db, domain, doctype,
      %({"name": "Acme Corp #{i}", "domain_name": "acme#{i}.example.com"}),
      Facet::RBAC::AuthContext.system
    )
    expect_create_success(r)
    ids << r.as(Facet::Document::Create::Result).projection.id
  end

  # Poison every row's search column directly. This mimics the drift
  # Reproject fixes: content is correct, but the derived `search` column
  # carries stale fallback data.
  db.exec(
    "UPDATE projections SET search = 'POISONED' WHERE domain = $1 AND doc_type = $2",
    domain, doctype
  )
  ids
end

# Reads the search column of a single projection row.
private def search_for(db, id) : String?
  db.query_one("SELECT search FROM projections WHERE id = $1", id, as: String?)
end

module Facet::Doctype::Reproject
  describe Reproject do
    it "re-projects the search column from the doctype's `search:` template" do
      with_temp_doctype("reprojecthappy") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 3)

        # Sanity: poison landed.
        ids.each { |id| search_for(db, id).should eq("POISONED") }

        # Run with workers=1 to keep the test deterministic against the spec
        # pool (which is sized for the single test fiber, not a parallel pool).
        result = Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) { |_| }
        res = result.as(Reproject::Result)
        res.stats.processed.get.should eq(3)
        res.stats.superseded.get.should eq(0)
        res.stats.skipped.get.should eq(0)
        res.stats.failed.get.should eq(0)

        # Each row's search column now equals the folded corpus of `name` and
        # `domain_name` (space-joined by the trigger). The sentinel is gone.
        ids.each_with_index do |id, i|
          search_for(db, id).should eq("acme corp #{i} acme#{i}.example.com")
        end
      end
    end

    it "leaves the content column byte-identical (content-preserving)" do
      with_temp_doctype("reprojectcontent") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 2)

        before_content = ids.map do |id|
          db.query_one("SELECT content FROM projections WHERE id = $1", id, as: JSON::Any)
        end

        Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) { |_| }

        ids.each_with_index do |id, i|
          after = db.query_one("SELECT content FROM projections WHERE id = $1", id, as: JSON::Any)
          after.to_json.should eq(before_content[i].to_json)
        end
      end
    end

    it "is idempotent — running twice produces identical search state" do
      with_temp_doctype("reprojectidem") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 2)

        Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) { |_| }
        search_after_first = ids.map { |id| search_for(db, id) }

        Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) { |_| }
        ids.each_with_index do |id, i|
          search_for(db, id).should eq(search_after_first[i])
        end
      end
    end

    it "skips rows marked with meta.migration_error" do
      with_temp_doctype("reprojectskip") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 2)

        # Mark the first row as having a migration error.
        target_id = ids[0]
        db.exec(
          "UPDATE projections SET meta = jsonb_set(meta, '{migration_error}', '\"blocked\"') WHERE id = $1",
          target_id
        )

        result = Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) { |_| }
        res = result.as(Reproject::Result)
        res.stats.processed.get.should eq(1)
        res.stats.skipped.get.should eq(1)

        # The marked row is NOT re-projected — the sentinel survives.
        search_for(db, target_id).should eq("POISONED")

        # The unmarked row WAS re-projected.
        search_for(db, ids[1]).should eq("acme corp 1 acme1.example.com")
      end
    end

    it "skips tombstoned rows" do
      with_temp_doctype("reprojecttomb") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 2)

        # Tombstone the first row via the delete service so a proper `delete`
        # mutation lands (the tombstone keeps its search corpus per the
        # retention contract).
        del = Facet::Document::Delete.call(db, domain, doctype, ids[0], Facet::RBAC::AuthContext.system)
        del.should be_a(Facet::Document::Delete::Result)

        result = Reproject.call(db, "#{domain}.#{doctype}", workers: 1, channel_cap: 4) do |_|
        end
        res = result.as(Reproject::Result)
        # The producer's cursor filters `deleted_at IS NULL`, so the tombstone
        # is never enqueued — it is omitted, not superseded. Only the live row
        # is processed.
        res.stats.processed.get.should eq(1)
        res.stats.superseded.get.should eq(0)

        # The tombstone keeps its pre-delete search corpus (retention); the
        # reproject pass never touches it.
        search_for(db, ids[0]).should eq("POISONED")

        # The live row was re-projected.
        search_for(db, ids[1]).should eq("acme corp 1 acme1.example.com")
      end
    end

    it "returns ServiceError 404 when the doctype does not exist" do
      with_db do |db|
        result = Reproject.call(db, "nonexistent.Doctype", workers: 1) { |_| }
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end

    it "returns ServiceError 400 when the qualified doctype is malformed" do
      with_db do |db|
        result = Reproject.call(db, "noDotSeparator", workers: 1) { |_| }
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(400)
      end
    end

    it "processes keyset pages correctly with a small batch size" do
      with_temp_doctype("reprojectkeyset") do |db, domain, doctype|
        ids = setup_doctype_with_poisoned_search(db, domain, doctype, 5)

        # batch_size=2 forces the keyset cursor to advance through 3 pages.
        result = Reproject.call(db, "#{domain}.#{doctype}", batch_size: 2, workers: 1, channel_cap: 4) { |_| }
        res = result.as(Reproject::Result)
        res.stats.processed.get.should eq(5)

        # All rows re-projected — content still matches the expected search corpus.
        ids.each_with_index do |id, i|
          search_for(db, id).should eq("acme corp #{i} acme#{i}.example.com")
        end
      end
    end

    # The optimistic-lock supersede path (`state` mismatch under
    # `FOR UPDATE`) is structurally guaranteed by the worker's lock+verify
    # sequence in `process_one` and is not exercised end-to-end here —
    # doing so reliably would need a custom channel that mutates `state`
    # between enqueue and worker acquire.
  end
end
