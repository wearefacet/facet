# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# Specs for the rollback snapshot's projection meta (B-143) and the
# cascade restore of composition children (B-144). The parent / child /
# grandchild trio mirrors the cluster-scope fixtures in
# `spec/audit/audit_spec.cr`.
RB_META_DOMAIN = "audit"

# Builds the composition doctype trio: parent (aggregate root) → child →
# grandchild. Every link is a `member_of` ownership, so deleting the
# parent cascades a tombstone onto both levels. Returns the doctype names.
def rb_meta_build_trio(db)
  restore_seeded_baseline(db)
  ensure_domain(db, RB_META_DOMAIN)

  suffix = unique_suffix(6)
  parent_dt = "RbPar#{suffix}"
  child_dt = "RbChd#{suffix}"
  grand_dt = "RbGrd#{suffix}"

  parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{RB_META_DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  child_defn = %({"doctype": "#{child_dt}", "domain": "#{RB_META_DOMAIN}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}, "children": {"items": {"doctype": "#{grand_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  grand_defn = %({"doctype": "#{grand_dt}", "domain": "#{RB_META_DOMAIN}", "member_of": "#{child_dt}", "fields": {"label": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", grand_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  {parent_dt, child_dt, grand_dt}
end

def rb_meta_create(db, doctype, content, parent_id = nil, meta_overrides = nil)
  overrides = meta_overrides || (parent_id ? {"parent_id" => JSON::Any.new(parent_id)} : nil)
  result = Facet::Document::Create.call(db, RB_META_DOMAIN, doctype, content, Facet::RBAC::AuthContext.system, meta_overrides: overrides)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result)
end

def rb_meta_delete(db, doctype, doc_id)
  result = Facet::Document::Delete.call(db, RB_META_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Delete::Result)
  result.as(Facet::Document::Delete::Result).mutation_id
end

# The restore-endpoint flow: resolve the pre-delete target, then roll back
# to it — the same two calls the route composes.
def rb_meta_restore(db, doctype, doc_id, ctx = Facet::RBAC::AuthContext.system)
  target = Facet::Audit::Restore.resolve_target(db, RB_META_DOMAIN, doctype, doc_id)
  target.should be_a(String)
  Facet::Audit::Rollback.call(db, target.as(String), ctx)
end

def rb_meta_snapshot_count(db, doctype, doc_id)
  db.query_one(
    "SELECT COUNT(*) FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'snapshot'",
    RB_META_DOMAIN, doctype, doc_id, as: Int64
  )
end

describe Facet::Audit::Rollback do
  # ── Replayed meta persistence (B-143) ────────────────────────────────

  describe "replayed meta persistence" do
    it "keeps meta.parent_id when a composition child is restored" do
      with_db do |db|
        parent_dt, child_dt, _grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child = rb_meta_create(db, child_dt, %({"label": "C"}), parent.projection.id)

        rb_meta_delete(db, child_dt, child.projection.id)

        result = rb_meta_restore(db, child_dt, child.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.deleted_at.should be_nil
        rb.projection.meta["parent_id"].as_s.should eq(parent.projection.id)
        rb.projection.meta["schema_version"].as_i.should eq(1)
        rb.cascade_restored.should be_empty

        # The snapshot row replays the create's meta too. The defect lost
        # parent_id here as well.
        snap_meta = db.query_one(
          "SELECT arguments->'meta' FROM mutations WHERE id = $1",
          rb.mutation_id, as: JSON::Any
        )
        snap_meta["parent_id"].as_s.should eq(parent.projection.id)
      end
    end

    it "keeps meta.parent_id when a live composition child rolls back" do
      with_db do |db|
        parent_dt, child_dt, _grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child = rb_meta_create(db, child_dt, %({"label": "C"}), parent.projection.id)

        upd = Facet::Document::Update.call(db, RB_META_DOMAIN, child_dt, child.projection.id, %({"label": "C2"}), Facet::RBAC::AuthContext.system)
        upd.should be_a(Facet::Document::Update::Result)

        result = Facet::Audit::Rollback.call(db, child.mutation_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.content["label"].as_s.should eq("C")
        rb.projection.meta["parent_id"].as_s.should eq(parent.projection.id)
        rb.cascade_restored.should be_empty
      end
    end

    it "restores the historical meta keys of the replayed state" do
      with_db do |db|
        create_simple_doctype(db, RB_META_DOMAIN, "RbMetaKeys", %({"name": {"type": "string"}}))
        doc = rb_meta_create(db, "RbMetaKeys", %({"name": "n"}), nil, {"origin" => JSON::Any.new("seed")})
        # The create stamps the extra meta key; the projection carries it.
        doc.projection.meta["origin"].as_s.should eq("seed")

        upd = Facet::Document::Update.call(db, RB_META_DOMAIN, "RbMetaKeys", doc.projection.id, %({"name": "n2"}), Facet::RBAC::AuthContext.system)
        upd.should be_a(Facet::Document::Update::Result)
        rb_meta_delete(db, "RbMetaKeys", doc.projection.id)

        result = rb_meta_restore(db, "RbMetaKeys", doc.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.meta["origin"].as_s.should eq("seed")
        rb.projection.meta["schema_version"].as_i.should eq(1)
      end
    end

    it "falls back to the current projection's schema_version when the replayed meta has none" do
      with_db do |db|
        create_simple_doctype(db, RB_META_DOMAIN, "RbMetaFall", %({"name": {"type": "string"}}))
        doc = rb_meta_create(db, "RbMetaFall", %({"name": "n"}), nil, {"origin" => JSON::Any.new("seed")})
        upd = Facet::Document::Update.call(db, RB_META_DOMAIN, "RbMetaFall", doc.projection.id, %({"name": "n2"}), Facet::RBAC::AuthContext.system)
        upd.should be_a(Facet::Document::Update::Result)
        rb_meta_delete(db, "RbMetaFall", doc.projection.id)

        # Strip schema_version from the create row, so the replay carries no
        # value. The pre-rollback projection carries a distinct one — the
        # fallback source.
        db.exec(
          "UPDATE mutations SET arguments = jsonb_set(arguments, '{meta}', (arguments->'meta') - 'schema_version') WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
          RB_META_DOMAIN, "RbMetaFall", doc.projection.id
        )
        db.exec(
          "UPDATE projections SET meta = jsonb_set(meta, '{schema_version}', '3') WHERE domain = $1 AND doc_type = $2 AND id = $3",
          RB_META_DOMAIN, "RbMetaFall", doc.projection.id
        )

        result = rb_meta_restore(db, "RbMetaFall", doc.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.meta["schema_version"].as_i.should eq(3)
        rb.projection.meta["origin"].as_s.should eq("seed")
      end
    end

    it "defaults schema_version to 1 when neither the replay nor the projection carries it" do
      with_db do |db|
        create_simple_doctype(db, RB_META_DOMAIN, "RbMetaOne", %({"name": {"type": "string"}}))
        doc = rb_meta_create(db, "RbMetaOne", %({"name": "n"}), nil, {"origin" => JSON::Any.new("seed")})
        upd = Facet::Document::Update.call(db, RB_META_DOMAIN, "RbMetaOne", doc.projection.id, %({"name": "n2"}), Facet::RBAC::AuthContext.system)
        upd.should be_a(Facet::Document::Update::Result)
        rb_meta_delete(db, "RbMetaOne", doc.projection.id)

        db.exec(
          "UPDATE mutations SET arguments = jsonb_set(arguments, '{meta}', (arguments->'meta') - 'schema_version') WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
          RB_META_DOMAIN, "RbMetaOne", doc.projection.id
        )
        db.exec(
          "UPDATE projections SET meta = meta - 'schema_version' WHERE domain = $1 AND doc_type = $2 AND id = $3",
          RB_META_DOMAIN, "RbMetaOne", doc.projection.id
        )

        result = rb_meta_restore(db, "RbMetaOne", doc.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.meta["schema_version"].as_i.should eq(1)
        rb.projection.meta["origin"].as_s.should eq("seed")
      end
    end
  end

  # ── Cascade restore (B-144) ──────────────────────────────────────────

  describe "cascade restore" do
    it "restores the cascade-tombstoned child and grandchild with the parent" do
      with_db do |db|
        parent_dt, child_dt, grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child = rb_meta_create(db, child_dt, %({"label": "C"}), parent.projection.id)
        grand = rb_meta_create(db, grand_dt, %({"label": "G"}), child.projection.id)

        rb_meta_delete(db, parent_dt, parent.projection.id)

        # Both descendants are tombstones after the cascade.
        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child.projection.id).deleted_at.should_not be_nil
        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, grand_dt, grand.projection.id).deleted_at.should_not be_nil

        result = rb_meta_restore(db, parent_dt, parent.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.deleted_at.should be_nil

        # The cascade set covers both levels, and the result lists every
        # restore with its own snapshot mutation id.
        rb.cascade_restored.map(&.doc_id).sort!.should eq([child.projection.id, grand.projection.id].sort)
        child_entry = rb.cascade_restored.find { |c| c.doc_id == child.projection.id } || raise "missing child entry"
        child_entry.domain.should eq(RB_META_DOMAIN)
        child_entry.doc_type.should eq(child_dt)
        child_entry.mut_id.should_not eq("")
        grand_entry = rb.cascade_restored.find { |c| c.doc_id == grand.projection.id } || raise "missing grand entry"
        grand_entry.doc_type.should eq(grand_dt)
        grand_entry.mut_id.should_not eq("")

        # Both children are live again, each with its own parent link.
        child_proj = Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child.projection.id)
        child_proj.deleted_at.should be_nil
        child_proj.meta["parent_id"].as_s.should eq(parent.projection.id)
        grand_proj = Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, grand_dt, grand.projection.id)
        grand_proj.deleted_at.should be_nil
        grand_proj.meta["parent_id"].as_s.should eq(child.projection.id)

        # Each child restore is its own rollback snapshot: the cause parent
        # is the child's own pre-delete mutation, and the row carries the
        # replayed meta.
        kind, parent_link, meta_arg = db.query_one(
          "SELECT cause_kind, cause_parent, arguments->'meta' FROM mutations WHERE id = $1",
          child_entry.mut_id, as: {String, String, JSON::Any}
        )
        kind.should eq("rollback")
        parent_link.should eq(child.mutation_id)
        meta_arg["parent_id"].as_s.should eq(parent.projection.id)
      end
    end

    it "restores the cascade subtree on a manual rollback to the delete mutation" do
      with_db do |db|
        parent_dt, child_dt, grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child = rb_meta_create(db, child_dt, %({"label": "C"}), parent.projection.id)
        grand = rb_meta_create(db, grand_dt, %({"label": "G"}), child.projection.id)

        del_mut_id = rb_meta_delete(db, parent_dt, parent.projection.id)

        # The target is the delete itself, not the pre-delete mutation.
        result = Facet::Audit::Rollback.call(db, del_mut_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.projection.deleted_at.should be_nil
        rb.cascade_restored.map(&.doc_id).sort!.should eq([child.projection.id, grand.projection.id].sort)

        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child.projection.id).deleted_at.should be_nil
        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, grand_dt, grand.projection.id).deleted_at.should be_nil
      end
    end

    it "does not resurrect a child deleted separately from the parent" do
      with_db do |db|
        parent_dt, child_dt, _grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child1 = rb_meta_create(db, child_dt, %({"label": "C1"}), parent.projection.id)
        child2 = rb_meta_create(db, child_dt, %({"label": "C2"}), parent.projection.id)

        # child2 dies on its own delete before the parent goes. The parent's
        # cascade then tombstones child1 only.
        rb_meta_delete(db, child_dt, child2.projection.id)
        rb_meta_delete(db, parent_dt, parent.projection.id)

        result = rb_meta_restore(db, parent_dt, parent.projection.id)
        result.should be_a(Facet::Audit::Rollback::Result)
        rb = result.as(Facet::Audit::Rollback::Result)
        rb.cascade_restored.map(&.doc_id).should eq([child1.projection.id])

        child1_proj = Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child1.projection.id)
        child1_proj.deleted_at.should be_nil
        child2_proj = Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child2.projection.id)
        child2_proj.deleted_at.should_not be_nil
      end
    end

    it "denies the whole restore when one cascade child is not authorized" do
      with_db do |db|
        parent_dt, child_dt, _grand_dt = rb_meta_build_trio(db)
        parent = rb_meta_create(db, parent_dt, %({"name": "P"}))
        child = rb_meta_create(db, child_dt, %({"label": "C"}), parent.projection.id)

        rb_meta_delete(db, parent_dt, parent.projection.id)

        snaps_before = rb_meta_snapshot_count(db, parent_dt, parent.projection.id) +
                       rb_meta_snapshot_count(db, child_dt, child.projection.id)

        # The caller may update the parent but holds no right on the child.
        partial = Facet::RBAC::AuthContext.authenticated(
          "restorer-#{unique_suffix}",
          Facet::RBAC::ActiveRole.new(
            role_id: "audit.partial_restore",
            visible_tags: Set{"default"},
            permissions: [Facet::RBAC::Permission.new(action: "update", domain: RB_META_DOMAIN, path: [parent_dt])],
          ),
        )

        result = rb_meta_restore(db, parent_dt, parent.projection.id, partial)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 403
        err.message.should eq "rollback refused: your role cannot write a cascade child document"

        # Zero writes: no snapshot landed on the parent or the child, and
        # both tombstones stand.
        (rb_meta_snapshot_count(db, parent_dt, parent.projection.id) +
          rb_meta_snapshot_count(db, child_dt, child.projection.id)).should eq(snaps_before)
        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, parent_dt, parent.projection.id).deleted_at.should_not be_nil
        Facet::Mutation::Client.fetch_projection(db, RB_META_DOMAIN, child_dt, child.projection.id).deleted_at.should_not be_nil
      end
    end
  end
end
