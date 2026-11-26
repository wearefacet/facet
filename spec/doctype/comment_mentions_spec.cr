# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/doctype/seed"
require "../../src/document"
require "../../src/notifications"
require "../../src/iam/helpers"

# The seeded `core.Comment` mention hook (`data/seeds/core.Comment/script.lua`).
#
# Each example registers the production seed (definition + script) through
# the seed pipeline, drives comments through `Document::Create` /
# `Document::Update` with an authenticated actor context, and asserts on
# real `notifications` rows.
#
# `allow_system_writes` + `skip_authorization` mirror the production nested
# route: `SidecarHandler` sets the `target` reference from the path, then
# delegates to `Document::Create` with both flags set after enforcing its
# own gates. These examples cover the hook, not the route gates.

# An active iam → core grant on Account, so the hook's label reads
# (`document.get("iam.Account", …)` for the actor and the host) pass the
# cross-domain grant ceiling.
private def upsert_account_grant(db) : Nil
  upsert_grant(db, "iam", "core", %([{"doctype": "Account", "tags": ["default"]}]))
end

private def mention_actor_ctx(db, account_id : String) : Facet::RBAC::AuthContext
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

private def create_mention_comment(db, auth, target : String, body : String) : Facet::Document::Create::Result
  result = Facet::Document::Create.call(
    db, "core", "Comment",
    %({"target": #{target.to_json}, "body": #{body.to_json}}),
    auth, allow_system_writes: true, skip_authorization: true)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result)
end

private def update_mention_comment(db, auth, comment_id : String, body : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "Comment", comment_id, %({"body": #{body.to_json}}), auth, skip_authorization: true)
  result.should be_a(Facet::Document::Update::Result)
end

# One tuple per notification, oldest first:
# {account_id, kind, icon, title, domain, doc_type, doc_id}.
private def mention_notification_rows(db) : Array(Tuple(String, String, String?, String, String, String, String))
  db.query_all(
    "SELECT account_id, kind, icon, title, domain, doc_type, doc_id " \
    "FROM notifications ORDER BY created_at, id",
  ) do |rs|
    {
      rs.read(String), rs.read(String), rs.read(String?), rs.read(String),
      rs.read(String), rs.read(String), rs.read(String),
    }
  end
end

private def mention_rows_for(rows, account_id : String)
  rows.select { |row| row[0] == account_id }
end

describe "core.Comment mention notifications" do
  before_each do
    with_db do |db|
      # `notifications` is not in the global truncation list.
      db.exec("TRUNCATE notifications")
      ensure_domain(db, "core")
      ensure_domain(db, "iam")
      Facet::Doctype::Seed.ensure_doctype(db, "core", "Comment")
    end
  end

  it "notifies each mentioned account once, routed to the host document" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "author-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      bob = create_test_account(db, email: "bob-#{unique_suffix}@example.com", display_name: "Bob Ferris")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Ping [Alice](urn:facet:iam:Account:#{alice}) and [Bob](urn:facet:iam:Account:#{bob}).",
      )

      rows = mention_notification_rows(db)
      rows.size.should eq(2)

      alice_rows = mention_rows_for(rows, alice)
      alice_rows.size.should eq(1)
      alice_rows[0][1].should eq("comment_mention")
      alice_rows[0][2].should eq("at-sign")
      alice_rows[0][3].should eq("Ada Lovelace mentioned you on Host Record")
      # The notification points at the host document, not the comment.
      alice_rows[0][4].should eq("iam")
      alice_rows[0][5].should eq("Account")
      alice_rows[0][6].should eq(host)

      bob_rows = mention_rows_for(rows, bob)
      bob_rows.size.should eq(1)
      bob_rows[0][3].should eq("Ada Lovelace mentioned you on Host Record")
      bob_rows[0][6].should eq(host)
    end
  end

  it "skips the comment author" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "self-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      bob = create_test_account(db, email: "bob-#{unique_suffix}@example.com", display_name: "Bob Ferris")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Note to [myself](urn:facet:iam:Account:#{author}) and [Bob](urn:facet:iam:Account:#{bob}).",
      )

      rows = mention_notification_rows(db)
      rows.size.should eq(1)
      rows[0][0].should eq(bob)
    end
  end

  it "keeps the comment when a mention names an unknown account" do
    with_db do |db|
      author = create_test_account(db, email: "ghost-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")
      ghost = Facet::Util::ScriptHelpers.ulid

      result = create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Ping [Ghost](urn:facet:iam:Account:#{ghost}).",
      )
      result.projection.content["body"].as_s.should contain("Ghost")

      # The pcall contained the send-time enqueue rejection — the comment
      # persisted and no notification row exists.
      mention_notification_rows(db).size.should eq(0)
    end
  end

  it "dedupes repeated mentions in one body (link and bare form)" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "dup-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Twice [Alice](urn:facet:iam:Account:#{alice}) and again urn:facet:iam:Account:#{alice} bare.",
      )

      rows = mention_notification_rows(db)
      rows.size.should eq(1)
      rows[0][0].should eq(alice)
    end
  end

  it "degrades the title when the iam.Account read is not granted" do
    with_db do |db|
      # No DomainGrant from iam to core — the default install. The label
      # fetches fail the grant ceiling; the mention still notifies with a
      # generic actor label and no host suffix.
      author = create_test_account(db, email: "degraded-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Ping [Alice](urn:facet:iam:Account:#{alice}).",
      )

      rows = mention_notification_rows(db)
      rows.size.should eq(1)
      rows[0][0].should eq(alice)
      rows[0][3].should eq("Someone mentioned you")
      rows[0][6].should eq(host)
    end
  end

  it "sends nothing for a system-context create" do
    with_db do |db|
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      result = Facet::Document::Create.call(
        db, "core", "Comment",
        %({"target": "iam.Account.#{host}", "body": "Ping [Alice](urn:facet:iam:Account:#{alice})."}),
        Facet::RBAC::AuthContext.system, allow_system_writes: true, skip_authorization: true)
      result.should be_a(Facet::Document::Create::Result)

      mention_notification_rows(db).size.should eq(0)
    end
  end

  it "notifies net-new mentions only on update" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "editor-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      bob = create_test_account(db, email: "bob-#{unique_suffix}@example.com", display_name: "Bob Ferris")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      comment = create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Ping [Alice](urn:facet:iam:Account:#{alice}).",
      )

      # Bob joins; Alice stays. Alice must not hear again — one row total.
      update_mention_comment(
        db, mention_actor_ctx(db, author), comment.projection.id,
        "Ping [Alice](urn:facet:iam:Account:#{alice}) and [Bob](urn:facet:iam:Account:#{bob}).",
      )

      rows = mention_notification_rows(db)
      mention_rows_for(rows, alice).size.should eq(1)
      mention_rows_for(rows, bob).size.should eq(1)
    end
  end

  it "stays silent when an update resubmits the same body" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "same-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      body = "Ping [Alice](urn:facet:iam:Account:#{alice})."
      comment = create_mention_comment(db, mention_actor_ctx(db, author), "iam.Account.#{host}", body)
      update_mention_comment(db, mention_actor_ctx(db, author), comment.projection.id, body)

      mention_rows_for(mention_notification_rows(db), alice).size.should eq(1)
    end
  end

  it "re-notifies a mention removed and re-added" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "readd-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      comment_id = create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}", "No mentions yet.",
      ).projection.id

      # Add — net-new, notifies.
      update_mention_comment(
        db, mention_actor_ctx(db, author), comment_id,
        "Ping [Alice](urn:facet:iam:Account:#{alice}).",
      )
      mention_rows_for(mention_notification_rows(db), alice).size.should eq(1)

      # Remove — no notification.
      update_mention_comment(db, mention_actor_ctx(db, author), comment_id, "Mention removed.")
      mention_rows_for(mention_notification_rows(db), alice).size.should eq(1)

      # Re-add — net-new again against the mention-free old body.
      update_mention_comment(
        db, mention_actor_ctx(db, author), comment_id,
        "Back: [Alice](urn:facet:iam:Account:#{alice}).",
      )
      mention_rows_for(mention_notification_rows(db), alice).size.should eq(2)
    end
  end

  it "notifies a mention whose account id is the account's email" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "author-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      jean = create_test_account(
        db, email: "jean-#{unique_suffix}@amplitude-solutions.com",
        display_name: "Jean Emmanuel Wattier",
        doc_id: "jean-#{unique_suffix}@amplitude-solutions.com",
      )
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      # Link form (what the composer inserts) and bare form closed by a
      # sentence period — the trailing dot is prose, not the id.
      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "Hey [@Jean](urn:facet:iam:Account:#{jean}) and again urn:facet:iam:Account:#{jean}.",
      )

      rows = mention_rows_for(mention_notification_rows(db), jean)
      rows.size.should eq(1)
      rows[0][1].should eq("comment_mention")
      rows[0][3].should eq("Ada Lovelace mentioned you on Host Record")
      rows[0][6].should eq(host)
    end
  end

  it "routes a comment on an email-id account to that host" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "author-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      alice = create_test_account(db, email: "alice-#{unique_suffix}@example.com", display_name: "Alice Chen")
      jean = create_test_account(
        db, email: "jean-host-#{unique_suffix}@amplitude-solutions.com",
        display_name: "Jean Emmanuel Wattier",
        doc_id: "jean-host-#{unique_suffix}@amplitude-solutions.com",
      )

      # The comment's target (and so the notification's doc_ref) carries
      # the email id — the dotted reference must survive the enqueue-time
      # `DocURI` validation with the id whole.
      create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{jean}",
        "Ping [Alice](urn:facet:iam:Account:#{alice}).",
      )

      rows = mention_rows_for(mention_notification_rows(db), alice)
      rows.size.should eq(1)
      rows[0][3].should eq("Ada Lovelace mentioned you on Jean Emmanuel Wattier")
      rows[0][4].should eq("iam")
      rows[0][5].should eq("Account")
      rows[0][6].should eq(jean)
    end
  end

  it "notifies net-new email-id mentions on update" do
    with_db do |db|
      upsert_account_grant(db)
      author = create_test_account(db, email: "editor-#{unique_suffix}@example.com", display_name: "Ada Lovelace")
      jean = create_test_account(
        db, email: "jean-edit-#{unique_suffix}@amplitude-solutions.com",
        display_name: "Jean Emmanuel Wattier",
        doc_id: "jean-edit-#{unique_suffix}@amplitude-solutions.com",
      )
      host = create_test_account(db, email: "host-#{unique_suffix}@example.com", display_name: "Host Record")

      comment = create_mention_comment(
        db, mention_actor_ctx(db, author), "iam.Account.#{host}",
        "No one yet.",
      )

      update_mention_comment(
        db, mention_actor_ctx(db, author), comment.projection.id,
        "Now: [@Jean](urn:facet:iam:Account:#{jean}).",
      )

      rows = mention_rows_for(mention_notification_rows(db), jean)
      rows.size.should eq(1)
      rows[0][3].should eq("Ada Lovelace mentioned you on Host Record")
    end
  end
end
