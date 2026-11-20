# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/cron/tombstone_content_prune"

# ── Setup ────────────────────────────────────────────────────────────────────

HIST_DOMAIN = "histagg"

# Namespaced so the helpers stay collision-free with the other spec files
# compiled into the same binary.
module AggHistory
  # Registers one parent doctype with two child relationships (two distinct
  # child doctypes, so the per-doctype branch walk is exercised) plus a
  # `mine` named scope on both children (`owner_id` $self — the $mine grant
  # shape). Returns `{parent, child_a, child_b}` doctype names.
  def self.register_pair(db) : {String, String, String}
    ensure_domain(db, HIST_DOMAIN)
    # Register the core/iam doctype set: the children declare an `owner_id`
    # reference targeting iam.Account, whose definition must exist for the
    # authoring-time reference check.
    restore_seeded_baseline(db)
    parent = "P#{unique_suffix}"
    child_a = "Ca#{unique_suffix}"
    child_b = "Cb#{unique_suffix}"

    child_fields = %({"name": {"type": "string"}, "owner_id": {"type": "reference", "doctype": "iam.Account"}})
    child_scopes = %({"mine": {"where": {"owner_id": "$self"}}})

    parent_defn = %({"doctype": "#{parent}", "domain": "#{HIST_DOMAIN}", "aggregate_root": true, "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_a}", "collection": true}, "notes": {"doctype": "#{child_b}", "collection": true}}})
    child_a_defn = %({"doctype": "#{child_a}", "domain": "#{HIST_DOMAIN}", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": #{child_fields}, "scopes": #{child_scopes}})
    child_b_defn = %({"doctype": "#{child_b}", "domain": "#{HIST_DOMAIN}", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": #{child_fields}, "scopes": #{child_scopes}})
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_a_defn, Facet::RBAC::AuthContext.system))
    expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_b_defn, Facet::RBAC::AuthContext.system))
    {parent, child_a, child_b}
  end

  # Creates a parent document. Returns the create result.
  def self.create_parent(db, parent_dt : String, name : String = "root") : Facet::Document::Create::Result
    res = Facet::Document::Create.call(db, HIST_DOMAIN, parent_dt, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system)
    expect_create_success(res)
  end

  # Ensures the `iam.Account` row a child's `owner_id` reference points at
  # exists (the authoring-time reference check requires it).
  def self.ensure_owner(db, account_id : String) : Nil
    exists = db.query_one?("SELECT 1 FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1 AND deleted_at IS NULL", account_id, as: Int32)
    create_account_projection(db, account_id, [] of String) if exists.nil?
  end

  # Creates a child document the way the nested route does (meta_overrides)
  # and returns the create result. `owner` names the owning account row.
  def self.create_child(db, child_dt : String, parent_id : String, name : String, owner : String? = nil) : Facet::Document::Create::Result
    ensure_owner(db, owner) if owner
    body = owner ? %({"name": "#{name}", "owner_id": "iam.Account.#{owner}"}) : %({"name": "#{name}"})
    res = Facet::Document::Create.call(
      db, HIST_DOMAIN, child_dt, body, Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    )
    expect_create_success(res)
  end

  # Creates a role holding the given permission JSON fragments and returns
  # the auth context of an account that carries it.
  def self.reader_context(db, role_id : String, account_id : String, permissions_json : String) : Facet::RBAC::AuthContext
    create_role_projection(db, role_id, JSON.parse(%([#{permissions_json}])).as_a)
    create_account_projection(db, account_id, [role_id])
    role = Facet::RBAC::ActiveRole.from_projection_content(
      Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
    )
    Facet::RBAC::AuthContext.authenticated(account_id, role)
  end

  # The mutation ids of one document's rows, newest first (the timeline order).
  def self.mutation_ids(list : Facet::Audit::List::Result, doc_id : String) : Array(String)
    list.items.select { |m| m.doc_id == doc_id }.map(&.id)
  end
end

# ── Specs ────────────────────────────────────────────────────────────────────

describe "aggregate history (include=children)" do
  it "merges parent and child rows into one mixed timeline" do
    with_db do |db|
      parent_dt, child_a, child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id

      # Creation order: parent create → child_a create → parent update →
      # child_b create. The timeline returns it newest first, so the
      # doc_type sequence pins the merge (D9 ordering).
      child1 = AggHistory.create_child(db, child_a, parent_id, "kid-1")
      Facet::Document::Update.call(db, HIST_DOMAIN, parent_dt, parent_id, %({"name": "root2"}), Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Update::Result)
      child2 = AggHistory.create_child(db, child_b, parent_id, "note-1")

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: Facet::RBAC::AuthContext.system, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      list.items.map(&.doc_type).should eq([child_b, parent_dt, child_a, parent_dt])
      list.items.map(&.action).should eq(["create", "update", "create", "create"])
      list.items.map(&.doc_id).should eq([child2.projection.id, parent_id, child1.projection.id, parent_id])
      list.total.should eq(4)

      # Every row carries the label of its document's CURRENT projection
      # row (the join is a PK lookup, not a point-in-time replay) — the
      # parent's label moved to "root2" with its update, the children
      # carry their own names (D6).
      list.items.map(&.display_name).should eq(["note-1", "root2", "kid-1", "root2"])
    end
  end

  it "stays parent-only without the flag" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      AggHistory.create_child(db, child_a, parent.projection.id, "kid-1")

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent.projection.id,
        auth_context: Facet::RBAC::AuthContext.system,
      ).should be_a(Facet::Audit::List::Result)

      list.items.map(&.doc_type).uniq!
      list.items.map(&.doc_type).should eq([parent_dt])
      list.items.map(&.action).should eq(["create"])
      list.total.should eq(1)
      # Plain mode leaves the label unset.
      list.items.map(&.display_name).should eq([nil])
    end
  end

  it "paginates the merged timeline with an accurate cross-branch count" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      child = AggHistory.create_child(db, child_a, parent_id, "kid-1")
      Facet::Document::Update.call(db, HIST_DOMAIN, parent_dt, parent_id, %({"name": "root2"}), Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, HIST_DOMAIN, child_a, child.projection.id, %({"name": "kid-2"}), Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Update::Result)

      # 2 parent rows + 2 child rows, one page at a time. The count covers
      # both branches (C3) and each row appears exactly once. `total` is
      # offset-relative (B-297): each page reports what remains from its
      # own offset, so a one-row page reports `4, 3, 2, 1` before the
      # first empty page reports `0`.
      seen = [] of String
      page = 1
      loop do
        list = Facet::Audit::List.call(
          db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
          page: page, items_per_page: 1,
          auth_context: Facet::RBAC::AuthContext.system, include_children: true,
        ).should be_a(Facet::Audit::List::Result)
        list.total.should eq(5 - page)
        break if list.items.empty?
        list.items.size.should eq(1)
        seen.concat(list.items.map(&.id))
        page += 1
      end

      seen.size.should eq(4)
      seen.uniq.size.should eq(4)
    end
  end

  it "keeps child rows out when the caller has no child grant (no 403)" do
    with_db do |db|
      parent_dt, child_a, child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      AggHistory.create_child(db, child_a, parent_id, "kid-1")
      AggHistory.create_child(db, child_b, parent_id, "note-1")

      auth = AggHistory.reader_context(db, "hist_parent_only_role", "hist_parent_only_acc",
        %({"action": "read", "on": "#{HIST_DOMAIN}.#{parent_dt}"}))

      result = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: auth, include_children: true,
      )
      result.should be_a(Facet::Audit::List::Result)

      list = result.as(Facet::Audit::List::Result)
      list.items.map(&.doc_type).uniq!
      list.items.map(&.doc_type).should eq([parent_dt])
      list.total.should eq(1)
    end
  end

  it "shows only the children a $mine-scoped grant matches" do
    with_db do |db|
      parent_dt, child_a, child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      mine = AggHistory.create_child(db, child_a, parent_id, "mine", owner: "hist_mine_acc")
      theirs = AggHistory.create_child(db, child_a, parent_id, "theirs", owner: "hist_other_acc")
      AggHistory.create_child(db, child_b, parent_id, "note", owner: "hist_mine_acc")

      auth = AggHistory.reader_context(db, "hist_mine_role", "hist_mine_acc", %(
        {"action": "read", "on": "#{HIST_DOMAIN}.#{parent_dt}"},
        {"action": "read", "on": "#{HIST_DOMAIN}.#{child_a}", "scope": "$mine"}
      ))

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: auth, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      # The owned child's row rides the feed; the other account's child and
      # the unreadable child_b doctype contribute nothing.
      list.items.map(&.doc_id).should eq([mine.projection.id, parent_id])
      list.items.map(&.doc_type).should eq([child_a, parent_dt])
      list.total.should eq(2)
      theirs.projection.id.to_s.should_not eq(mine.projection.id)
    end
  end

  it "keeps tombstoned child rows while the payload is retained" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      child = AggHistory.create_child(db, child_a, parent_id, "kid-1", owner: "hist_tomb_acc")

      Facet::Document::Delete.call(db, HIST_DOMAIN, child_a, child.projection.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      auth = AggHistory.reader_context(db, "hist_tomb_role", "hist_tomb_acc", %(
        {"action": "read", "on": "#{HIST_DOMAIN}.#{parent_dt}"},
        {"action": "read", "on": "#{HIST_DOMAIN}.#{child_a}", "scope": "$mine"}
      ))

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: auth, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      # The tombstone retains its content, so the scope still matches and
      # the child's create + delete rows stay on the feed. The label
      # survives too (the prune never clears display_name).
      list.items.map(&.doc_id).should eq([child.projection.id, child.projection.id, parent_id])
      list.items.map(&.action).should eq(["delete", "create", "create"])
      list.items.compact_map(&.display_name).should eq(["kid-1", "kid-1", "root"])
      list.total.should eq(3)
    end
  end

  it "hides pruned child rows from scoped readers but keeps them for unscoped readers" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      child = AggHistory.create_child(db, child_a, parent_id, "kid-1", owner: "hist_prune_acc")

      Facet::Document::Delete.call(db, HIST_DOMAIN, child_a, child.projection.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      # Age the tombstone past the retention window and prune its payload.
      db.exec("UPDATE projections SET deleted_at = now() - make_interval(days => 31) WHERE id = $1", child.projection.id)
      Facet::Cron::TombstoneContentPrune.prune(db, retention_days: 30).should eq(1)

      scoped = AggHistory.reader_context(db, "hist_prune_role", "hist_prune_acc", %(
        {"action": "read", "on": "#{HIST_DOMAIN}.#{parent_dt}"},
        {"action": "read", "on": "#{HIST_DOMAIN}.#{child_a}", "scope": "$mine"}
      ))

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: scoped, include_children: true,
      ).should be_a(Facet::Audit::List::Result)
      # Fail-closed: the scope evaluates against the emptied content, so
      # the child id no longer resolves and its rows drop off the feed.
      list.items.map(&.doc_type).uniq!
      list.items.map(&.doc_type).should eq([parent_dt])
      list.total.should eq(1)

      unscoped = AggHistory.reader_context(db, "hist_prune_wide_role", "hist_prune_wide_acc", %(
        {"action": "read", "on": "#{HIST_DOMAIN}.#{parent_dt}"},
        {"action": "read", "on": "#{HIST_DOMAIN}.#{child_a}"}
      ))

      wide = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: unscoped, include_children: true,
      ).should be_a(Facet::Audit::List::Result)
      # An unrestricted child grant needs no content probe — the id still
      # resolves from meta alone, so the rows stay.
      wide.items.map(&.doc_id).should eq([child.projection.id, child.projection.id, parent_id])
      wide.total.should eq(3)
    end
  end

  it "returns 403 when the caller holds no read grant on the parent doctype" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      AggHistory.create_child(db, child_a, parent.projection.id, "kid-1")

      # A role that reads the child doctype but holds no parent grant:
      # the target gate is a class-level denial on the parent doctype,
      # answered 403 like the read side. A grant holder whose parent row
      # is out of scope keeps the non-disclosing 404.
      auth = AggHistory.reader_context(db, "hist_child_only_role", "hist_child_only_acc",
        %({"action": "read", "on": "#{HIST_DOMAIN}.#{child_a}"}))

      result = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent.projection.id,
        auth_context: auth, include_children: true,
      )
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "reverts a child delete row back to a live child" do
    with_db do |db|
      parent_dt, child_a, _child_b = AggHistory.register_pair(db)
      parent = AggHistory.create_parent(db, parent_dt)
      parent_id = parent.projection.id
      child = AggHistory.create_child(db, child_a, parent_id, "kid-1")
      child_id = child.projection.id

      Facet::Document::Delete.call(db, HIST_DOMAIN, child_a, child_id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      list = Facet::Audit::List.call(
        db, domain: HIST_DOMAIN, doc_type: parent_dt, doc_id: parent_id,
        auth_context: Facet::RBAC::AuthContext.system, include_children: true,
      ).should be_a(Facet::Audit::List::Result)

      delete_row = list.items.find { |m| m.doc_id == child_id && m.action == "delete" }
      delete_row.should_not be_nil

      # Revert on the delete row restores the document (N5): the rollback
      # resolves the pre-delete mutation and replays it, clearing the
      # tombstone.
      result = Facet::Audit::Rollback.call(db, delete_row.as(Facet::Audit::List::MutationRecord).id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::Rollback::Result)

      proj = Facet::Mutation::Client.fetch_projection(db, HIST_DOMAIN, child_a, child_id)
      proj.deleted_at.should be_nil
      proj.content["name"].as_s.should eq("kid-1")
    end
  end
end
