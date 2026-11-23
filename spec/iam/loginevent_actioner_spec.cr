# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/oidc_helper"
require "../../src/iam"
require "../../src/audit"

# iam.LoginEvent attribution. `Helpers.write_login_event` picks the mutation
# actioner from an explicit resolved/unresolved signal — never from the id
# shape:
#
# - a resolved subject (a live `iam.Account` row) is the actioner itself, so
#   the audit surface's `actioner_id` filter answers "all login events about
#   account X";
# - a synthetic principal (`system:password`, `system:oidc`, an unresolved
#   IdP `sub`) keeps the `system` actioner.
#
# Helper names carry the `lea_` prefix — top-level helpers must stay
# collision-free with the other spec files compiled into this binary.
private def lea_last_login_event(db) : {String, String}
  db.query_one(
    "SELECT actioner_id, doc_id FROM mutations WHERE domain = 'iam' AND doc_type = 'LoginEvent' " \
    "ORDER BY id DESC LIMIT 1",
    as: {String, String},
  )
end

private def lea_seed_login_event_doctype(db) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "iam", "LoginEvent")
  Facet::Doctype::DefinitionStore.cache.clear
end

# Registers the doctypes the OIDC identity flow reads, seeds one enabled
# provider, and registers the LoginEvent doctype under test.
private def lea_seed_oidc_world(db, auto_provision : Bool) : Nil
  %w[core.DocType core.Domain iam.Account iam.Roles iam.OIDCProvider].each do |dir|
    domain, doctype = dir.split(".", 2)
    Facet::Doctype::Seed.ensure_doctype_definition(db, domain, doctype)
  end
  lea_seed_login_event_doctype(db)
  seed_test_roles(db)
  seed_oidc_provider(db, auto_provision: auto_provision)
end

private def lea_provider(db) : Facet::IAM::OIDC::Provider
  found = Facet::IAM::OIDC::Providers.find(db, "testidp")
  raise "testidp provider not seeded" if found.nil?
  found
end

private def lea_claims(sub : String, email : String) : Facet::IAM::OIDC::Identity::Claims
  Facet::IAM::OIDC::Identity::Claims.new(sub: sub, email: email, email_verified: true, display_name: nil)
end

describe "iam.LoginEvent actioner attribution" do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
    Facet::Event::Publisher.discard
  end

  it "stamps the subject account as the actioner of a resolved event" do
    with_db do |db|
      lea_seed_login_event_doctype(db)
      account_id = create_test_account(db, email: "actor@example.com")

      Facet::IAM::Helpers.write_login_event(db, account_id, "login", "spec probe")

      actioner, _doc_id = lea_last_login_event(db)
      actioner.should eq(account_id)
    end
  end

  it "keeps the system actioner for a synthetic principal" do
    with_db do |db|
      lea_seed_login_event_doctype(db)

      Facet::IAM::Helpers.write_login_event(db, "system:password",
        "password_login_denied", "spec probe", subject_resolved: false)

      actioner, _doc_id = lea_last_login_event(db)
      actioner.should eq("system")
    end
  end

  it "attributes a real login to the subject account" do
    with_db do |db|
      account_id = create_test_account(db)

      result = Facet::IAM::Login.call(
        db,
        email: "test@example.com",
        password: "test-password",
        cookie: false,
      )
      result.should be_a(Facet::IAM::Login::TokensEmitted)

      actioner, _doc_id = lea_last_login_event(db)
      actioner.should eq(account_id)
    end
  end

  it "answers a per-account audit query through the actioner filter" do
    with_db do |db|
      alice = create_test_account(db, email: "audit-alice@example.com")
      create_test_account(db, email: "audit-bob@example.com")

      Facet::IAM::Login.call(db,
        email: "audit-alice@example.com",
        password: "test-password",
        cookie: false).should be_a(Facet::IAM::Login::TokensEmitted)

      audit = Facet::Audit::List.call(db,
        filters: {"actioner_id__eq" => JSON::Any.new(alice)},
        auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      login_rows = audit.items.select { |row| row.doc_type == "LoginEvent" }
      login_rows.size.should eq(1)
      login_rows.all?(&.actioner_id.==(alice)).should be_true

      # Bob holds no login event — his filter answers nothing.
      bob_audit = Facet::Audit::List.call(db,
        filters: {"actioner_id__eq" => JSON::Any.new("no-such-account")},
        auth_context: Facet::RBAC::AuthContext.system).as(Facet::Audit::List::Result)
      bob_audit.items.count { |row| row.doc_type == "LoginEvent" }.should eq(0)
    end
  end

  it "keeps the system actioner for the oidc_only password denial" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      # The `oidc_only` write gate requires one enabled provider document.
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "OIDCProvider")
      seed_oidc_provider(db)
      lea_seed_login_event_doctype(db)
      Facet::SystemSettings.reset_cache!

      Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"iam": {"auth": {"mode": "oidc_only"}}}),
        Facet::RBAC::AuthContext.system,
      ).should be_a(Facet::Document::Update::Result)

      result = Facet::IAM::Login.call(
        db,
        email: "denied@example.com",
        password: "whatever",
        cookie: false,
      )
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)

      actioner, _doc_id = lea_last_login_event(db)
      actioner.should eq("system")
    end
  end

  it "attributes an oidc_denied event to the account when it resolved" do
    with_db do |db|
      lea_seed_oidc_world(db, auto_provision: true)
      account_id = create_test_account(db, email: "susp@example.test", status: "suspended")

      result = Facet::IAM::OIDC::Identity.authenticate(db, lea_provider(db),
        lea_claims("sub-susp", "susp@example.test"))
      result.should be_a(Facet::ServiceError)

      actioner, _doc_id = lea_last_login_event(db)
      actioner.should eq(account_id)
    end
  end

  it "keeps the system actioner for an oidc_denied event with no resolved account" do
    with_db do |db|
      lea_seed_oidc_world(db, auto_provision: false)

      # No account holds this identity and auto-provisioning is off — the
      # denial carries the raw IdP `sub` and stays attributed to `system`.
      result = Facet::IAM::OIDC::Identity.authenticate(db, lea_provider(db),
        lea_claims("sub-unknown", "unknown@example.test"))
      result.should be_a(Facet::ServiceError)

      actioner, doc_id = lea_last_login_event(db)
      actioner.should eq("system")
      subject = db.query_one(
        "SELECT content->>'account_id' FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND id = $1",
        doc_id, as: String)
      subject.should eq("sub-unknown")
    end
  end
end
