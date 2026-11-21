# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"
require "../../src/document"
require "../support/rbac_helper"

# The `$parent_id` reserved field token in named scopes: the system-managed
# composition linkage at `meta.parent_id`.
#
# This is the regression pin for the two-engine split: the list path
# (`ReadEnforcer.list_where_clauses`) and the single-row gate
# (`EnforcerSupport.row_authorized?`) compile scopes through the same
# `RBAC::ScopePredicateSql`, so a row the list shows is also readable,
# updatable, and deletable one-row-at-a-time — and `$null` / `ne` behave
# with SQL semantics on both paths.
#
# Fixture: `Project` (aggregate root, `manager` field) and `SubProject`
# (composition child). A context set `manager_projects` selects the ids of
# the projects the caller manages; the child scopes key on `$parent_id`.
private def pid_create_parent_doctype(db, domain : String) : Nil
  parent_defn = %({
    "doctype": "Project",
    "domain": "#{domain}",
    "schema_version": 1,
    "aggregate_root": true,
    "search": "{{ title }}",
    "fields": {
      "title":   {"type": "string"},
      "manager": {"type": "string"}
    },
    "children": {
      "subs": {"doctype": "SubProject", "collection": true}
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

private def pid_create_child_doctype(db, domain : String) : Nil
  child_defn = %({
    "doctype": "SubProject",
    "domain": "#{domain}",
    "schema_version": 1,
    "aggregate_root": false,
    "member_of": "Project",
    "search": "{{ title }}",
    "fields": {
      "title": {"type": "string"}
    },
    "scopes": {
      "managed_by_me": {"where": {"$parent_id": "$manager_projects"}},
      "roots_only":    {"where": {"$parent_id": "$null"}},
      "not_parent_a":  {"where": {"$parent_id__ne": "proj_a"}}
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

private def pid_create_domain(db, domain : String) : Nil
  content = %({"context_sets": {}})
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: content,
    actioner_id: "system",
  )
end

private def pid_set_context_sets(db, domain : String) : Nil
  core_content = Facet::Mutation::Client.fetch_content(db, "core", "Domain", domain)
  core_h = core_content.as_h
  core_h["context_sets"] = JSON.parse(
    <<-JSON
      {
        "manager_projects": {
          "from": "Project",
          "select": "$doc_id",
          "where": {"manager": "$self"}
        }
      }
    JSON
  )
  result = Facet::Document::Update.call(db, "core", "Domain", domain, core_h.to_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Update::Result)
end

# Creates a Project row with the given manager (a bare string field — the
# `$self` comparison matches both stored principal forms).
private def pid_create_project(db, domain : String, doc_id : String, manager : String) : Nil
  content = %({"title": "#{doc_id}", "manager": "#{manager}"})
  Facet::Mutation::Client.create(
    db, domain, "Project",
    doc_id: doc_id,
    content: content,
    actioner_id: "system",
  )
end

# Creates a SubProject row, optionally linked to a parent through
# `meta.parent_id` (the composition linkage the nested create route sets).
private def pid_create_child(db, domain : String, doc_id : String, parent_id : String?) : Nil
  content = %({"title": "#{doc_id}"})
  if parent_id
    meta = %({"parent_id": "#{parent_id}"})
    Facet::Mutation::Client.create(
      db, domain, "SubProject",
      doc_id: doc_id,
      content: content,
      meta: meta,
      actioner_id: "system",
    )
  else
    Facet::Mutation::Client.create(
      db, domain, "SubProject",
      doc_id: doc_id,
      content: content,
      actioner_id: "system",
    )
  end
end

# One parent-child fixture tree shared by every example:
# - proj_a managed by acc_1, proj_b managed by acc_2;
# - child_a1 / child_a2 under proj_a, child_b1 under proj_b;
# - root_child with no parent link.
private def pid_create_fixture(db) : String
  Facet::Doctype::Seed.ensure_doctype(db, "core", "Domain")
  domain = "pm-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..8].downcase}"
  pid_create_domain(db, domain)
  pid_create_parent_doctype(db, domain)
  pid_set_context_sets(db, domain)
  pid_create_child_doctype(db, domain)
  pid_create_project(db, domain, "proj_a", "iam.Account.acc_1")
  pid_create_project(db, domain, "proj_b", "iam.Account.acc_2")
  pid_create_child(db, domain, "child_a1", "proj_a")
  pid_create_child(db, domain, "child_a2", "proj_a")
  pid_create_child(db, domain, "child_b1", "proj_b")
  pid_create_child(db, domain, "root_child", nil)
  domain
end

module Facet::RBAC
  describe "ReadEnforcer $parent_id row gate" do
    it "authorizes the detail read of a row the scoped list shows" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))
        expect_rbac_authorized(db, domain, "SubProject", "child_a1", ctx)
        expect_rbac_authorized(db, domain, "SubProject", "child_a2", ctx)
      end
    end

    it "denies a child of a parent outside the resolved context set" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))
        expect_rbac_denied(db, domain, "SubProject", "child_b1", ctx)
      end
    end

    it "denies a root row (no parent link) under an eq scope" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))
        expect_rbac_denied(db, domain, "SubProject", "root_child", ctx)
      end
    end

    it "matches list and detail answers on the same rows" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))

        listed = Facet::Document::List.call(
          db, domain, "SubProject",
          filters: {} of String => JSON::Any,
          sort: ["id"],
          page: 1,
          items_per_page: 100,
          auth_context: ctx,
        )
        listed_ids = listed.as(Facet::Document::List::Result).items.map(&.id).sort!
        listed_ids.should eq(["child_a1", "child_a2"])

        # The regression contract: every listed row answers the single-row
        # gate the same way the list served it.
        listed_ids.each do |id|
          expect_rbac_authorized(db, domain, "SubProject", id, ctx)
        end
      end
    end

    it "matches the row id alone when the context set is empty" do
      with_db do |db|
        domain = pid_create_fixture(db)
        # acc_nobody manages nothing: the set resolves empty and the eq
        # against it fails closed for every row.
        ctx = AuthContext.authenticated("acc_nobody", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))
        expect_rbac_denied(db, domain, "SubProject", "child_a1", ctx)
      end
    end

    it "answers false — not an exception — for a row that does not exist" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me"])]))
        ReadEnforcer.authorized?(db, domain, "SubProject", "no_such_row", ctx).should be_false
      end
    end
  end

  describe "$parent_id null and ne semantics" do
    it "serves only root rows under an eq $null scope" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$roots_only"])]))
        expect_rbac_authorized(db, domain, "SubProject", "root_child", ctx)
        expect_rbac_denied(db, domain, "SubProject", "child_a1", ctx)
      end
    end

    it "serves roots and foreign children under a ne literal scope" do
      with_db do |db|
        domain = pid_create_fixture(db)
        # `ne` compiles to IS DISTINCT FROM: a root row (SQL NULL) counts as
        # different — "not equal" includes "not set".
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$not_parent_a"])]))
        expect_rbac_authorized(db, domain, "SubProject", "root_child", ctx)
        expect_rbac_authorized(db, domain, "SubProject", "child_b1", ctx)
        expect_rbac_denied(db, domain, "SubProject", "child_a1", ctx)
      end
    end

    it "OR-s aliases on one permission across the row gate" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("read", "#{domain}.SubProject", ["$managed_by_me", "$roots_only"])]))
        expect_rbac_authorized(db, domain, "SubProject", "child_a1", ctx)
        expect_rbac_authorized(db, domain, "SubProject", "root_child", ctx)
        expect_rbac_denied(db, domain, "SubProject", "child_b1", ctx)
      end
    end
  end

  describe "WriteEnforcer $parent_id row gate" do
    it "authorizes the update of a child inside the caller's scope" do
      with_db do |db|
        domain = pid_create_fixture(db)
        ctx = AuthContext.authenticated("acc_1", rbac_role([rbac_perm("update", "#{domain}.SubProject", ["$managed_by_me"])]))
        WriteEnforcer.authorize_update(db, domain, "SubProject", "child_a1", ctx).should be_true
        WriteEnforcer.authorize_update(db, domain, "SubProject", "child_b1", ctx).should be_false
        WriteEnforcer.authorize_update(db, domain, "SubProject", "root_child", ctx).should be_false
      end
    end
  end
end
