# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "../../src/rbac"
require "../../src/doctype"
require "json"

# The `iam.Account` doctype carries a Lua script that deduplicates its `roles`
# reference array at the write boundary (create and update). A duplicate role
# id would crash the frontend's keyed `{#each}` on the assignments page, so
# this invariant is enforced server-side.
describe "iam.Account roles dedup" do
  before_each do
    # The per-test TRUNCATE wipes the seeded doctypes; re-ensure the
    # `iam.Account` definition (with its script) and the `iam` domain
    # (idempotent, ~10 ms).
    with_db do |db|
      %w[core.DocType core.Domain iam.Account].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  it "deduplicates roles on create" do
    with_db do |db|
      body = %({
        "email": "dedup.create@example.com",
        "name": "Dedup Create",
        "status": "active",
        "roles": ["iam.Roles.admin", "iam.Roles.editor", "iam.Roles.admin"]
      })
      result = Facet::Document::Create.call(db, "iam", "Account", body, Facet::RBAC::AuthContext.system)
      proj = expect_create_success(result).projection

      roles = proj.content["roles"].as_a.map(&.as_s)
      roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
    end
  end

  it "leaves a duplicate-free roles array unchanged on create" do
    with_db do |db|
      body = %({
        "email": "dedup.clean@example.com",
        "name": "Dedup Clean",
        "status": "active",
        "roles": ["iam.Roles.admin", "iam.Roles.editor"]
      })
      result = Facet::Document::Create.call(db, "iam", "Account", body, Facet::RBAC::AuthContext.system)
      proj = expect_create_success(result).projection

      roles = proj.content["roles"].as_a.map(&.as_s)
      roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
    end
  end

  it "deduplicates roles on update when the patch reintroduces a duplicate" do
    with_db do |db|
      create_body = %({
        "email": "dedup.update@example.com",
        "name": "Dedup Update",
        "status": "active",
        "roles": ["iam.Roles.admin"]
      })
      created = expect_create_success(
        Facet::Document::Create.call(db, "iam", "Account", create_body, Facet::RBAC::AuthContext.system)
      )
      account_id = created.projection.id

      result = Facet::Document::Update.call(
        db, "iam", "Account", account_id,
        %({"roles": ["iam.Roles.admin", "iam.Roles.editor", "iam.Roles.admin"]}),
        Facet::RBAC::AuthContext.system
      )
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection

      roles = proj.content["roles"].as_a.map(&.as_s)
      roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
    end
  end

  it "deduplicates an already-persisted duplicate on update" do
    with_db do |db|
      # Insert an account directly with a duplicate roles array, bypassing the
      # create hook, to model legacy / corrupt persisted state.
      account_id = Facet::Util::ScriptHelpers.ulid
      Facet::Mutation::Client.create(
        db, "iam", "Account", doc_id: account_id,
        content: %({
          "email": "dedup.legacy@example.com",
          "name": "Dedup Legacy",
          "status": "active",
          "roles": ["iam.Roles.admin", "iam.Roles.admin", "iam.Roles.editor"]
        }),
        actioner_id: "system"
      )

      result = Facet::Document::Update.call(
        db, "iam", "Account", account_id,
        %({"status": "suspended"}),
        Facet::RBAC::AuthContext.system
      )
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection

      roles = proj.content["roles"].as_a.map(&.as_s)
      roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
    end
  end
end
