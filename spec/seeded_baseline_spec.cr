# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "./support/seeded_baseline_helper"

# `SeededBaseline` — the snapshot-restore fixture re-seed. The snapshot is
# taken once per suite in `before_suite`; these examples pin the contract the
# fixture callers rely on: the restore reproduces the seeded corpus, is
# idempotent, keeps the definition cache usable, and falls back to the real
# seed on databases without a snapshot.
describe "SeededBaseline" do
  it "restores every baseline row after a truncate" do
    with_db do |db|
      db.exec(SeededBaseline::TRUNCATE_SQL)
      restore_seeded_baseline(db)

      counts = db.query_one("(
        SELECT (SELECT count(*) FROM projections), (SELECT count(*) FROM spec_baseline_projections)
      )", as: {Int64, Int64})
      counts[0].should eq(counts[1])
      counts[0].should be > 0
    end
  end

  it "keeps the seeded corpus usable after repeated restores" do
    with_db do |db|
      restore_seeded_baseline(db)
      restore_seeded_baseline(db)

      row = db.query_one?("(
        SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'core.DocType' AND deleted_at IS NULL
      )", as: String)
      row.should eq("core.DocType")
    end
  end

  it "preserves example-created rows, like the seed does" do
    with_db do |db|
      # A fixture row created before the restore must survive it — the
      # original call sites run the seed helper after ensure_domain and
      # account fixtures, and the seed is additive.
      Facet::Mutation::Client.create(
        db, "core", "Domain", doc_id: "restore_keep",
        content: %({}), actioner_id: "system",
      )
      restore_seeded_baseline(db)

      row = db.query_one?("(
        SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'restore_keep' AND deleted_at IS NULL
      )", as: String)
      row.should eq("restore_keep")
    end
  end

  it "leaves the definition store resolvable for fixture callers" do
    with_db do |db|
      restore_seeded_baseline(db)

      defn = Facet::Doctype::DefinitionStore.fetch(db, "core.DocType")
      defn.should_not be_nil
      defn.not_nil!.doctype.should eq("DocType")
    end
  end

  it "keeps the projection trigger armed inside a caller's transaction" do
    # A restore inside an outer transaction must not leak the trigger
    # bypass past the helper: the next pipeline write in that transaction
    # must still land its projection row.
    with_db do |db|
      Facet::Database.with_transaction(db, ignore_if_set: true) do |txn|
        restore_seeded_baseline(txn)

        Facet::Mutation::Client.create(
          txn, "core", "Domain", doc_id: "nested_after_restore",
          content: %({}), actioner_id: "system",
        )
        row = Facet::Mutation::Client.fetch_projection(txn, "core", "Domain", "nested_after_restore")
        row.id.should eq("nested_after_restore")
      end
    end
  end

  it "falls back to the real seed when the snapshot is absent" do
    with_db do |db|
      begin
        db.exec("DROP TABLE spec_baseline_projections")
        db.exec("DROP TABLE spec_baseline_mutations")

        restore_seeded_baseline(db)

        row = db.query_one?(
          "SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'core.DocType' AND deleted_at IS NULL",
          as: String,
        )
        row.should eq("core.DocType")
      ensure
        # Later examples rely on the snapshot; rebuild it from the corpus the
        # fallback seed just produced (byte-identical to the template seed).
        SeededBaseline.create_snapshot(db)
      end
    end
  end
end
