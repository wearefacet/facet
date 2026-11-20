# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"

module Facet::Mutations
  # Lightweight projection row wrapper for spec assertions.
  record ProjectionRow,
    domain : String,
    doc_type : String,
    id : String,
    content : JSON::Any,
    version : Int32,
    links : JSON::Any,
    meta : JSON::Any,
    state : String,
    display_name : String?,
    deleted_at : Time?,
    updated_at : Time,
    created_at : Time

  # Helper: obtain a fresh DB connection for direct SQL testing.
  # The spec_helper already ran db_reset, so the schema is clean.
  def self.with_db(&)
    database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL is required") }
    DB.open(database_url) do |db|
      yield db
    end
  end

  # Insert a mutation row and return its ULID. The provenance columns get
  # the system-internal defaults; `cause_trace` is the row's own id (the
  # mutation is a root of its causal cluster).
  def self.insert_mutation(
    db,
    domain : String,
    doc_type : String,
    doc_id : String,
    action : String,
    actioner_id : String = "spec-runner",
    arguments : String = "{}",
    emitted_at : String? = nil,
  ) : String
    ts = emitted_at || "now()"
    mut_id = Facet::Util::ScriptHelpers.ulid

    result = db.query_one("
      INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace, emitted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, 'internal', 'request', $3, #{ts})
      RETURNING id
    ", domain, doc_type, mut_id, doc_id, action, actioner_id, arguments, as: String)

    result
  end

  # Fetch a single projection row as a ProjectionRow.
  def self.fetch_projection(db, domain : String, doc_type : String, id : String) : ProjectionRow
    db.query_one("
      SELECT domain, doc_type, id, content, version, links, meta, state, display_name, deleted_at, updated_at, created_at
      FROM projections
      WHERE domain = $1 AND doc_type = $2 AND id = $3
    ", domain, doc_type, id) do |rs|
      ProjectionRow.new(
        domain: rs.read(String),
        doc_type: rs.read(String),
        id: rs.read(String),
        content: rs.read(JSON::Any),
        version: rs.read(Int32),
        links: rs.read(JSON::Any),
        meta: rs.read(JSON::Any),
        state: rs.read(String),
        display_name: rs.read(String?),
        deleted_at: rs.read(Time?),
        updated_at: rs.read(Time),
        created_at: rs.read(Time)
      )
    end
  end
end

# ── Integration specs for the mutation trigger system ──────────────────────
#
# These tests run raw SQL against the real PostgreSQL database to verify
# that inserting into `mutations` correctly drives the `projections` table
# via the PL/pgSQL trigger.

describe "Mutations → Projections" do
  # Pre-requisite: the migration 0001_document_store has been applied by db_reset
  # in spec_helper. We do NOT reset the DB per example since migrations are
  # stateful; instead each test uses unique document IDs to avoid collisions.

  # ── CREATE ────────────────────────────────────────────────────────────────

  describe "create action" do
    it "inserts a new projection with the correct defaults" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        content = %({"name": "Alice", "email": "alice@test.com"})
        meta = %({"source": "signup"})

        mut_id = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": #{content}, "meta": #{meta}}))

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)

        row.id.should eq doc_id
        row.content.should eq JSON.parse(content)
        row.version.should eq 1
        row.links.should eq JSON.parse("[]")
        row.meta.should eq JSON.parse(meta)
        row.state.should eq mut_id
        row.deleted_at.should be_nil
        row.updated_at.should eq row.created_at
      end
    end

    it "uses empty objects when content/meta are omitted" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "note", doc_id, "create",
          arguments: "{}")

        row = Facet::Mutations.fetch_projection(db, "test", "note", doc_id)

        row.content.should eq JSON.parse("{}")
        row.meta.should eq JSON.parse("{}")
        row.version.should eq 1
        row.deleted_at.should be_nil
      end
    end
  end

  # ── UPDATE ────────────────────────────────────────────────────────────────

  describe "update action" do
    it "applies a diff to content and sets state to the mutation ID" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        # First: create the document
        create_content = %({"name": "Alice", "email": "alice@test.com", "age": 30})
        create_mut_id = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": #{create_content}}))

        # Second: update with a diff (change age, unset email)
        diff = %({"set": [{"path": ["age"], "value": 31}, {"path": ["city"], "value": "Paris"}], "unset": [["email"]]})
        update_mut_id = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "update",
          arguments: %({"diff": #{diff}}))

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)

        expected = JSON.parse(%({"name": "Alice", "age": 31, "city": "Paris"}))
        row.content.should eq expected
        row.state.should eq update_mut_id
        # state changed from the create mutation ID to the update mutation ID
        row.state.should_not eq create_mut_id
        # version is NOT bumped by update
        row.version.should eq 1
        row.deleted_at.should be_nil
      end
    end

    it "applies meta_diff to meta independently" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": {"name": "Alice"}, "meta": {"editor": "account1", "draft": true}}))

        diff = %({"diff": {"set": [], "unset": []}, "meta_diff": {"set": [{"path": ["editor"], "value": "account2"}], "unset": [["draft"]]}})
        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "update",
          arguments: diff)

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)

        expected_meta = JSON.parse(%({"editor": "account2"}))
        row.meta.should eq expected_meta
      end
    end

    it "is a no-op on content when diff is empty" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        content = %({"a": 1, "b": 2})

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": #{content}}))

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "update",
          arguments: %({"diff": {"set": [], "unset": []}}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)

        row.content.should eq JSON.parse(content)
      end
    end

    it "handles deep nested set and unset" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": {"address": {"city": "Paris", "zip": "75001", "country": "France"}}}))

        diff = %({"set": [{"path": ["address", "city"], "value": "Bangkok"}], "unset": [["address", "zip"]]})
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "update",
          arguments: %({"diff": #{diff}}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)

        expected = JSON.parse(%({"address": {"city": "Bangkok", "country": "France"}}))
        row.content.should eq expected
      end
    end

    it "creates intermediate objects when setting a deep path" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": {}}))

        diff = %({"set": [{"path": ["a", "b", "c"], "value": "deep"}], "unset": []})
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "update",
          arguments: %({"diff": #{diff}}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)

        expected = JSON.parse(%({"a": {"b": {"c": "deep"}}}))
        row.content.should eq expected
      end
    end
  end

  # ── DELETE ────────────────────────────────────────────────────────────────

  describe "delete action" do
    it "tombstones the projection and keeps content/links/search" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        content = %({"name": "Alice"})

        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": #{content}}))

        # Stage a display_name GUC so the create trigger stores one we can
        # later assert survives the tombstone. GUCs are transaction-local, so
        # the set + mutation insert run inside one transaction.
        Facet::Database.with_transaction do |txn|
          txn.exec("SELECT set_config('harness.mutation_display_name', 'Alice', true)")
          Facet::Mutations.insert_mutation(txn, "test", "user", doc_id, "update",
            arguments: %({"diff": {"set": [{"path": ["x"], "value": 1}], "unset": []}}))
        end
        pre = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        pre.display_name.should eq("Alice")

        delete_mut_id = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "delete")

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)

        # The tombstone keeps its pre-delete payload (content/links/search
        # retention) so per-emit RBAC checks can scope-evaluate `deleted`
        # events; meta, version, state, timestamps stay. The bulk payload is
        # cleared later by `Cron::TombstoneContentPrune` after the retention
        # window.
        row.content.should eq JSON.parse(%({"x": 1, "name": "Alice"}))
        row.state.should eq delete_mut_id
        row.deleted_at.should_not be_nil
        row.version.should eq 1 # version NOT bumped
        # display_name is preserved on the tombstone so audit views can label
        # the deleted document.
        row.display_name.should eq("Alice")
      end
    end

    it "tombstones the projection (deleted_at IS NOT NULL)" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": {"x": 1}}))

        # Delete
        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "delete")

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        row.deleted_at.should_not be_nil

        # A subsequent delete is still allowed (idempotent or no-op on already tombstoned)
        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "delete")

        row2 = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        row2.deleted_at.should_not be_nil
      end
    end

    it "resurrects a deleted document ID via a new create mutation" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        # Create then delete — the projection row stays as a tombstone.
        first_create = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": {"name": "Alice"}, "meta": {"source": "seed"}}))
        delete_mut = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "delete")

        row = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        row.deleted_at.should_not be_nil
        row.state.should eq delete_mut

        # A second create with the same doc_id should resurrect the projection
        # instead of raising a primary key violation. The new content/meta,
        # version, state, search, links, and timestamps are overwritten; the
        # tombstone (`deleted_at`) is cleared.
        second_create = Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "create",
          arguments: %({"content": {"name": "Bob", "city": "Paris"}, "meta": {"source": "reborn"}}))

        row2 = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        row2.deleted_at.should be_nil
        row2.state.should eq second_create
        row2.state.should_not eq delete_mut
        row2.content.should eq JSON.parse(%({"name": "Bob", "city": "Paris"}))
        row2.meta.should eq JSON.parse(%({"source": "reborn"}))
        row2.version.should eq 1
        # The resurrected row's `created_at` is the second create's emitted_at,
        # since the new lifecycle overwrites the original creation timestamp.
        row2.created_at.should eq row2.updated_at

        # Three mutations should be present (create, delete, create), and the
        # idx counter increments sequentially across the whole lifecycle.
        rows = db.query_all(
          "SELECT action, idx FROM mutations WHERE domain = 'test' AND doc_type = 'user' AND doc_id = $1 ORDER BY idx",
          doc_id,
          as: {String, Int32}
        )
        rows.map(&.[0]).should eq(["create", "delete", "create"])
        rows.map(&.[1]).should eq([1, 2, 3])

        # Sanity: the second create's mutation id is distinct from the first.
        second_create.should_not eq first_create
      end
    end

    it "overwrites display_name when the projection is resurrected" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Database.with_transaction do |txn|
          txn.exec("SELECT set_config('harness.mutation_display_name', 'Original', true)")
          Facet::Mutations.insert_mutation(txn, "test", "user", doc_id, "create",
            arguments: %({"content": {"name": "Alice"}}))
        end
        Facet::Mutations.insert_mutation(db, "test", "user", doc_id, "delete")

        tombstoned = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        tombstoned.display_name.should eq("Original")

        Facet::Database.with_transaction do |txn|
          txn.exec("SELECT set_config('harness.mutation_display_name', 'Reborn', true)")
          Facet::Mutations.insert_mutation(txn, "test", "user", doc_id, "create",
            arguments: %({"content": {"name": "Bob"}}))
        end

        reborn = Facet::Mutations.fetch_projection(db, "test", "user", doc_id)
        reborn.deleted_at.should be_nil
        reborn.display_name.should eq("Reborn")
      end
    end
  end

  # ── SNAPSHOT ──────────────────────────────────────────────────────────────

  describe "snapshot action" do
    it "inserts a new projection when none exists" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        content = %({"name": "Snapshot"})
        meta = %({"restored": true})

        mut_id = Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "snapshot",
          arguments: %({"content": #{content}, "meta": #{meta}, "version": 5}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)

        row.content.should eq JSON.parse(content)
        row.version.should eq 5
        row.meta.should eq JSON.parse(meta)
        row.state.should eq mut_id
        row.deleted_at.should be_nil
      end
    end

    it "overwrites content, meta, version and clears deleted_at" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        # Create then delete to get a tombstoned projection
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": {"old": "data"}}))
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "delete")

        # Snapshot overwrites everything
        new_content = %({"new": "data"})
        snap_mut_id = Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "snapshot",
          arguments: %({"content": #{new_content}, "version": 10, "meta": {"note": "restored"}}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)

        row.content.should eq JSON.parse(new_content)
        row.version.should eq 10
        row.meta.should eq JSON.parse(%({"note": "restored"}))
        row.state.should eq snap_mut_id
        row.deleted_at.should be_nil
      end
    end

    it "defaults version to 1 when not provided" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "snapshot",
          arguments: %({"content": {"a": 1}}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)
        row.version.should eq 1
      end
    end

    it "uses GREATEST to prevent version regression" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "snapshot",
          arguments: %({"content": {"a": 1}, "version": 10}))

        # Attempt a snapshot with lower version
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "snapshot",
          arguments: %({"content": {"b": 2}, "version": 5}))

        row = Facet::Mutations.fetch_projection(db, "test", "doc", doc_id)
        row.version.should eq 10
      end
    end
  end

  # ── IDX auto-increment ────────────────────────────────────────────────

  describe "idx column" do
    it "starts at 1 for the first mutation on a document" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": {"a": 1}}))

        row = db.query_one("SELECT idx FROM mutations WHERE doc_id = $1", doc_id, as: Int32)
        row.should eq 1
      end
    end

    it "increments sequentially for subsequent mutations on the same document" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "create",
          arguments: %({"content": {"a": 1}}))
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "update",
          arguments: %({"diff": {"set": [{"path": ["a"], "value": 2}], "unset": []}}))
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_id, "delete")

        idxs = db.query_all("SELECT idx FROM mutations WHERE doc_id = $1 ORDER BY idx", doc_id, as: Int32)
        idxs.should eq [1, 2, 3]
      end
    end

    it "maintains independent counters for different documents" do
      Facet::Mutations.with_db do |db|
        doc_a = Facet::Util::ScriptHelpers.ulid
        doc_b = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "doc", doc_a, "create",
          arguments: %({"content": {"x": 1}}))
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_b, "create",
          arguments: %({"content": {"y": 1}}))
        Facet::Mutations.insert_mutation(db, "test", "doc", doc_a, "update",
          arguments: %({"diff": {"set": [{"path": ["x"], "value": 2}], "unset": []}}))

        idxs_a = db.query_all("SELECT idx FROM mutations WHERE doc_id = $1 ORDER BY idx", doc_a, as: Int32)
        idxs_b = db.query_all("SELECT idx FROM mutations WHERE doc_id = $1 ORDER BY idx", doc_b, as: Int32)

        idxs_a.should eq [1, 2]
        idxs_b.should eq [1]
      end
    end

    it "counts independently across different domains and doc_types" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "domain_a", "type_a", doc_id, "create",
          arguments: %({"content": {"a": 1}}))
        Facet::Mutations.insert_mutation(db, "domain_b", "type_a", doc_id, "create",
          arguments: %({"content": {"b": 1}}))

        idx_a = db.query_one("SELECT idx FROM mutations WHERE domain = 'domain_a' AND doc_id = $1", doc_id, as: Int32)
        idx_b = db.query_one("SELECT idx FROM mutations WHERE domain = 'domain_b' AND doc_id = $1", doc_id, as: Int32)

        idx_a.should eq 1
        idx_b.should eq 1
      end
    end
  end

  # ── CROSS-CUTTING ─────────────────────────────────────────────────────────

  describe "state column" do
    it "tracks the last mutation ID across all action types" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        mut1 = Facet::Mutations.insert_mutation(db, "test", "tracking", doc_id, "create",
          arguments: %({"content": {"step": 1}}))

        row1 = Facet::Mutations.fetch_projection(db, "test", "tracking", doc_id)
        row1.state.should eq mut1

        mut2 = Facet::Mutations.insert_mutation(db, "test", "tracking", doc_id, "update",
          arguments: %({"diff": {"set": [{"path": ["step"], "value": 2}], "unset": []}}))

        row2 = Facet::Mutations.fetch_projection(db, "test", "tracking", doc_id)
        row2.state.should eq mut2

        mut3 = Facet::Mutations.insert_mutation(db, "test", "tracking", doc_id, "delete")

        row3 = Facet::Mutations.fetch_projection(db, "test", "tracking", doc_id)
        row3.state.should eq mut3
      end
    end
  end

  describe "version column" do
    it "stays at 1 across create, update, and delete (only snapshot changes it)" do
      Facet::Mutations.with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid

        Facet::Mutations.insert_mutation(db, "test", "v", doc_id, "create",
          arguments: %({"content": {"x": 1}}))
        Facet::Mutations.insert_mutation(db, "test", "v", doc_id, "update",
          arguments: %({"diff": {"set": [{"path": ["x"], "value": 2}], "unset": []}}))
        Facet::Mutations.insert_mutation(db, "test", "v", doc_id, "delete")

        row = Facet::Mutations.fetch_projection(db, "test", "v", doc_id)
        row.version.should eq 1
      end
    end
  end
end
