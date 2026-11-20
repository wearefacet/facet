# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/mutation/client"
require "../../src/document/search"

# These specs test the low-level Mutation::Client methods directly against
# the SQL trigger pipeline. Each test creates a fresh doc_id to avoid
# cross-contamination from the PL/pgSQL trigger state.

module Facet::Mutation
  describe Client do
    # ── create ──────────────────────────────────────────────────────────

    describe ".create" do
      it "inserts a create mutation and creates a projection" do
        with_db do |db|
          doc_id = "client_test_#{Facet::Util::ScriptHelpers.ulid}"
          mut_id = Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice"}), actioner_id: "spec")

          mut_id.should_not be_empty

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.domain.should eq("test")
          proj.doc_type.should eq("TestDoc")
          proj.id.should eq(doc_id)
          proj.content["name"].as_s.should eq("Alice")
          proj.deleted_at.should be_nil
          proj.version.should eq(1)
        end
      end

      it "auto-generates a ULID doc_id when none is provided" do
        with_db do |db|
          mut_id = Client.create(db, "test", "TestDoc", content: %({"name": "AutoID"}), actioner_id: "spec")
          mut_id.should_not be_empty
        end
      end

      it "inserts a create mutation with a custom doc_id" do
        with_db do |db|
          doc_id = "custom_doc_#{Facet::Util::ScriptHelpers.ulid}"
          mut_id = Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"custom": true}), actioner_id: "spec")
          mut_id.should_not be_empty

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.id.should eq(doc_id)
          proj.content["custom"].as_bool.should be_true
        end
      end
    end

    # ── update ──────────────────────────────────────────────────────────

    describe ".update" do
      it "applies an incremental update via JsonDiff" do
        with_db do |db|
          doc_id = "client_test_upd_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice", "age": 30}), actioner_id: "spec")

          diff = %({"set": [{"path": ["age"], "value": 31}], "unset": []})
          mut_id = Client.update(db, "test", "TestDoc", doc_id, diff_json: diff, actioner_id: "spec")
          mut_id.should_not be_empty

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.content["name"].as_s.should eq("Alice")
          proj.content["age"].as_i.should eq(31)
        end
      end

      it "supports unsetting fields" do
        with_db do |db|
          doc_id = "client_test_unset_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice", "temp": "remove_me"}), actioner_id: "spec")

          diff = %({"set": [], "unset": [["temp"]]})
          Client.update(db, "test", "TestDoc", doc_id, diff_json: diff, actioner_id: "spec")

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.content["temp"]?.should be_nil
          proj.content["name"].as_s.should eq("Alice")
        end
      end

      it "raises ArgumentError for empty diff (no set, no unset)" do
        with_db do |db|
          doc_id = "client_test_emptydiff_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice"}), actioner_id: "spec")

          empty_diff = %({"set": [], "unset": []})
          expect_raises(ArgumentError, /empty update diff/i) do
            Client.update(db, "test", "TestDoc", doc_id, diff_json: empty_diff, actioner_id: "spec")
          end

          # Verify no mutation was inserted and projection is unchanged
          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.content["name"].as_s.should eq("Alice")
        end
      end

      it "raises ArgumentError for diff with only empty set" do
        with_db do |db|
          doc_id = "client_test_emptyset_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice"}), actioner_id: "spec")

          diff = %({"set": [], "unset": []})
          expect_raises(ArgumentError, /empty update diff/i) do
            Client.update(db, "test", "TestDoc", doc_id, diff_json: diff, actioner_id: "spec")
          end
        end
      end
    end

    # ── snapshot_mutation ──────────────────────────────────────────────

    describe ".snapshot_mutation" do
      it "overwrites the full projection content" do
        with_db do |db|
          doc_id = "client_test_snap_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Original"}), actioner_id: "spec")

          mut_id = Client.snapshot_mutation(db, "test", "TestDoc", doc_id, content: %({"name": "Snapshot", "version": 2}), version: 2, actioner_id: "spec")
          mut_id.should_not be_empty

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.content["name"].as_s.should eq("Snapshot")
          proj.version.should eq(2)
        end
      end

      it "sets version correctly on snapshot" do
        with_db do |db|
          doc_id = "client_test_snap_v_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "A"}), actioner_id: "spec")

          # Snapshot with a higher version
          Client.snapshot_mutation(db, "test", "TestDoc", doc_id, content: %({"name": "B"}), version: 5, actioner_id: "spec")

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.version.should eq(5)
        end
      end
    end

    # ── delete ──────────────────────────────────────────────────────────

    describe ".delete" do
      it "soft-deletes a document by setting deleted_at" do
        with_db do |db|
          doc_id = "client_test_del_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "Alice"}), actioner_id: "spec")

          mut_id = Client.delete(db, "test", "TestDoc", doc_id, actioner_id: "spec")
          mut_id.should_not be_empty

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.deleted_at.should_not be_nil
        end
      end

      it "keeps content, links, and search after delete (tombstone retention)" do
        with_db do |db|
          doc_id = "client_test_del2_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "ToDelete"}), actioner_id: "spec")
          Client.delete(db, "test", "TestDoc", doc_id, actioner_id: "spec")

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          # The tombstone keeps its pre-delete payload so per-emit RBAC
          # checks can scope-evaluate `deleted` events. The payload is
          # cleared later by `Cron::TombstoneContentPrune` after the
          # retention window.
          proj.content.should eq(JSON.parse(%({"name": "ToDelete"})))
          proj.deleted_at.should_not be_nil
        end
      end
    end

    # ── fetch_content ───────────────────────────────────────────────────

    describe ".fetch_content" do
      it "returns only the content column" do
        with_db do |db|
          doc_id = "client_test_fc_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"x": 1, "y": 2}), actioner_id: "spec")

          content = Client.fetch_content(db, "test", "TestDoc", doc_id)
          content["x"].as_i.should eq(1)
          content["y"].as_i.should eq(2)
        end
      end
    end

    # ── fetch_projection ────────────────────────────────────────────────

    describe ".fetch_projection" do
      it "returns the full projection record" do
        with_db do |db|
          doc_id = "client_test_fp_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"k": "v"}), actioner_id: "spec")

          proj = Client.fetch_projection(db, "test", "TestDoc", doc_id)
          proj.should be_a(Client::Projection)
          proj.domain.should eq("test")
          proj.doc_type.should eq("TestDoc")
          proj.id.should eq(doc_id)
          proj.deleted_at.should be_nil
          proj.updated_at.should be_a(Time)
          proj.created_at.should be_a(Time)
        end
      end

      it "raises DB::NoResultsError for non-existent document" do
        with_db do |db|
          expect_raises(DB::NoResultsError) do
            Client.fetch_projection(db, "test", "TestDoc", "does_not_exist")
          end
        end
      end
    end

    # ── projection_exists? ──────────────────────────────────────────────

    describe ".projection_exists?" do
      it "returns true when the projection exists" do
        with_db do |db|
          doc_id = "client_test_pex_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: "{}", actioner_id: "spec")

          Client.projection_exists?(db, "test", "TestDoc", doc_id).should be_true
        end
      end

      it "returns false when the projection does not exist" do
        with_db do |db|
          Client.projection_exists?(db, "test", "TestDoc", "nonexistent").should be_false
        end
      end
    end

    # ── cause stamping ───────────────────────────────────────────────

    describe "cause metadata" do
      it "writes the cause columns and leaves the document arguments untouched" do
        with_db do |db|
          doc_id = "client_test_cause_#{Facet::Util::ScriptHelpers.ulid}"
          Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "A"}), actioner_id: "spec", cause: Cause.root(CauseKind::Request, event: "test.event"))

          row = db.query_one(
            "SELECT arguments, cause_event FROM mutations WHERE doc_id = $1 AND action = 'create'",
            doc_id, as: {JSON::Any, String}
          )
          # Document payload (arguments) must NOT carry the cause —
          # provenance lives on the typed provenance columns.
          row[0].as_h.has_key?("_reason").should be_false
          row[1].should eq("test.event")
        end
      end

      it "stamps a default request cause with trace when no cause is given" do
        with_db do |db|
          doc_id = "client_test_nocause_#{Facet::Util::ScriptHelpers.ulid}"
          mut_id = Client.create(db, "test", "TestDoc", doc_id: doc_id, content: %({"name": "A"}), actioner_id: "spec")

          row = db.query_one(
            "SELECT channel, cause_kind, cause_trace FROM mutations WHERE doc_id = $1 AND action = 'create'",
            doc_id, as: {String, String, String}
          )
          row[0].should eq("internal")
          row[1].should eq("request")
          row[2].should eq(mut_id)
        end
      end
    end
  end
end
