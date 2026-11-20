# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# ── Helpers ──────────────────────────────────────────────────────────────────
#
# Namespaced so they stay collision-free with the helpers of the other spec
# files compiled into the same binary.

module ParentLinkage
  # Linkage columns of one mutation row.
  record MutationLink,
    id : String,
    action : String,
    parent_doc_id : String?,
    cause_kind : String,
    cause_trace : String

  # Reads the linkage columns of one mutation row by its id.
  def self.mutation_link(db, mut_id : String) : MutationLink
    db.query_one(
      "SELECT id, action, parent_doc_id, cause_kind, cause_trace FROM mutations WHERE id = $1",
      mut_id,
    ) do |rs|
      MutationLink.new(
        id: rs.read(String),
        action: rs.read(String),
        parent_doc_id: rs.read(String?),
        cause_kind: rs.read(String),
        cause_trace: rs.read(String),
      )
    end
  end

  # Raw mutation insert (mirrors `spec/mutation/mutations_spec.cr`). The
  # BEFORE INSERT trigger assigns idx and stamps `parent_doc_id`; the
  # AFTER trigger upserts the projection. Empty arguments COALESCE to
  # no-op `diff` / `meta_diff` on update rows.
  def self.insert_raw_mutation(db, domain : String, doc_type : String, doc_id : String, action : String, arguments : String = "{}") : String
    mut_id = Facet::Util::ScriptHelpers.ulid
    db.query_one(
      "INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace) " \
      "VALUES ($1, $2, $3, $4, $5, 'spec-runner', $6::jsonb, 'internal', 'request', $3) RETURNING id",
      domain, doc_type, mut_id, doc_id, action, arguments, as: String)
  end

  # Registers an aggregate parent doctype (one children relationship) and
  # its child doctype (`member_of`). Both names are caller-chosen and
  # unique per test.
  def self.register_pair(db, domain : String, parent_dt : String, child_dt : String) : Nil
    parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))

    child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}})
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))
  end

  # Creates a root parent document via the service. Returns the full
  # result so tests can pin the create mutation's own linkage.
  def self.create_parent(db, domain : String, parent_dt : String, name : String = "Parent") : Facet::Document::Create::Result
    res = Facet::Document::Create.call(db, domain, parent_dt, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system)
    expect_create_success(res)
  end

  # Creates a child document the way the nested route does — the parent id
  # rides in `meta_overrides` (see `HTTP::RestRoutes.rest_post_root_child_or_action`).
  def self.create_child(db, domain : String, child_dt : String, parent_id : String, label : String = "Child") : Facet::Document::Create::Result
    res = Facet::Document::Create.call(
      db, domain, child_dt, %({"label": "#{label}"}), Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    )
    expect_create_success(res)
  end

  # Fetches the create mutation id of a document (one create per id).
  def self.create_mutation_id(db, domain : String, doc_type : String, doc_id : String) : String
    db.query_one(
      "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
      domain, doc_type, doc_id, as: String)
  end
end

# ── Stamp rule ───────────────────────────────────────────────────────────────
#
# Every child mutation row carries `parent_doc_id`; roots carry NULL.
# Stamping happens in the BEFORE INSERT trigger `stamp_mutation_insert`
# (`db/migrations/0001_document_store.sql`): `arguments->'meta'->>'parent_id'`
# first, else a PK probe of the projection's `meta`.

describe "mutations.parent_doc_id stamping" do
  it "stamps a child create (nested-route staging) and leaves a root create NULL" do
    with_temp_doctype("plcreate") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Child"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent = ParentLinkage.create_parent(db, domain, parent_dt)
      parent_link = ParentLinkage.mutation_link(db, parent.mutation_id)
      parent_link.action.should eq("create")
      parent_link.parent_doc_id.should be_nil

      child = ParentLinkage.create_child(db, domain, child_dt, parent.projection.id)
      child_link = ParentLinkage.mutation_link(db, child.mutation_id)
      child_link.action.should eq("create")
      child_link.parent_doc_id.should eq(parent.projection.id)
    end
  end

  it "stamps compound-create children — plain and recursive compound" do
    with_temp_doctype("plcomp") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      part_dt = "#{parent_dt}Part"
      sub_dt = "#{parent_dt}Sub"

      parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"parts": {"doctype": "#{part_dt}", "collection": true}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))

      part_defn = %({"doctype": "#{part_dt}", "domain": "#{domain}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}, "children": {"subparts": {"doctype": "#{sub_dt}", "collection": true}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", part_defn, Facet::RBAC::AuthContext.system))

      sub_defn = %({"doctype": "#{sub_dt}", "domain": "#{domain}", "member_of": "#{part_dt}", "fields": {"label": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", sub_defn, Facet::RBAC::AuthContext.system))

      body = %({
        "$content": {"name": "Widget"},
        "$children": {
          "parts": [
            {"label": "Plain part"},
            {"$content": {"label": "Compound part"}, "$children": {"subparts": [{"label": "Nested sub"}]}}
          ]
        }
      })
      result = Facet::Document::CreateWithChildren.call(db, domain, parent_dt, body, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::CreateWithChildren::Result)
      cwc = result.as(Facet::Document::CreateWithChildren::Result)
      parent_id = cwc.projection.id

      parts = cwc.children["parts"]
      plain, compound = parts[0], parts[1]

      # Plain child → stamped with the aggregate parent's id.
      ParentLinkage.mutation_link(db, plain.mut_id).parent_doc_id.should eq(parent_id)

      # Recursive compound child → stamped with the aggregate parent's id.
      ParentLinkage.mutation_link(db, compound.mut_id).parent_doc_id.should eq(parent_id)

      # The compound child's own child → stamped with the compound child's id.
      sub = compound.children["subparts"][0]
      ParentLinkage.mutation_link(db, sub.mut_id).parent_doc_id.should eq(compound.id)
    end
  end

  it "stamps update and delete rows of a child via the projections fallback" do
    with_temp_doctype("plwrited") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Child"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent_id = ParentLinkage.create_parent(db, domain, parent_dt).projection.id
      child = ParentLinkage.create_child(db, domain, child_dt, parent_id)

      upd = Facet::Document::Update.call(db, domain, child_dt, child.projection.id, %({"label": "Updated"}), Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)
      upd_link = ParentLinkage.mutation_link(db, upd.as(Facet::Document::Update::Result).mutation_id)
      upd_link.action.should eq("update")
      upd_link.parent_doc_id.should eq(parent_id)

      del = Facet::Document::Delete.call(db, domain, child_dt, child.projection.id, Facet::RBAC::AuthContext.system)
      del.should be_a(Facet::Document::Delete::Result)
      del_link = ParentLinkage.mutation_link(db, del.as(Facet::Document::Delete::Result).mutation_id)
      del_link.action.should eq("delete")
      del_link.parent_doc_id.should eq(parent_id)
    end
  end

  it "stamps cascade child deletes inside the parent's causal cluster" do
    with_temp_doctype("plcasc") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Child"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent_id = ParentLinkage.create_parent(db, domain, parent_dt).projection.id
      child_ids = ["Cog A", "Cog B"].map { |label| ParentLinkage.create_child(db, domain, child_dt, parent_id, label).projection.id }

      del = Facet::Document::Delete.call(db, domain, parent_dt, parent_id, Facet::RBAC::AuthContext.system)
      del.should be_a(Facet::Document::Delete::Result)
      root_trace = ParentLinkage.mutation_link(db, del.as(Facet::Document::Delete::Result).mutation_id).cause_trace

      cascade_del_ids = db.query_all(
        "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND action = 'delete' AND cause_kind = 'cascade' ORDER BY id",
        domain, child_dt, as: String)
      cascade_del_ids.size.should eq(2)

      cascade_del_ids.each do |mut_id|
        link = ParentLinkage.mutation_link(db, mut_id)
        link.parent_doc_id.should eq(parent_id)
        link.cause_kind.should eq("cascade")
        # The whole composition subtree groups under the root delete's trace.
        link.cause_trace.should eq(root_trace)
      end

      # Sanity: the cascaded rows are the two children of this parent.
      cascaded_doc_ids = db.query_all(
        "SELECT doc_id FROM mutations WHERE domain = $1 AND doc_type = $2 AND action = 'delete' AND cause_kind = 'cascade'",
        domain, child_dt, as: String)
      cascaded_doc_ids.sort.should eq(child_ids.sort)
    end
  end

  it "stamps a rollback snapshot of a child via the projections fallback" do
    with_temp_doctype("plroll") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Child"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent_id = ParentLinkage.create_parent(db, domain, parent_dt).projection.id
      child = ParentLinkage.create_child(db, domain, child_dt, parent_id)

      upd = Facet::Document::Update.call(db, domain, child_dt, child.projection.id, %({"label": "v2"}), Facet::RBAC::AuthContext.system)
      upd.should be_a(Facet::Document::Update::Result)

      rb = Facet::Audit::Rollback.call(db, upd.as(Facet::Document::Update::Result).mutation_id, Facet::RBAC::AuthContext.system)
      rb.should be_a(Facet::Audit::Rollback::Result)
      rb_result = rb.as(Facet::Audit::Rollback::Result)

      link = ParentLinkage.mutation_link(db, rb_result.mutation_id)
      link.action.should eq("snapshot")
      link.cause_kind.should eq("rollback")
      # The rollback snapshot's own arguments carry no parent_id — the stamp
      # comes from the pre-rollback projection row's meta.
      link.parent_doc_id.should eq(parent_id)
    end
  end

  it "stamps the periodic snapshot row (raw-SQL pattern)" do
    with_temp_doctype("plpsnap") do |db, domain, _dt|
      ensure_domain(db, domain)
      doc_type = "PLSnapChild"
      parent_id = Facet::Util::ScriptHelpers.ulid
      child_id = Facet::Util::ScriptHelpers.ulid

      create_mut = ParentLinkage.insert_raw_mutation(db, domain, doc_type, child_id, "create",
        arguments: %({"content": {"label": "c0"}, "meta": {"parent_id": "#{parent_id}"}}))
      ParentLinkage.mutation_link(db, create_mut).parent_doc_id.should eq(parent_id)

      # Drive idx to the snapshot interval (default 10): nine no-op updates
      # on top of the create. The tenth insert fires `periodic_snapshot`.
      9.times { ParentLinkage.insert_raw_mutation(db, domain, doc_type, child_id, "update") }

      snap = db.query_one?(
        "SELECT id, parent_doc_id, cause_kind FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'snapshot'",
        domain, doc_type, child_id,
        as: {String, String?, String},
      )
      snap.should_not be_nil
      snap_id, snap_parent, snap_cause = snap.not_nil!
      snap_cause.should eq("periodic_snapshot")
      # The snapshot's arguments carry the projection meta — including the
      # parent linkage.
      snap_parent.should eq(parent_id)
      ParentLinkage.mutation_link(db, snap_id).parent_doc_id.should eq(parent_id)
    end
  end

  it "leaves a Lua document.create row NULL (no parent meta at write time)" do
    with_temp_doctype("pllua") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Task"

      task_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", task_defn, Facet::RBAC::AuthContext.system))

      script = <<-LUA
        local export = {}
        function export.create(ctx)
          local ok, task = pcall(document.create, "#{child_dt}", '{"title": "spawned"}')
          if not ok then
            ctx.error("Failed to create task: " .. tostring(task))
            return
          end
          ctx.root.task_id = task.id
        end
        return export
      LUA
      fields = %({"name": {"type": "string"}, "task_id": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))

      res = Facet::Document::Create.call(db, domain, doctype, %({"name": "Spawner"}), Facet::RBAC::AuthContext.system)
      proj = expect_create_success(res).projection
      task_id = proj.content["task_id"]?.try(&.as_s?)
      task_id.should_not be_nil

      link = ParentLinkage.mutation_link(db, ParentLinkage.create_mutation_id(db, domain, child_dt, task_id.not_nil!))
      # The child doctype of this aggregate never carried meta.parent_id —
      # the Lua-created row is a root, not a member of the spawner's feed.
      link.parent_doc_id.should be_nil
    end
  end

  it "drops the stale parent linkage on a copied child and rewrites with new_parent_id" do
    with_temp_doctype("plcopy") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Part"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent_id = ParentLinkage.create_parent(db, domain, parent_dt).projection.id
      child = ParentLinkage.create_child(db, domain, child_dt, parent_id, "Copied")

      # Copy without a target parent — the copy becomes a root. The source
      # parent's linkage is never inherited.
      copy_id = Facet::Document::Copy.deep_copy(db, domain, domain, child_dt, child.projection.id, "system:copy")
      copy_id.should be_a(String)
      copy_link = ParentLinkage.mutation_link(db, ParentLinkage.create_mutation_id(db, domain, child_dt, copy_id.as(String)))
      copy_link.parent_doc_id.should be_nil

      # Copy with an explicit target parent — linkage rewrites to it.
      other_parent_id = ParentLinkage.create_parent(db, domain, parent_dt, "Other").projection.id
      copy2_id = Facet::Document::Copy.deep_copy(db, domain, domain, child_dt, child.projection.id, "system:copy", new_parent_id: other_parent_id)
      copy2_id.should be_a(String)
      copy2_link = ParentLinkage.mutation_link(db, ParentLinkage.create_mutation_id(db, domain, child_dt, copy2_id.as(String)))
      copy2_link.parent_doc_id.should eq(other_parent_id)
    end
  end

  it "stamps rows written directly through Mutation::Client.create (system writers)" do
    with_temp_doctype("plsys") do |db, domain, parent_dt|
      ensure_domain(db, domain)
      child_dt = "#{parent_dt}Child"
      ParentLinkage.register_pair(db, domain, parent_dt, child_dt)

      parent_id = ParentLinkage.create_parent(db, domain, parent_dt).projection.id

      doc_id = Facet::Util::ScriptHelpers.ulid
      mut_id = Facet::Mutation::Client.create(
        db, domain, child_dt,
        doc_id: doc_id,
        content: %({"label": "system-made"}),
        meta: %({"parent_id": "#{parent_id}"}),
        actioner_id: "system:test",
      )
      # System writers (doctype create, seed, domain copy, import) stage
      # meta.parent_id themselves — the trigger stamps their rows. The
      # aggregate read sees them; the push feed does not (no emitter).
      ParentLinkage.mutation_link(db, mut_id).parent_doc_id.should eq(parent_id)
    end
  end
end
