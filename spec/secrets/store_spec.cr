# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/secrets/store"
require "../../src/iam/auth_state"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"

# ── Fixture helpers ──────────────────────────────────────────────────────

SECRET_STORE_DOMAIN  = "secretstore"
SECRET_STORE_DOCTYPE = "Widget"

def store_doc_ref(doc_id : String) : String
  "#{SECRET_STORE_DOMAIN}.#{SECRET_STORE_DOCTYPE}.#{doc_id}"
end

def create_store_doc(name : String) : String
  with_db do |db|
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, SECRET_STORE_DOMAIN, SECRET_STORE_DOCTYPE,
      doc_id: doc_id,
      content: %({"name": #{name.to_json}}),
      actioner_id: "system:secrets-spec",
    )
    doc_id
  end
end

def delete_store_doc(doc_id : String) : Nil
  with_db do |db|
    Facet::Mutation::Client.delete(db, SECRET_STORE_DOMAIN, SECRET_STORE_DOCTYPE, doc_id, "system:secrets-spec")
  end
end

def fetch_secret_row(doc_id : String, slot : String) : {String, JSON::Any, Time?, Int32, String, Time}?
  with_db do |db|
    db.query_one?(
      "SELECT value, meta, expires_at, version, set_by, set_at FROM secrets " \
      "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
      SECRET_STORE_DOMAIN, SECRET_STORE_DOCTYPE, doc_id, slot,
      as: {String, JSON::Any, Time?, Int32, String, Time},
    )
  end
end

# ── Specs ────────────────────────────────────────────────────────────────

describe Facet::Secrets do
  before_each do
    with_db do |db|
      ensure_domain(db, SECRET_STORE_DOMAIN)
      Facet::Doctype::DefinitionStore.cache.clear
      body = %({
        "doctype": "#{SECRET_STORE_DOCTYPE}",
        "domain": "#{SECRET_STORE_DOMAIN}",
        "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": { "type": "string" }
        }
      })
      result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
      raise "secrets spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
    end
  end

  describe "resolve" do
    it "splits the qualified reference into the document key" do
      ref = Facet::Secrets.resolve("hr.Employee.01ABCDEF")
      ref.domain.should eq("hr")
      ref.doc_type.should eq("Employee")
      ref.doc_id.should eq("01ABCDEF")
    end

    it "raises on a malformed reference" do
      expect_raises(ArgumentError, /doc_ref/) do
        Facet::Secrets.resolve("only-two.parts")
      end
    end
  end

  describe "set / verify (hash)" do
    it "stores a hash payload and verifies the right candidate" do
      doc_id = create_store_doc("hash-user")
      with_db do |db|
        version = Facet::Secrets.set(db, store_doc_ref(doc_id), "password", "s3cret-pw",
          mode: "hash", set_by: "system:spec")
        version.should eq(1)

        Facet::Secrets.verify(db, store_doc_ref(doc_id), "password", "s3cret-pw").should be_true
        Facet::Secrets.verify(db, store_doc_ref(doc_id), "password", "wrong-pw").should be_false
      end
    end

    it "returns nil for a missing slot" do
      doc_id = create_store_doc("no-slot")
      with_db do |db|
        Facet::Secrets.verify(db, store_doc_ref(doc_id), "nothing", "whatever").should be_nil
      end
    end
  end

  describe "set / reveal (sealed)" do
    it "round-trips a sealed value" do
      doc_id = create_store_doc("sealed-doc")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "api_key", "sk-live-123",
          mode: "sealed", set_by: "system:spec")
        Facet::Secrets.reveal(db, store_doc_ref(doc_id), "api_key").should eq("sk-live-123")
      end
    end

    it "returns nil when the slot is missing" do
      doc_id = create_store_doc("sealed-missing")
      with_db do |db|
        Facet::Secrets.reveal(db, store_doc_ref(doc_id), "absent").should be_nil
      end
    end

    it "returns nil once the TTL has passed" do
      doc_id = create_store_doc("sealed-expired")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "api_key", "short-lived",
          mode: "sealed", set_by: "system:spec", ttl: 5.minutes)
        Facet::Secrets.reveal(db, store_doc_ref(doc_id), "api_key").should eq("short-lived")

        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 minute' " \
          "WHERE doc_id = $1 AND slot = 'api_key'",
          doc_id,
        )
        Facet::Secrets.reveal(db, store_doc_ref(doc_id), "api_key").should be_nil
      end
    end

    it "raises when revealing a non-sealed slot" do
      doc_id = create_store_doc("reveal-hash")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "password", "s3cret-pw",
          mode: "hash", set_by: "system:spec")
        expect_raises(ArgumentError, /sealed/) do
          Facet::Secrets.reveal(db, store_doc_ref(doc_id), "password")
        end
      end
    end
  end

  describe "set / consume (token)" do
    it "consumes exactly once and returns the document key" do
      doc_id = create_store_doc("token-doc")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "raw-opaque-token",
          mode: "token", set_by: "system:spec", ttl: 15.minutes)

        consumed = Facet::Secrets.consume(db, "otp", "raw-opaque-token")
        consumed.should_not be_nil
        consumed.try(&.domain).should eq(SECRET_STORE_DOMAIN)
        consumed.try(&.doc_type).should eq(SECRET_STORE_DOCTYPE)
        consumed.try(&.doc_id).should eq(doc_id)

        # Replay: the row is gone after the first consume.
        Facet::Secrets.consume(db, "otp", "raw-opaque-token").should be_nil
      end
    end

    it "returns nil for a wrong raw token" do
      doc_id = create_store_doc("token-wrong")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "real-token",
          mode: "token", set_by: "system:spec", ttl: 15.minutes)
        Facet::Secrets.consume(db, "otp", "forged-token").should be_nil
      end
    end

    it "honours the domain filter" do
      doc_id = create_store_doc("token-domain")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "scoped-token",
          mode: "token", set_by: "system:spec", ttl: 15.minutes)
        Facet::Secrets.consume(db, "otp", "scoped-token", SECRET_STORE_DOMAIN).should_not be_nil
      end
    end

    it "returns nil when the token is expired" do
      doc_id = create_store_doc("token-expired")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "stale-token",
          mode: "token", set_by: "system:spec", ttl: 1.minute)
        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 minute' " \
          "WHERE doc_id = $1 AND slot = 'otp'",
          doc_id,
        )
        Facet::Secrets.consume(db, "otp", "stale-token").should be_nil
      end
    end
  end

  describe "set validation" do
    it "raises when token mode has no ttl" do
      doc_id = create_store_doc("token-no-ttl")
      with_db do |db|
        expect_raises(ArgumentError, /requires a ttl/) do
          Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "x",
            mode: "token", set_by: "system:spec")
        end
      end
    end

    it "raises when hash mode carries a ttl" do
      doc_id = create_store_doc("hash-with-ttl")
      with_db do |db|
        expect_raises(ArgumentError, /must not carry a ttl/) do
          Facet::Secrets.set(db, store_doc_ref(doc_id), "password", "x",
            mode: "hash", set_by: "system:spec", ttl: 5.minutes)
        end
      end
    end

    it "raises on an unknown mode" do
      doc_id = create_store_doc("bad-mode")
      with_db do |db|
        expect_raises(ArgumentError, /Unknown secret mode/) do
          Facet::Secrets.set(db, store_doc_ref(doc_id), "slot", "x",
            mode: "plaintext", set_by: "system:spec")
        end
      end
    end
  end

  describe "versioning" do
    it "bumps version and refreshes set_at on every write" do
      doc_id = create_store_doc("versioned")
      with_db do |db|
        v1 = Facet::Secrets.set(db, store_doc_ref(doc_id), "api_key", "v1-value",
          mode: "sealed", set_by: "system:spec")
        v1.should eq(1)

        # Pull set_at back so the second write's refresh is observable.
        db.exec(
          "UPDATE secrets SET set_at = now() - interval '1 hour' " \
          "WHERE doc_id = $1 AND slot = 'api_key'",
          doc_id,
        )

        v2 = Facet::Secrets.set(db, store_doc_ref(doc_id), "api_key", "v2-value",
          mode: "sealed", set_by: "system:spec")
        v2.should eq(2)

        row = fetch_secret_row(doc_id, "api_key")
        row.should_not be_nil
        if row
          row[3].should eq(2)
          row[5].should be > Time.utc - 1.minute
        end
      end
    end
  end

  describe "clear" do
    it "removes the slot and is a no-op on an empty slot" do
      doc_id = create_store_doc("cleared")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "api_key", "gone-soon",
          mode: "sealed", set_by: "system:spec")
        Facet::Secrets.clear(db, store_doc_ref(doc_id), "api_key")
        Facet::Secrets.reveal(db, store_doc_ref(doc_id), "api_key").should be_nil

        # Clearing again must not raise.
        Facet::Secrets.clear(db, store_doc_ref(doc_id), "api_key")
      end
    end
  end

  describe "copy_slot" do
    it "copies a hash payload as-is" do
      src = create_store_doc("copy-src")
      dst = create_store_doc("copy-dst")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(src), "password", "copied-pw",
          mode: "hash", set_by: "system:spec", meta: {"origin" => "seed"})
        Facet::Secrets.copy_slot(db, store_doc_ref(src), store_doc_ref(dst), "password")

        Facet::Secrets.verify(db, store_doc_ref(dst), "password", "copied-pw").should be_true
        # The source is untouched.
        Facet::Secrets.verify(db, store_doc_ref(src), "password", "copied-pw").should be_true

        row = fetch_secret_row(dst, "password")
        row.try(&.[1]).should eq(JSON.parse(%({"origin": "seed"})))
        row.try(&.[4]).should eq("system:spec")
      end
    end

    it "re-seals a sealed payload under the target binding" do
      src = create_store_doc("copy-sealed-src")
      dst = create_store_doc("copy-sealed-dst")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(src), "api_key", "sealed-copy",
          mode: "sealed", set_by: "system:spec")
        Facet::Secrets.copy_slot(db, store_doc_ref(src), store_doc_ref(dst), "api_key")

        Facet::Secrets.reveal(db, store_doc_ref(dst), "api_key").should eq("sealed-copy")

        # The copied payload is bound to the target row: opening it under
        # the source binding fails.
        row = fetch_secret_row(dst, "api_key")
        row.should_not be_nil
        expect_raises(ArgumentError) do
          Facet::Secrets::Codec.open(row.try(&.[0]).to_s, store_doc_ref(src), "api_key")
        end
      end
    end

    it "raises when the source slot is empty" do
      src = create_store_doc("copy-empty-src")
      dst = create_store_doc("copy-empty-dst")
      with_db do |db|
        expect_raises(ArgumentError, /No secret/) do
          Facet::Secrets.copy_slot(db, store_doc_ref(src), store_doc_ref(dst), "absent")
        end
      end
    end

    it "refuses to copy a token" do
      src = create_store_doc("copy-token-src")
      dst = create_store_doc("copy-token-dst")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(src), "otp", "single-use",
          mode: "token", set_by: "system:spec", ttl: 15.minutes)
        expect_raises(ArgumentError, /token/) do
          Facet::Secrets.copy_slot(db, store_doc_ref(src), store_doc_ref(dst), "otp")
        end
      end
    end
  end

  describe "prune" do
    it "deletes slots of tombstoned documents past the window and keeps recent ones" do
      old_doc = create_store_doc("tombstoned-old")
      fresh_doc = create_store_doc("tombstoned-fresh")

      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(old_doc), "api_key", "old-value",
          mode: "sealed", set_by: "system:spec")
        Facet::Secrets.set(db, store_doc_ref(fresh_doc), "api_key", "fresh-value",
          mode: "sealed", set_by: "system:spec")
      end

      delete_store_doc(old_doc)
      delete_store_doc(fresh_doc)

      with_db do |db|
        # Age the first tombstone past the window; keep the second inside it.
        db.exec(
          "UPDATE projections SET deleted_at = now() - make_interval(days => $1) WHERE id = $2",
          31, old_doc,
        )

        deleted = Facet::Secrets.prune(db, 30)
        deleted.should eq(1)

        fetch_secret_row(old_doc, "api_key").should be_nil
        fetch_secret_row(fresh_doc, "api_key").should_not be_nil

        # Idempotent: nothing left to prune for the aged tombstone.
        Facet::Secrets.prune(db, 30).should eq(0)
      end
    end

    it "removes expired token rows past the window" do
      doc_id = create_store_doc("prune-token")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "expired-ago",
          mode: "token", set_by: "system:spec", ttl: 1.minute)
        db.exec(
          "UPDATE secrets SET expires_at = now() - make_interval(days => $1) " \
          "WHERE doc_id = $2 AND slot = 'otp'",
          31, doc_id,
        )

        deleted = Facet::Secrets.prune(db, 30)
        deleted.should eq(1)
        fetch_secret_row(doc_id, "otp").should be_nil
      end
    end

    it "keeps an expired token inside the window" do
      doc_id = create_store_doc("prune-token-recent")
      with_db do |db|
        Facet::Secrets.set(db, store_doc_ref(doc_id), "otp", "expired-recently",
          mode: "token", set_by: "system:spec", ttl: 1.minute)
        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 hour' " \
          "WHERE doc_id = $1 AND slot = 'otp'",
          doc_id,
        )

        Facet::Secrets.prune(db, 30).should eq(0)
        fetch_secret_row(doc_id, "otp").should_not be_nil
      end
    end
  end

  describe "iam.Account slots (password / reset)" do
    # The invite flow stores the reset-link token in the `reset` slot and
    # the password hash in the `password` slot of real `iam.Account` docs.
    # These specs pin the slot semantics the bootstrap endpoints rely on.

    it "upserts the reset slot: a second set overwrites the pending link" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "iam.Account.#{account_id}"

        Facet::Secrets.set(db, doc_ref, "reset", "first-link-token",
          mode: "token", set_by: "system", ttl: 15.minutes)
        version = Facet::Secrets.set(db, doc_ref, "reset", "second-link-token",
          mode: "token", set_by: "system", ttl: 15.minutes)
        version.should eq(2)

        # One pending link per account: the first token is gone.
        Facet::Secrets.consume(db, "reset", "first-link-token", domain: "iam").should be_nil
        consumed = Facet::Secrets.consume(db, "reset", "second-link-token", domain: "iam")
        consumed.should_not be_nil
        consumed.try(&.doc_id).should eq(account_id)
      end
    end

    it "requires a ttl on the reset slot and forbids one on the password slot" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "iam.Account.#{account_id}"

        expect_raises(ArgumentError, /requires a ttl/) do
          Facet::Secrets.set(db, doc_ref, "reset", "link-token",
            mode: "token", set_by: "system")
        end

        expect_raises(ArgumentError, /must not carry a ttl/) do
          Facet::Secrets.set(db, doc_ref, "password", "pw",
            mode: "hash", set_by: "system", ttl: 5.minutes)
        end
      end
    end

    it "consumes the reset token exactly once and returns the account id" do
      with_db do |db|
        account_id = create_test_account(db)

        Facet::Secrets.set(db, "iam.Account.#{account_id}", "reset", "single-use-link",
          mode: "token", set_by: "system", ttl: 15.minutes)

        consumed = Facet::Secrets.consume(db, "reset", "single-use-link", domain: "iam")
        consumed.should_not be_nil
        consumed.try(&.domain).should eq("iam")
        consumed.try(&.doc_type).should eq("Account")
        consumed.try(&.doc_id).should eq(account_id)

        # Replay: the row is gone after the first consume.
        Facet::Secrets.consume(db, "reset", "single-use-link", domain: "iam").should be_nil
      end
    end

    it "rejects an expired reset token" do
      with_db do |db|
        account_id = create_test_account(db)

        Facet::Secrets.set(db, "iam.Account.#{account_id}", "reset", "stale-link",
          mode: "token", set_by: "system", ttl: 1.minute)
        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 minute' " \
          "WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
          account_id,
        )

        Facet::Secrets.consume(db, "reset", "stale-link", domain: "iam").should be_nil
      end
    end

    it "returns nil when verifying a missing password slot on an iam.Account doc" do
      with_db do |db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        content = {
          "email" => "noslot@example.com",
          "name"  => "No Slot",
        }.to_json

        Facet::Mutation::Client.create(
          db,
          "iam",
          "Account",
          doc_id: doc_id,
          content: content,
          actioner_id: "system",
        )

        # `nil` means "no local credential yet" — a pending link account.
        # The nil path burns a dummy bcrypt comparison, so this costs the
        # same as a wrong password.
        Facet::Secrets.verify(db, "iam.Account.#{doc_id}", "password", "whatever").should be_nil
      end
    end

    it "leaves no pending link when a password write converges (set password + clear reset)" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "iam.Account.#{account_id}"

        Facet::Secrets.set(db, doc_ref, "reset", "pending-link-token",
          mode: "token", set_by: "system", ttl: 15.minutes)

        Facet::Database.with_transaction(db, ignore_if_set: true) do |txn|
          Facet::Secrets.set(txn, doc_ref, "password", "new-password",
            mode: "hash", set_by: "system")
          Facet::Secrets.clear(txn, doc_ref, "reset")
        end

        Facet::Secrets.verify(db, doc_ref, "password", "new-password").should be_true
        Facet::Secrets.consume(db, "reset", "pending-link-token", domain: "iam").should be_nil
      end
    end
  end

  describe "truncate isolation" do
    # These two examples run back to back: the first leaves rows in both
    # out-of-band tables, the second asserts the per-example TRUNCATE (on
    # `projections`, via the FK cascade) cleared them — no state may leak
    # between examples.
    it "writes a secrets slot and an auth_state row" do
      with_db do |db|
        doc_id = create_store_doc("truncate-isolation")
        ref = "#{SECRET_STORE_DOMAIN}.#{SECRET_STORE_DOCTYPE}.#{doc_id}"
        Facet::Secrets.set(db, ref, "password", "pw",
          mode: "hash", set_by: "system")
        Facet::IAM::AuthState.try_advance_totp_step(db, ref, 7_i64)

        secrets_count = db.query_one("SELECT count(*) FROM secrets", as: Int64)
        secrets_count.should be > 0
        state_count = db.query_one("SELECT count(*) FROM auth_state", as: Int64)
        state_count.should be > 0
      end
    end

    it "starts with empty secrets and auth_state tables" do
      with_db do |db|
        secrets_count = db.query_one("SELECT count(*) FROM secrets", as: Int64)
        secrets_count.should eq(0)
        state_count = db.query_one("SELECT count(*) FROM auth_state", as: Int64)
        state_count.should eq(0)
      end
    end
  end
end
