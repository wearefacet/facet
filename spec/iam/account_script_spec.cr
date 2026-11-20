# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/rbac"

# The seeded `iam.Account` create hook (bootstrap rule):
#
#   - a HUMAN account starts `pending` — no credential, no federation yet;
#     the first full login flips it to `active` (Facet::IAM::Login);
#   - service accounts are machine identities (API keys require `active`);
#   - JIT-provisioned OIDC accounts carry `federated_identities` and are
#     created `active` by the provider flow;
#   - an explicit `suspended` / `disabled` create status is honoured.
private def account_status(db, id) : String?
  db.query_one?("SELECT content->>'status' FROM projections WHERE id = $1", id, as: String)
end

describe "iam.Account lifecycle script" do
  it "creates a human account pending, even when active is submitted" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      result = Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-human@example.test", "name": "Hook Human", "status": "active"}),
        Facet::RBAC::AuthContext.system,
      )
      created = expect_create_success(result)
      account_status(db, created.projection.id).should eq("pending")
    end
  end

  it "creates a human account pending when no status is submitted" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      result = Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-nohuman@example.test", "name": "Hook NoStatus"}),
        Facet::RBAC::AuthContext.system,
      )
      created = expect_create_success(result)
      account_status(db, created.projection.id).should eq("pending")
    end
  end

  it "keeps a service account active" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      result = Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-service@example.test", "name": "Hook Service", "service_account": true}),
        Facet::RBAC::AuthContext.system,
      )
      created = expect_create_success(result)
      account_status(db, created.projection.id).should eq("active")
    end
  end

  it "keeps an explicit suspended status on a human account" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      result = Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-susp@example.test", "name": "Hook Suspended", "status": "suspended"}),
        Facet::RBAC::AuthContext.system,
      )
      created = expect_create_success(result)
      account_status(db, created.projection.id).should eq("suspended")
    end
  end

  it "keeps a JIT-provisioned federated account active" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      link = %([{"provider": "testidp", "subject": "sub-hook", "linked_at": "2026-01-01T00:00:00Z"}])
      result = Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-fed@example.test", "name": "Hook Fed", "status": "active", "federated_identities": #{link}}),
        Facet::RBAC::AuthContext.system,
      )
      created = expect_create_success(result)
      account_status(db, created.projection.id).should eq("active")
    end
  end

  it "does not force pending on update" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      created = expect_create_success(Facet::Document::Create.call(
        db, "iam", "Account",
        %({"email": "hook-upd@example.test", "name": "Hook Upd"}),
        Facet::RBAC::AuthContext.system,
      ))
      account_status(db, created.projection.id).should eq("pending")

      updated = Facet::Document::Update.call(
        db, "iam", "Account", created.projection.id,
        %({"status": "active"}),
        Facet::RBAC::AuthContext.system,
      )
      updated.should be_a(Facet::Document::Update::Result)
      account_status(db, created.projection.id).should eq("active")
    end
  end
end
