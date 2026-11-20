# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document"
require "../../src/audit"
require "../../src/rbac"
require "../../src/mutation/client"

# Valid 32-byte master key for building a Config with coalescing enabled.
# The secret store fails closed on a missing or short key.
COALESCE_MASTER_KEY = "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="

COALESCE_DOMAIN = "coalescetest"

# ── Config swap ───────────────────────────────────────────────────────────
#
# The test config ships `coalesce_window_minutes: 0` so the rest of the suite
# is unaffected by folding writes. These specs swap the config singleton with
# a bespoke window and restore it after.

def with_coalesce_window(minutes : Int32, &)
  original = Facet::Config.instance
  Facet::Config.instance = Facet::Config.new(
    artifact_grant_secret: "test-secret",
    secrets: Facet::Secrets::Config.new(master_key: COALESCE_MASTER_KEY),
    mutations: Facet::Config::MutationsConfig.new(coalesce_window_minutes: minutes),
    # The suite runs with the staleness bound disabled; a swap that
    # defaulted it to 300 would let the process caches rebuild from the
    # truncated projections mid-suite.
    cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
  )
  yield
ensure
  Facet::Config.instance = original || Facet::Config.instance
end

# ── Setup helpers ─────────────────────────────────────────────────────────

def register_coalesce_doctype(db : DB::Connection) : String
  ensure_domain(db, COALESCE_DOMAIN)
  doctype = "T#{unique_suffix}"
  Facet::Doctype::DefinitionStore.invalidate("#{COALESCE_DOMAIN}.#{doctype}")
  create_schema = %({"doctype": "#{doctype}", "domain": "#{COALESCE_DOMAIN}", "fields": {"title": {"type": "string"}, "body": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
  raise "coalesce spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  doctype
end

def coalesce_create_doc(db : DB::Connection, doctype : String, body : String = %({"title": "Original", "body": "v0"})) : String
  res = Facet::Document::Create.call(db, COALESCE_DOMAIN, doctype, body, Facet::RBAC::AuthContext.system)
  expect_create_success(res).projection.id
end

def coalesce_update(db : DB::Connection, doctype : String, doc_id : String, patch : String, actioner_id : String? = nil)
  Facet::Document::Update.call(
    db, COALESCE_DOMAIN, doctype, doc_id, patch,
    Facet::RBAC::AuthContext.system,
    actioner_id: actioner_id,
  )
end

def coalesce_rows(db : DB::Connection, doctype : String, doc_id : String) : Array({String, Int32, String})
  db.query_all(
    "SELECT id, idx, action FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx ASC",
    COALESCE_DOMAIN, doctype, doc_id,
    as: {String, Int32, String}
  )
end

def stored_diff(db : DB::Connection, doctype : String, doc_id : String, mut_id : String) : JSON::Any
  db.query_one(
    "SELECT arguments->'diff' FROM mutations WHERE id = $1",
    mut_id, as: JSON::Any
  )
end

# A session-tier auth context with an update grant on the doctype — a
# different channel from the system context's `internal`.
def coalesce_session_context(db : DB::Connection, doctype : String) : Facet::RBAC::AuthContext
  role_id = "coalesce_role_#{unique_suffix}"
  account_id = "coalesce_actor_#{unique_suffix}"
  create_role_projection(db, role_id, [permission_json("update", "#{COALESCE_DOMAIN}.#{doctype}")])
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# ── Specs ─────────────────────────────────────────────────────────────────

describe Facet::Document::Coalesce do
  describe "write-time coalescing" do
    it "merges consecutive same-actor updates into one row with an idx gap" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          res1 = coalesce_update(db, doctype, doc_id, %({"title": "First", "body": "v1"}))
          res1.should be_a(Facet::Document::Update::Result)
          mut1 = res1.as(Facet::Document::Update::Result).mutation_id

          res2 = coalesce_update(db, doctype, doc_id, %({"title": "Second", "body": "v2"}))
          res2.should be_a(Facet::Document::Update::Result)
          result2 = res2.as(Facet::Document::Update::Result)
          mut2 = result2.mutation_id

          # One create + one merged update row; the previous update's idx
          # stays vacant (…, 1, 3 — the gap clue).
          rows = coalesce_rows(db, doctype, doc_id)
          rows.map(&.[1]).should eq([1, 3])
          rows[1][0].should eq(mut2)
          rows[1][2].should eq("update")
          mut2.should_not eq(mut1)

          # The merged row carries the composed X→Z diff: applying it to the
          # pre-first-write content yields the new content.
          x = JSON.parse(%({"title": "Original", "body": "v0"}))
          composed = Facet::Mutation::JsonDiff::Result.from_json(stored_diff(db, doctype, doc_id, mut2))
          Facet::Mutation::JsonDiff.apply_diff(x, JSON.parse(composed.to_json)).should eq(
            JSON.parse(%({"title": "Second", "body": "v2"}))
          )

          # The projection is at the new content; state is the new id.
          proj = result2.projection
          proj.content["title"].as_s.should eq("Second")
          proj.content["body"].as_s.should eq("v2")
          proj.state.should eq(mut2)
          proj.meta["parent_id"]?.should be_nil
        end
      end
    end

    it "emits exactly one event for the merged write" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"body": "v1"}))
          Facet::Event::Publisher.flush
          event_manager.clear!

          res = coalesce_update(db, doctype, doc_id, %({"body": "v2"}))
          mut_id = res.as(Facet::Document::Update::Result).mutation_id
          Facet::Event::Publisher.flush

          events = event_manager.events_for("FACET:RESOURCE:#{COALESCE_DOMAIN}:#{doctype}")
          updated = events.select { |m| m.headers["event"]?.try(&.as_s?) == "updated" }
          updated.size.should eq(1)
          updated.first.headers["mutation_id"].as_s.should eq(mut_id)
        end
      end
    end

    it "chains merges across a burst" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          5.times do |i|
            res = coalesce_update(db, doctype, doc_id, %({"body": "v#{i + 1}"}))
            res.should be_a(Facet::Document::Update::Result)
          end

          # One create + one merged row holding the X→Z5 diff. The first
          # update does not merge (the last row is the create), then each
          # merge takes MAX(idx)+1 and deletes the folded row: 2 → 3 → 4 →
          # 5 → 6.
          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(2)
          rows.map(&.[1]).should eq([1, 6])

          x = JSON.parse(%({"title": "Original", "body": "v0"}))
          composed = Facet::Mutation::JsonDiff::Result.from_json(stored_diff(db, doctype, doc_id, rows[1][0]))
          Facet::Mutation::JsonDiff.apply_diff(x, JSON.parse(composed.to_json)).should eq(
            JSON.parse(%({"title": "Original", "body": "v5"}))
          )

          proj = Facet::Mutation::Client.fetch_projection(db, COALESCE_DOMAIN, doctype, doc_id)
          proj.content["body"].as_s.should eq("v5")
        end
      end
    end

    it "does not merge when the actor differs" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          coalesce_update(db, doctype, doc_id, %({"body": "v1"}), actioner_id: "actor-one")
          res = coalesce_update(db, doctype, doc_id, %({"body": "v2"}), actioner_id: "actor-two")
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3) # create + two updates
          rows.map(&.[1]).should eq([1, 2, 3])
        end
      end
    end

    it "does not merge when the channel differs" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          # First write: system context → channel internal.
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          # Second write: session context → channel session.
          ctx = coalesce_session_context(db, doctype)
          res = Facet::Document::Update.call(db, COALESCE_DOMAIN, doctype, doc_id, %({"body": "v2"}), ctx)
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3)
          channels = db.query_all(
            "SELECT channel FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx ASC",
            COALESCE_DOMAIN, doctype, doc_id, as: String
          )
          channels.should eq(["internal", "internal", "session"])
        end
      end
    end

    it "does not merge when the window expired" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          # Age the last row beyond the window.
          db.exec(
            "UPDATE mutations SET emitted_at = now() - make_interval(mins => 10) WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'update'",
            COALESCE_DOMAIN, doctype, doc_id
          )

          res = coalesce_update(db, doctype, doc_id, %({"body": "v2"}))
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3)
        end
      end
    end

    it "does not merge when the last row is a create" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          # The first update after the create — last row is the create.
          res = coalesce_update(db, doctype, doc_id, %({"body": "v1"}))
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(2)
          rows.map(&.[1]).should eq([1, 2]) # no gap: nothing merged
        end
      end
    end

    it "does not merge when the last row is a snapshot" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          # A restore writes a snapshot row (rollback cause).
          list = Facet::Audit::List.call(
            db, domain: COALESCE_DOMAIN, doc_type: doctype, doc_id: doc_id,
            auth_context: Facet::RBAC::AuthContext.system,
          ).as(Facet::Audit::List::Result)
          create_mut = list.items.find!(&.action.==("create")).id
          Facet::Audit::Rollback.call(db, create_mut, Facet::RBAC::AuthContext.system).should be_a(Facet::Audit::Rollback::Result)

          res = coalesce_update(db, doctype, doc_id, %({"body": "v2"}))
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(4) # create + update + rollback snapshot + update
          rows[2][2].should eq("snapshot")
        end
      end
    end

    it "does not merge when the last row's cluster has more members" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          # Write an update row whose cause_trace is shared with another row
          # (the shape an action or hook cluster produces).
          shared_trace = Facet::Util::ScriptHelpers.ulid
          root_cause = Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Action,
            name: "promote",
            trace: shared_trace,
          )
          Facet::Mutation::Client.update(
            db, COALESCE_DOMAIN, doctype, doc_id,
            diff_json: %({"set": [{"path": ["body"], "value": "driven"}], "unset": []}),
            actioner_id: "system",
            cause: root_cause,
            mutation_id: Facet::Util::ScriptHelpers.ulid,
          )
          # The cluster's root row on another document shares the trace.
          other_id = coalesce_create_doc(db, doctype, %({"title": "Other", "body": "o"}))
          Facet::Mutation::Client.create(
            db, COALESCE_DOMAIN, doctype,
            doc_id: other_id,
            content: %({"title": "Other", "body": "o"}),
            actioner_id: "system",
            cause: Facet::Mutation::Cause.new(
              kind: Facet::Mutation::CauseKind::Action,
              name: "promote",
              trace: shared_trace,
            ),
          )

          res = coalesce_update(db, doctype, doc_id, %({"body": "after"}))
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3) # create + driven update + the new update
          rows.map(&.[1]).should eq([1, 2, 3])
        end
      end
    end

    it "does not merge when the last row is an action update" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          # The shape Action.persist_document_update produces: one update
          # row carrying the action cause, trace = its own id (no nested
          # document.* writes). Same actor as the write below — only the
          # cause must block the fold.
          action_mut_id = Facet::Util::ScriptHelpers.ulid
          Facet::Mutation::Client.update(
            db, COALESCE_DOMAIN, doctype, doc_id,
            diff_json: %({"set": [{"path": ["body"], "value": "confirmed"}], "unset": []}),
            actioner_id: "actor-one",
            cause: Facet::Mutation::Cause.new(
              kind: Facet::Mutation::CauseKind::Action,
              name: "confirm",
            ).resolve(action_mut_id),
            mutation_id: action_mut_id,
          )

          res = coalesce_update(db, doctype, doc_id, %({"body": "after"}), actioner_id: "actor-one")
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3) # create + action update + the new update
          rows.map(&.[1]).should eq([1, 2, 3])

          # The action row keeps its cause — the action survives in the log.
          list = Facet::Audit::List.call(
            db, domain: COALESCE_DOMAIN, doc_type: doctype, doc_id: doc_id,
            auth_context: Facet::RBAC::AuthContext.system,
          ).as(Facet::Audit::List::Result)
          action_row = list.items.find!(&.cause_name.==("confirm"))
          action_row.cause_kind.should eq("action")
          action_row.action.should eq("update")
        end
      end
    end

    it "does not merge an update driven by an action" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          # A plain request update first.
          coalesce_update(db, doctype, doc_id, %({"body": "v1"}), actioner_id: "actor-one")

          # The nested document.update shape: the write inside the action
          # script carries the action's child cause (parent = the action's
          # pre-generated mutation id). It must land as its own row, not
          # fold into the request update and mislabel it.
          action_mut_id = Facet::Util::ScriptHelpers.ulid
          child_cause = Facet::Mutation::Cause.new(
            kind: Facet::Mutation::CauseKind::Action,
            name: "confirm",
          ).child_of(action_mut_id)
          res = Facet::Document::Update.call(
            db, COALESCE_DOMAIN, doctype, doc_id, %({"body": "v2"}),
            Facet::RBAC::AuthContext.system,
            actioner_id: "actor-one", cause: child_cause,
          )
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3) # create + v1 + v2 — no fold
          rows.map(&.[1]).should eq([1, 2, 3])

          list = Facet::Audit::List.call(
            db, domain: COALESCE_DOMAIN, doc_type: doctype, doc_id: doc_id,
            auth_context: Facet::RBAC::AuthContext.system,
          ).as(Facet::Audit::List::Result)
          request_row = list.items.find! { |m| m.action == "update" && m.cause_kind == "request" }
          request_row.cause_kind.should eq("request")
        end
      end
    end

    it "does not merge an assistant write into a request update" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          coalesce_update(db, doctype, doc_id, %({"body": "v1"}), actioner_id: "actor-one")

          # The assistant tool shape: a root assistant cause (the workspace
          # registrar stamps Cause.root(Assistant)). Same actor and channel
          # as the request write — only the cause must block the fold.
          res = Facet::Document::Update.call(
            db, COALESCE_DOMAIN, doctype, doc_id, %({"body": "v2"}),
            Facet::RBAC::AuthContext.system,
            actioner_id: "actor-one",
            cause: Facet::Mutation::Cause.root(
              Facet::Mutation::CauseKind::Assistant,
              name: "domain-builder",
            ),
          )
          res.should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3) # create + v1 + v2 — no fold
          rows.map(&.[1]).should eq([1, 2, 3])
        end
      end
    end

    it "coalesce_window_minutes = 0 disables coalescing" do
      with_coalesce_window(0) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)

          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)
          coalesce_update(db, doctype, doc_id, %({"body": "v2"})).should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          rows.size.should eq(3)
          rows.map(&.[1]).should eq([1, 2, 3])
        end
      end
    end

    it "rolls back to a merged row and restores the end state" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"title": "First", "body": "v1"})).should be_a(Facet::Document::Update::Result)
          res = coalesce_update(db, doctype, doc_id, %({"title": "Second", "body": "v2"}))
          merged_mut = res.as(Facet::Document::Update::Result).mutation_id

          # Roll back to the merged row: the replay applies the composed
          # X→Z diff and restores state Z.
          rb = Facet::Audit::Rollback.call(db, merged_mut, Facet::RBAC::AuthContext.system)
          rb.should be_a(Facet::Audit::Rollback::Result)
          proj = rb.as(Facet::Audit::Rollback::Result).projection
          proj.content["title"].as_s.should eq("Second")
          proj.content["body"].as_s.should eq("v2")
        end
      end
    end

    it "does not leak the bypass GUC: a delete after a fold still writes the tombstone" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          # A standalone update — the row the in-transaction update folds.
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          # One transaction: the update folds the standalone row, then the
          # delete joins the same transaction. The fold's bypass GUC must
          # not survive into the delete — the tombstone is trigger-driven.
          deleted = nil
          Facet::Database.with_transaction(db) do |txn|
            coalesce_update(txn, doctype, doc_id, %({"body": "v2"})).should be_a(Facet::Document::Update::Result)
            deleted = Facet::Document::Delete.call(txn, COALESCE_DOMAIN, doctype, doc_id)
          end
          deleted.should be_a(Facet::Document::Delete::Result)

          # (a) The delete mutation exists, (b) the projection is tombstoned.
          rows = coalesce_rows(db, doctype, doc_id)
          rows.map(&.[2]).should eq(["create", "update", "delete"])
          deleted_at = db.query_one(
            "SELECT deleted_at FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
            COALESCE_DOMAIN, doctype, doc_id, as: Time?
          )
          deleted_at.should_not be_nil
        end
      end
    end

    it "does not leak the bypass GUC: a create after a fold still writes its projection row" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          created = nil
          Facet::Database.with_transaction(db) do |txn|
            coalesce_update(txn, doctype, doc_id, %({"body": "v2"})).should be_a(Facet::Document::Update::Result)
            created = Facet::Document::Create.call(txn, COALESCE_DOMAIN, doctype, %({"title": "Sibling", "body": "s0"}))
          end
          created.should be_a(Facet::Document::Create::Result)

          sibling_id = created.as(Facet::Document::Create::Result).projection.id
          sibling = Facet::Mutation::Client.fetch_projection(db, COALESCE_DOMAIN, doctype, sibling_id)
          sibling.content["title"].as_s.should eq("Sibling")
        end
      end
    end

    it "keeps an outer bypass in force after a fold" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)

          # An outer caller sets the bypass itself; the fold must restore
          # that value, not clear it.
          bypass = nil
          Facet::Database.with_transaction(db) do |txn|
            txn.exec("SELECT set_config($1, $2, true)", "harness.bypass_projection_triggers", "outer")
            coalesce_update(txn, doctype, doc_id, %({"body": "v2"})).should be_a(Facet::Document::Update::Result)
            bypass = txn.query_one("SELECT current_setting($1, true)", "harness.bypass_projection_triggers", as: String?)
          end
          bypass.should eq("outer")
        end
      end
    end

    it "reads aggregate history across a merged row (parent_doc_id preserved)" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          doc_id = coalesce_create_doc(db, doctype)
          coalesce_update(db, doctype, doc_id, %({"body": "v1"})).should be_a(Facet::Document::Update::Result)
          coalesce_update(db, doctype, doc_id, %({"body": "v2"})).should be_a(Facet::Document::Update::Result)

          rows = coalesce_rows(db, doctype, doc_id)
          merged_id = rows[1][0]

          # parent_doc_id stays stamped on the merged row — the aggregate
          # history read keys on it. The doc is a root here, so NULL.
          parent = db.query_one(
            "SELECT parent_doc_id FROM mutations WHERE id = $1", merged_id, as: String?
          )
          parent.should be_nil

          # The audit list reads across the merged row without a gap error.
          list = Facet::Audit::List.call(
            db, domain: COALESCE_DOMAIN, doc_type: doctype, doc_id: doc_id,
            auth_context: Facet::RBAC::AuthContext.system,
          )
          list.should be_a(Facet::Audit::List::Result)
          items = list.as(Facet::Audit::List::Result).items
          items.size.should eq(2)
          items.map(&.action).sort!.should eq(["create", "update"])
        end
      end
    end

    it "keeps long-text patch composition correct on the merged row" do
      with_coalesce_window(3) do
        with_db do |db|
          doctype = register_coalesce_doctype(db)
          base = (1..60).map { |i| "line #{i}\n" }.join
          v1 = base.gsub("line 30\n", "line thirty\n")
          v2 = v1.gsub("line 40\n", "line forty\n")

          doc_id = coalesce_create_doc(db, doctype, %({"title": "Doc", "body": #{base.inspect}}))
          coalesce_update(db, doctype, doc_id, %({"body": #{v1.inspect}})).should be_a(Facet::Document::Update::Result)
          res = coalesce_update(db, doctype, doc_id, %({"body": #{v2.inspect}}))
          merged_mut = res.as(Facet::Document::Update::Result).mutation_id

          # The projection holds the second write's content.
          proj = Facet::Mutation::Client.fetch_projection(db, COALESCE_DOMAIN, doctype, doc_id)
          proj.content["body"].as_s.should eq(v2)

          # The stored composed diff maps X→Z directly.
          x = JSON.parse(%({"title": "Doc", "body": #{base.inspect}}))
          composed = Facet::Mutation::JsonDiff::Result.from_json(stored_diff(db, doctype, doc_id, merged_mut))
          Facet::Mutation::JsonDiff.apply_diff(x, JSON.parse(composed.to_json)).should eq(
            JSON.parse(%({"title": "Doc", "body": #{v2.inspect}}))
          )
        end
      end
    end
  end
end
