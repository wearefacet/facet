# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"

# iam.LoginEvent per-account listing. The seed declares `filters: [equality]`
# on `account_id`, so `Document::List` serves `account_id__eq` and answers
# "all login events about account X". The declaration is the gate: an
# operator outside the derived set stays a loud 422 (B-20), never a silent
# unfiltered result.
#
# Helper names carry the `lef_` prefix — top-level helpers must stay
# collision-free with the other spec files compiled into this binary.
private def lef_seed_login_event_doctype(db) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "iam", "LoginEvent")
  Facet::Doctype::DefinitionStore.cache.clear
end

describe "iam.LoginEvent account_id filter" do
  it "serves account_id__eq on the seeded definition" do
    with_db do |db|
      lef_seed_login_event_doctype(db)

      alice = create_test_account(db, email: "flt-alice@example.com")
      bob = create_test_account(db, email: "flt-bob@example.com")

      Facet::IAM::Helpers.write_login_event(db, alice, "login", "alice in")
      Facet::IAM::Helpers.write_login_event(db, bob, "logout", "bob out")

      result = Facet::Document::List.call(db, "iam", "LoginEvent",
        filters: {"account_id__eq" => JSON::Any.new(alice)},
        auth_context: Facet::RBAC::AuthContext.system)
      listing = result.as(Facet::Document::List::Result)

      listing.items.size.should eq(1)
      listing.items.first.content["account_id"].as_s.should eq(alice)
      listing.items.first.content["event"].as_s.should eq("login")

      bob_view = Facet::Document::List.call(db, "iam", "LoginEvent",
        filters: {"account_id__eq" => JSON::Any.new(bob)},
        auth_context: Facet::RBAC::AuthContext.system).as(Facet::Document::List::Result)
      bob_view.items.size.should eq(1)
      bob_view.items.first.content["event"].as_s.should eq("logout")
    end
  end

  it "keeps an undeclared operator a loud 422" do
    with_db do |db|
      lef_seed_login_event_doctype(db)
      account_id = create_test_account(db, email: "flt-neg@example.com")
      Facet::IAM::Helpers.write_login_event(db, account_id, "login")

      result = Facet::Document::List.call(db, "iam", "LoginEvent",
        filters: {"account_id__match" => JSON::Any.new("flt")},
        auth_context: Facet::RBAC::AuthContext.system)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("account_id")
    end
  end
end
