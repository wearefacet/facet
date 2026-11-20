# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# Helper: create a simple document with a given content and return its id + first mutation id
# Uses simple lowercase-letter-only domains that pass both DoctypeDefinition and Validation regexes
DOMAIN = "audit"

def create_test_doc(db, doctype = "ATarget", content = %({"name": "initial", "count": 0}))
  ensure_domain(db, DOMAIN)

  string_type = Facet::Doctype::FieldType.parse("string")
  integer_type = Facet::Doctype::FieldType.parse("integer")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN,
    fields: {
      "name"  => Facet::Doctype::FieldDefinition.new(type: string_type),
      "count" => Facet::Doctype::FieldDefinition.new(type: integer_type),
    },
  )

  create_result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  create_result.should be_a(Facet::Document::Create::Result)

  doc_result = Facet::Document::Create.call(db, DOMAIN, doctype, content, Facet::RBAC::AuthContext.system)
  doc_result.should be_a(Facet::Document::Create::Result)
  doc = doc_result.as(Facet::Document::Create::Result)

  {id: doc.projection.id, mut_id: doc.mutation_id}
end

def update_test_doc(db, doctype, doc_id, patch)
  result = Facet::Document::Update.call(db, DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Update::Result)
  result.as(Facet::Document::Update::Result).mutation_id
end

def snapshot_count(db, doctype, doc_id)
  db.query_one(
    "SELECT COUNT(*) FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = $1 AND doc_id = $2 AND action = 'snapshot'",
    doctype, doc_id, as: Int64
  )
end

describe Facet::Audit do
  # ── Audit::List ──────────────────────────────────────────────────────────

  describe "Audit::List" do
    it "lists all mutations globally" do
      with_db do |db|
        create_test_doc(db, "LGlobal")
        result = Facet::Audit::List.call(db, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.should be_a(Array(Facet::Audit::List::MutationRecord))
        list.total.should be >= 2_i64
      end
    end

    it "filters by domain" do
      with_db do |db|
        create_test_doc(db, "LDomain")
        result = Facet::Audit::List.call(db, domain: DOMAIN, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.all? { |m| m.domain == DOMAIN }.should be_true
      end
    end

    it "filters by doctype" do
      with_db do |db|
        create_test_doc(db, "LFilterDt")
        result = Facet::Audit::List.call(db, doc_type: "LFilterDt", auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.all? { |m| m.doc_type == "LFilterDt" }.should be_true
      end
    end

    it "filters by doc_id" do
      with_db do |db|
        doc = create_test_doc(db, "LFilterId")
        result = Facet::Audit::List.call(db, doc_id: doc[:id], auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.all? { |m| m.doc_id == doc[:id] }.should be_true
      end
    end

    it "filters globally by domain using filter syntax" do
      with_db do |db|
        create_test_doc(db, "LGFilterDom")
        result = Facet::Audit::List.call(db, filters: {"domain__eq" => JSON::Any.new(DOMAIN)}, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.size.should be > 0
        list.items.all? { |m| m.domain == DOMAIN }.should be_true
      end
    end

    it "filters globally by doctype using filter syntax" do
      with_db do |db|
        create_test_doc(db, "LGFilterDt")
        result = Facet::Audit::List.call(db, filters: {"doc_type__eq" => JSON::Any.new("LGFilterDt")}, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.size.should be > 0
        list.items.all? { |m| m.doc_type == "LGFilterDt" }.should be_true
      end
    end

    it "filters globally by doc_id using filter syntax" do
      with_db do |db|
        doc = create_test_doc(db, "LGFilterId")
        result = Facet::Audit::List.call(db, filters: {"doc_id__eq" => JSON::Any.new(doc[:id])}, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.size.should be > 0
        list.items.all? { |m| m.doc_id == doc[:id] }.should be_true
      end
    end

    it "answers 422 for unknown filter keys (B-145)" do
      with_db do |db|
        create_test_doc(db, "LUnknown")
        result = Facet::Audit::List.call(db, filters: {"nonexistent__eq" => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("Unknown filter field 'nonexistent'")
        error.message.should contain("filterable")
      end
    end

    it "filters by action using filter syntax" do
      with_db do |db|
        create_test_doc(db, "LFilterAct")
        result = Facet::Audit::List.call(db, filters: {"action__eq" => JSON::Any.new("create")}, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.all? { |m| m.action == "create" }.should be_true
      end
    end

    it "filters by actioner_id using filter syntax" do
      with_db do |db|
        create_test_doc(db, "LFilterActor")
        result = Facet::Audit::List.call(db, filters: {"actioner_id__eq" => JSON::Any.new("system")}, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.all? { |m| m.actioner_id == "system" }.should be_true
      end
    end

    it "supports pagination" do
      with_db do |db|
        create_test_doc(db, "LPag")
        result = Facet::Audit::List.call(db, page: 1, items_per_page: 1, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.size.should eq 1
      end
    end

    it "sorts by emitted_at descending by default" do
      with_db do |db|
        create_test_doc(db, "LSort")
        result = Facet::Audit::List.call(db, auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        if list.items.size >= 2
          list.items[0].emitted_at.should be >= list.items[1].emitted_at
        end
      end
    end

    it "supports sort by idx ascending" do
      with_db do |db|
        create_test_doc(db, "LSortIdx")
        result = Facet::Audit::List.call(db, sort: ["idx"], auth_context: Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        if list.items.size >= 2
          list.items[0].idx.should be <= list.items[1].idx
        end
      end
    end

    # ── Authorization modes (global vs document) ────────────────────

    it "returns 403 for the global view without the wildcard read" do
      with_db do |db|
        create_test_doc(db, "LAuthGlobal")
        account_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")

        # A role that can read only the audit doctype — not `*.*` — is
        # denied the global view.
        role = Facet::RBAC::ActiveRole.new(
          role_id: "audit.noread",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: DOMAIN, path: ["LAuthGlobal"])],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(account_id, role)

        result = Facet::Audit::List.call(db, auth_context: ctx)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end
    end

    it "serves the global view with domain filters for a wildcard-read role" do
      with_db do |db|
        create_test_doc(db, "LAuthDom")
        account_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.viewer").not_nil!
        active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
        ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

        result = Facet::Audit::List.call(db, domain: DOMAIN, auth_context: ctx)
        result.should be_a(Facet::Audit::List::Result)
        list = result.as(Facet::Audit::List::Result)
        list.items.should_not be_empty
        list.items.all? { |m| m.domain == DOMAIN }.should be_true
      end
    end

    it "keeps the document-history gate non-disclosing (404 on a denied target)" do
      with_db do |db|
        doc = create_test_doc(db, "LAuthDoc")
        other = create_test_account(db, email: "audit-doc-denied@example.com", roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")

        # A role scoped to `$mine` on the target doctype — the document was
        # created by `system`, so the reader cannot see it.
        role = Facet::RBAC::ActiveRole.new(
          role_id: "audit.mine",
          visible_tags: Set.new(["default"]),
          permissions: [Facet::RBAC::Permission.new(action: "read", domain: DOMAIN, path: ["LAuthDoc"], scope: "$mine")],
        )
        ctx = Facet::RBAC::AuthContext.authenticated(other, role)

        result = Facet::Audit::List.call(db, domain: DOMAIN, doc_type: "LAuthDoc", doc_id: doc[:id], auth_context: ctx)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end
  end

  # ── Audit::Rollback ──────────────────────────────────────────────────────

  describe "Audit::Rollback" do
    it "returns an error for a non-existent mutation" do
      with_db do |db|
        result = Facet::Audit::Rollback.call(db, "nonexistent", Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 404
      end
    end

    it "rolls back to the initial create mutation (no snapshots)" do
      with_db do |db|
        doc = create_test_doc(db, "RbNoSnap")

        update_test_doc(db, "RbNoSnap", doc[:id],
          %({"name": "updated1", "count": 1}))

        result = Facet::Audit::Rollback.call(db, doc[:mut_id], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "initial"
        rb.projection.content["count"].should eq 0
      end
    end

    it "rolls back to a specific update mutation" do
      with_db do |db|
        doc = create_test_doc(db, "RbMid")
        mut1 = update_test_doc(db, "RbMid", doc[:id],
          %({"name": "step1", "count": 1}))
        update_test_doc(db, "RbMid", doc[:id],
          %({"name": "step2", "count": 2}))

        result = Facet::Audit::Rollback.call(db, mut1, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step1"
        rb.projection.content["count"].should eq 1
      end
    end

    it "rolls back using the latest snapshot when available" do
      with_db do |db|
        doc = create_test_doc(db, "RbSnap")
        mut_ids = [] of String
        15.times do |i|
          mut_id = update_test_doc(db, "RbSnap", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
          mut_ids << mut_id
        end

        # Rollback to mut_ids[12] (idx=14)
        # Latest snapshot before idx=14 is at idx=10
        result = Facet::Audit::Rollback.call(db, mut_ids[12], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step13"
        rb.projection.content["count"].should eq 13
      end
    end

    it "rolls back to a point before a snapshot" do
      with_db do |db|
        doc = create_test_doc(db, "RbB4Snap")
        mut_ids = [] of String
        12.times do |i|
          mut_id = update_test_doc(db, "RbB4Snap", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
          mut_ids << mut_id
        end

        # idx=10 is a snapshot. Rollback to mut_ids[3] (idx=5)
        result = Facet::Audit::Rollback.call(db, mut_ids[3], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step4"
        rb.projection.content["count"].should eq 4
      end
    end

    it "rolls back to a point after a snapshot" do
      with_db do |db|
        doc = create_test_doc(db, "RbAftSnap")
        mut_ids = [] of String
        15.times do |i|
          mut_id = update_test_doc(db, "RbAftSnap", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
          mut_ids << mut_id
        end

        # Rollback to mut_ids[12] (idx=14, after snapshot at idx=10)
        result = Facet::Audit::Rollback.call(db, mut_ids[12], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step13"
        rb.projection.content["count"].should eq 13
      end
    end

    it "rolls back to before a delete and restores the document" do
      with_db do |db|
        doc = create_test_doc(db, "RbDel")
        mut1 = update_test_doc(db, "RbDel", doc[:id], %({"count": 100}))

        del_result = Facet::Document::Delete.call(db, DOMAIN, "RbDel", doc[:id], Facet::RBAC::AuthContext.system)
        del_result.should be_a(Facet::Document::Delete::Result)

        read_result = Facet::Document::Read.call(db, DOMAIN, "RbDel", doc[:id], Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::ServiceError)

        # Rollback to mut1 (before the delete)
        result = Facet::Audit::Rollback.call(db, mut1, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "initial"
        rb.projection.content["count"].should eq 100
        rb.projection.deleted_at.should be_nil
      end
    end

    it "rolls back a delete mutation to the state before the delete" do
      with_db do |db|
        doc = create_test_doc(db, "RbToDel")
        update_mut_id = update_test_doc(db, "RbToDel", doc[:id], %({"count": 100}))

        del_result = Facet::Document::Delete.call(db, DOMAIN, "RbToDel", doc[:id], Facet::RBAC::AuthContext.system)
        del_result.should be_a(Facet::Document::Delete::Result)
        del_mut_id = del_result.as(Facet::Document::Delete::Result).mutation_id

        # A delete target resolves to the mutation before the delete — a
        # restore, not a tombstone persist.
        result = Facet::Audit::Rollback.call(db, del_mut_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "initial"
        rb.projection.content["count"].should eq 100
        rb.projection.deleted_at.should be_nil

        # The snapshot's cause parent is the pre-delete mutation (the state
        # restored), not the delete itself.
        cause = db.query_one(
          "SELECT cause_parent FROM mutations WHERE id = $1",
          rb.mutation_id, as: String
        )
        cause.should eq update_mut_id

        # The document is live again.
        read_result = Facet::Document::Read.call(db, DOMAIN, "RbToDel", doc[:id], Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::Document::Read::Result)
      end
    end

    it "rejects rollback to a degenerate delete with no preceding mutation" do
      with_db do |db|
        # A delete as the document's FIRST mutation — reachable only through a
        # projection/log divergence (the normal write path always creates
        # first). Simulate it with a bare delete mutation.
        doc_id = "delonly-#{Random.new.next_int.abs}"
        del_mut_id = Facet::Util::ScriptHelpers.ulid
        Facet::Mutation::Client.delete(
          db, DOMAIN, "RbDelOnly", doc_id,
          actioner_id: "spec",
          cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Request).resolve(del_mut_id),
          mutation_id: del_mut_id,
        )

        # No mutation precedes the delete — nothing to restore.
        result = Facet::Audit::Rollback.call(db, del_mut_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 422

        # No snapshot mutation was produced.
        snapshot_count(db, "RbDelOnly", doc_id).should eq 0
      end
    end

    it "records the rollback with actioner_id system:rollback" do
      with_db do |db|
        doc = create_test_doc(db, "RbTrace")
        result = Facet::Audit::Rollback.call(db, doc[:mut_id], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)

        rb_mut = db.query_one(
          "SELECT actioner_id FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = 'RbTrace' AND doc_id = $1 AND action = 'snapshot' ORDER BY idx DESC LIMIT 1",
          doc[:id], as: String
        )
        rb_mut.should eq "system:rollback"
      end
    end

    it "stamps a rollback cause with parent linkage on the rollback snapshot mutation" do
      with_db do |db|
        doc = create_test_doc(db, "RbMeta")
        result = Facet::Audit::Rollback.call(db, doc[:mut_id], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)

        rb_mut = db.query_one(
          "SELECT actioner_id, cause_kind, cause_parent, cause_trace FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = 'RbMeta' AND doc_id = $1 AND action = 'snapshot' ORDER BY idx DESC LIMIT 1",
          doc[:id], as: {String, String, String?, String}
        )
        rb_mut[1].should eq("rollback")
        rb_mut[2].should eq(doc[:mut_id])
        rb_mut[3].should_not eq("")
      end
    end
  end

  # ── periodic_snapshot trigger ─────────────────────────────────────────

  describe "periodic_snapshot trigger" do
    it "creates a snapshot when idx reaches a multiple of 10" do
      with_db do |db|
        doc = create_test_doc(db, "Snap10")
        # create=idx1, 9 updates=idx2..10 → idx10 triggers snapshot at idx11
        9.times do |i|
          update_test_doc(db, "Snap10", doc[:id], %({"count": #{i + 1}}))
        end

        # Verify a snapshot was created (it will be at idx 11 since the snapshot itself takes an idx)
        snap_count = snapshot_count(db, "Snap10", doc[:id])
        snap_count.should eq(1_i64)

        # The snapshot actioner_id should be system:snapshot
        actor = db.query_one(
          "SELECT actioner_id FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = 'Snap10' AND doc_id = $1 AND action = 'snapshot'",
          doc[:id], as: String
        )
        actor.should eq "system:snapshot"
      end
    end

    it "creates multiple snapshots at every 10th mutation" do
      with_db do |db|
        doc = create_test_doc(db, "Snap20")
        # create=idx1, 19 updates=idx2..20 → idx10, idx20 trigger snapshots
        19.times do |i|
          update_test_doc(db, "Snap20", doc[:id], %({"count": #{i + 1}}))
        end

        # Should have 2 snapshots (triggered at idx=10 and idx=20)
        snapshot_count(db, "Snap20", doc[:id]).should eq(2_i64)
      end
    end

    it "does not create a snapshot at non-multiple idx" do
      with_db do |db|
        doc = create_test_doc(db, "SnapNon")
        4.times do |i|
          update_test_doc(db, "SnapNon", doc[:id], %({"count": #{i + 1}}))
        end

        snapshot_count(db, "SnapNon", doc[:id]).should eq(0_i64)
      end
    end

    it "does not snapshot a snapshot mutation (prevents cascade)" do
      with_db do |db|
        doc = create_test_doc(db, "SnapNest")
        9.times do |i|
          update_test_doc(db, "SnapNest", doc[:id], %({"count": #{i + 1}}))
        end

        # Exactly 1 snapshot at idx=10, not 2
        snapshot_count(db, "SnapNest", doc[:id]).should eq(1_i64)
      end
    end

    it "records snapshot with actioner_id system:snapshot and system provenance" do
      with_db do |db|
        doc = create_test_doc(db, "SnapActor")
        9.times do |i|
          update_test_doc(db, "SnapActor", doc[:id], %({"count": #{i + 1}}))
        end

        row = db.query_one(
          "SELECT actioner_id, channel, cause_kind, cause_trace FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = 'SnapActor' AND doc_id = $1 AND action = 'snapshot'",
          doc[:id], as: {String, String, String, String}
        )
        row[0].should eq "system:snapshot"
        # Provenance: system-internal, root of its own causal cluster —
        # never a copy of the projection's document meta.
        row[1].should eq "internal"
        row[2].should eq "periodic_snapshot"
        row[3].should_not eq ""
      end
    end
  end

  # ── Rollback with snapshot optimization ──────────────────────────────────

  describe "rollback with snapshot optimization" do
    it "replays from the latest snapshot instead of from scratch" do
      with_db do |db|
        doc = create_test_doc(db, "OptSnap")
        mut_ids = [] of String
        25.times do |i|
          mut_id = update_test_doc(db, "OptSnap", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
          mut_ids << mut_id
        end

        # Rollback to mut_ids[22] (idx=24, after snapshots at idx=10 and idx=20)
        result = Facet::Audit::Rollback.call(db, mut_ids[22], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step23"
        rb.projection.content["count"].should eq 23
      end
    end

    it "replays from scratch when no snapshot exists before target" do
      with_db do |db|
        doc = create_test_doc(db, "OptNoSnap")
        mut_ids = [] of String
        5.times do |i|
          mut_id = update_test_doc(db, "OptNoSnap", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
          mut_ids << mut_id
        end

        # No snapshots (idx 6 is < 10). Rollback to mut_ids[2] (idx=4)
        result = Facet::Audit::Rollback.call(db, mut_ids[2], Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step3"
        rb.projection.content["count"].should eq 3
      end
    end

    it "handles rollback to a snapshot itself" do
      with_db do |db|
        doc = create_test_doc(db, "OptSelf")
        9.times do |i|
          update_test_doc(db, "OptSelf", doc[:id],
            %({"name": "step#{i + 1}", "count": #{i + 1}}))
        end

        # Find the snapshot (created by the periodic snapshot at idx=10)
        snap_id = db.query_one(
          "SELECT id FROM mutations WHERE domain = '#{DOMAIN}' AND doc_type = 'OptSelf' AND doc_id = $1 AND action = 'snapshot' AND actioner_id = 'system:snapshot'",
          doc[:id], as: String
        )

        5.times do |i|
          update_test_doc(db, "OptSelf", doc[:id],
            %({"name": "after_#{i + 1}", "count": #{10 + i + 1}}))
        end

        # Rollback to the snapshot itself
        result = Facet::Audit::Rollback.call(db, snap_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["name"].should eq "step9"
        rb.projection.content["count"].should eq 9
      end
    end
  end

  # ── Audit::Rollback cluster scope ────────────────────────────────────────
  # A cluster is the set of mutations sharing one `cause_trace`. Undoing it
  # restores every touched document to its pre-cluster state (or re-tombstones
  # documents born inside the cluster).
  describe "Audit::Rollback cluster scope" do
    it "restores a cascade subtree: every document back to its pre-delete state" do
      with_db do |db|
        restore_seeded_baseline(db)

        ensure_domain(db, DOMAIN)

        # A parent doctype with an owned child doctype (member_of) — deleting
        # the parent document cascades a tombstone onto every owned child
        # document. One causal cluster: the parent delete + the cascaded
        # child tombstones.
        parent_dt = "ClusWid#{unique_suffix(6)}"
        child_dt = "#{parent_dt}Cog"
        parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{DOMAIN}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        parent_res = Facet::Document::Create.call(db, DOMAIN, parent_dt, %({"name": "Parent"}), Facet::RBAC::AuthContext.system)
        parent_res.should be_a(Facet::Document::Create::Result)
        parent_id = parent_res.as(Facet::Document::Create::Result).projection.id

        child_ids = ["Cog A", "Cog B"].map do |label|
          cres = Facet::Document::Create.call(
            db, DOMAIN, child_dt, %({"label": "#{label}"}), Facet::RBAC::AuthContext.system,
            meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
          )
          cres.should be_a(Facet::Document::Create::Result)
          cres.as(Facet::Document::Create::Result).projection.id
        end

        # Delete the parent — one causal cluster.
        del_result = Facet::Document::Delete.call(db, DOMAIN, parent_dt, parent_id, Facet::RBAC::AuthContext.system)
        del_result.should be_a(Facet::Document::Delete::Result)
        root_mut_id = del_result.as(Facet::Document::Delete::Result).mutation_id

        child_ids.each do |cid|
          tombstoned = Facet::Mutation::Client.fetch_projection(db, DOMAIN, child_dt, cid)
          tombstoned.deleted_at.should_not be_nil
        end

        # Cluster undo on the root delete.
        result = Facet::Audit::Rollback.call(db, root_mut_id, Facet::RBAC::AuthContext.system, scope: Facet::Audit::Rollback::Scope::Cluster)
        result.should be_a(Facet::Audit::Rollback::ClusterResult)
        cr = result.as(Facet::Audit::Rollback::ClusterResult)
        # The cascade tombstoned three documents: the parent and its two
        # owned children.
        cr.documents.size.should eq 3
        outcomes = cr.documents.map(&.outcome)
        outcomes.uniq.should eq(["restored"])
        doc_types = cr.documents.map(&.doc_type)
        doc_types.uniq.sort!.should eq([child_dt, parent_dt].sort)

        # Every undo mutation shares the undo's own trace and its own row id.
        undo_mutations = db.query_all(
          "SELECT id, action FROM mutations WHERE cause_trace = $1",
          cr.trace, as: {String, String}
        )
        undo_mutations.size.should eq 3
        undo_mutations.all? { |(_, action)| action == "snapshot" }.should be_true
        undo_ids = undo_mutations.map(&.[0])
        undo_ids.uniq.size.should eq 3

        # All three documents are live again.
        parent_proj = Facet::Mutation::Client.fetch_projection(db, DOMAIN, parent_dt, parent_id)
        parent_proj.deleted_at.should be_nil
        child_ids.each do |cid|
          child_proj = Facet::Mutation::Client.fetch_projection(db, DOMAIN, child_dt, cid)
          child_proj.deleted_at.should be_nil
        end
      end
    end

    it "deletes a document born inside the cluster and restores the touched one" do
      with_db do |db|
        ensure_domain(db, DOMAIN)

        # Doc A: a normal create, then an update stamped into a synthetic
        # cluster (mirrors an action's nested write).
        a = create_test_doc(db, "ClusTouch")
        trace = Facet::Util::ScriptHelpers.ulid
        a_upd_id = Facet::Mutation::Client.update(
          db, DOMAIN, "ClusTouch", a[:id],
          %({"set": [{"path": ["name"], "value": "changed"}]}),
          actioner_id: "spec",
          cause: Facet::Mutation::Cause.new(kind: Facet::Mutation::CauseKind::Request, trace: trace),
        )

        # Doc B: born inside the cluster — its first (and only) mutation
        # carries the same trace.
        born_id = Facet::Util::ScriptHelpers.ulid
        Facet::Mutation::Client.create(
          db, DOMAIN, "ClusBorn", doc_id: born_id,
          content: %({"name": "born"}),
          actioner_id: "spec",
          cause: Facet::Mutation::Cause.new(kind: Facet::Mutation::CauseKind::Request, trace: trace),
        )

        result = Facet::Audit::Rollback.call(db, a_upd_id, Facet::RBAC::AuthContext.system, scope: Facet::Audit::Rollback::Scope::Cluster)
        result.should be_a(Facet::Audit::Rollback::ClusterResult)
        cr = result.as(Facet::Audit::Rollback::ClusterResult)
        cr.documents.size.should eq 2

        restored_undo = cr.documents.find { |d| d.doc_id == a[:id] } || raise "missing restore undo for #{a[:id]}"
        restored_undo.outcome.should eq "restored"
        born_undo = cr.documents.find { |d| d.doc_id == born_id } || raise "missing delete undo for #{born_id}"
        born_undo.outcome.should eq "deleted"

        # A is back to its pre-cluster content; B is tombstoned.
        a_proj = Facet::Mutation::Client.fetch_projection(db, DOMAIN, "ClusTouch", a[:id])
        a_proj.content["name"].should eq "initial"
        b_proj = Facet::Mutation::Client.fetch_projection(db, DOMAIN, "ClusBorn", born_id)
        b_proj.deleted_at.should_not be_nil
      end
    end

    it "denies the whole cluster when the caller holds no update rights (403)" do
      with_db do |db|
        restore_seeded_baseline(db)

        ensure_domain(db, DOMAIN)

        # Parent doctype with an owned child doctype (member_of). Deleting
        # the parent document produces the cluster the rollback targets.
        parent_dt = "ClusDeny#{unique_suffix(6)}"
        child_dt = "#{parent_dt}Cog"
        parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
        Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
        child_defn = %({"doctype": "#{child_dt}", "domain": "#{DOMAIN}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}})
        Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

        parent_res = Facet::Document::Create.call(db, DOMAIN, parent_dt, %({"name": "Parent"}), Facet::RBAC::AuthContext.system)
        parent_res.should be_a(Facet::Document::Create::Result)
        parent_id = parent_res.as(Facet::Document::Create::Result).projection.id
        child_res = Facet::Document::Create.call(
          db, DOMAIN, child_dt, %({"label": "Cog"}), Facet::RBAC::AuthContext.system,
          meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
        )
        child_res.should be_a(Facet::Document::Create::Result)
        child_id = child_res.as(Facet::Document::Create::Result).projection.id

        del_result = Facet::Document::Delete.call(db, DOMAIN, parent_dt, parent_id, Facet::RBAC::AuthContext.system)
        del_result.should be_a(Facet::Document::Delete::Result)
        root_mut_id = del_result.as(Facet::Document::Delete::Result).mutation_id

        # A denied principal authorizes nothing — no root-document right and
        # no per-document right, so the whole undo is refused.
        result = Facet::Audit::Rollback.call(db, root_mut_id, Facet::RBAC::AuthContext.denied, scope: Facet::Audit::Rollback::Scope::Cluster)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 403
        err.message.should eq "rollback refused: your role cannot write every document in the cluster"

        # Nothing was applied — the tombstones stand.
        tombstoned = Facet::Mutation::Client.fetch_projection(db, DOMAIN, child_dt, child_id)
        tombstoned.deleted_at.should_not be_nil
      end
    end
  end
end
