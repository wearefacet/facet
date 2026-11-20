# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/secrets/store"
require "../../src/secrets/staging"
require "../../src/secrets/adoption"
require "../../src/doctype"
require "../../src/document"
require "../../src/document/copy"
require "../../src/audit/rollback"
require "../../src/mutation/client"

# ── Fixture helpers ──────────────────────────────────────────────────────

ADOPTION_DOMAIN  = "secretdocs"
ADOPTION_DOCTYPE = "Vault"

# Registers `secretdocs.Vault` with the secret fields the specs use.
# Doctype registration is create-only (a duplicate answers 409), so a
# re-registration within one example goes through the update path instead.
def adoption_create_vault_doctype(db, with_script : Bool = false) : Nil
  ensure_domain(db, ADOPTION_DOMAIN)
  Facet::Doctype::DefinitionStore.cache.clear

  fields = %({
    "name": { "type": "string" },
    "pw":   { "type": "secret", "mode": "hash" },
    "key":  { "type": "secret", "mode": "sealed" },
    "otp":  { "type": "secret", "mode": "token", "ttl_seconds": 3600 },
    "cred": {
      "type": "object",
      "properties": {
        "token": { "type": "secret", "mode": "hash" }
      }
    }
  })

  script = <<-LUA
    local export = {}
    function export.bind(ctx, args)
      ctx.root.otp = args.h
    end
    return export
  LUA

  actions = %({"bind": {"args": {"h": {"type": "string", "required": true}}}})

  body = %({
    "doctype": "#{ADOPTION_DOCTYPE}",
    "domain": "#{ADOPTION_DOMAIN}",
    "schema_version": 1,
    "fields": #{fields},
    "search": "{{ name }}",
    #{with_script ? "\"actions\": #{actions}, \"script\": #{script.to_json}" : "\"actions\": {}"}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
  return if result.is_a?(Facet::Document::Create::Result)

  err = result.as(Facet::ServiceError)
  # Already registered within this example (the before_each ran the
  # create): re-register as a same-version edit carrying the script.
  if err.status == 409
    update = Facet::Doctype::Update.call(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}", body, Facet::RBAC::AuthContext.system)
    raise "adoption spec doctype update failed: #{update}" unless update.is_a?(Facet::Doctype::Update::Result)
    return
  end
  raise "adoption spec doctype create failed: #{err.message}"
end

# Stages a hash-mode handle for `slot` (raw plaintext) without going
# through the HTTP route.
def adoption_stage_hash(db, slot : String, plaintext : String, created_by : String, domain = ADOPTION_DOMAIN, doc_type = ADOPTION_DOCTYPE) : String
  payload = Facet::Secrets::Codec.hash_payload(plaintext)
  Facet::Secrets::Staging.insert(db, "hash", payload, domain, doc_type, slot, created_by)
end

def adoption_stage_sealed(db, slot : String, plaintext : String, created_by : String, domain = ADOPTION_DOMAIN, doc_type = ADOPTION_DOCTYPE) : String
  handle = "sh_" + Facet::Util::ScriptHelpers.ulid
  payload = Facet::Secrets::Codec.seal(plaintext, Facet::Secrets::Staging.doc_ref(handle), slot)
  Facet::Secrets::Staging.insert(db, "sealed", payload, domain, doc_type, slot, created_by, handle: handle)
end

def adoption_stage_token(db, slot : String, raw_token : String, created_by : String, domain = ADOPTION_DOMAIN, doc_type = ADOPTION_DOCTYPE) : String
  payload = Facet::Secrets::Codec.token_payload(raw_token)
  Facet::Secrets::Staging.insert(db, "token", payload, domain, doc_type, slot, created_by)
end

def adoption_slot_row(doc_id : String, slot : String)
  with_db do |db|
    db.query_one?(
      "SELECT mode, value, version FROM secrets " \
      "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
      ADOPTION_DOMAIN, ADOPTION_DOCTYPE, doc_id, slot,
      as: {String, String, Int32},
    )
  end
end

# A minimal authenticated context with a wildcard role — enough to pass
# the WriteEnforcer gates the pipelines run, while keeping a real account
# id (the staging `created_by` binding).
def adoption_auth(account_id : String = "user-spec") : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "spec-role",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "*", "on": "*.*"})))],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def adoption_create_doc(content_json : String, account_id : String = "user-spec")
  with_db do |db|
    Facet::Document::Create.call(
      db, ADOPTION_DOMAIN, ADOPTION_DOCTYPE, content_json,
      adoption_auth(account_id),
    )
  end
end

def adoption_update_doc(doc_id : String, patch_json : String, account_id : String = "user-spec")
  with_db do |db|
    Facet::Document::Update.call(
      db, ADOPTION_DOMAIN, ADOPTION_DOCTYPE, doc_id, patch_json,
      auth_context: adoption_auth(account_id),
    )
  end
end

def adoption_marker(content : JSON::Any, field : String)
  content[field].as_h?
end

# ── Specs ────────────────────────────────────────────────────────────────

module Facet
  describe Secrets::Adoption do
    before_each do
      with_db do |db|
        adoption_create_vault_doctype(db)
      end
    end

    describe "create with a staged handle" do
      it "lands the marker in content, the payload in the slot, and consumes the staging row" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec") }
        doc = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"}))
        result = doc.should be_a(Facet::Document::Create::Result)

        marker = adoption_marker(result.projection.content, "pw")
        marker.should_not be_nil
        marker.as(Hash(String, JSON::Any))["mode"].as_s.should eq("hash")
        marker.as(Hash(String, JSON::Any))["version"].as_i.should eq(1)
        marker.as(Hash(String, JSON::Any))["set_at"].as_s.should contain("T")

        row = adoption_slot_row(result.projection.id, "pw")
        row.should_not be_nil
        row.as({String, String, Int32})[0].should eq("hash")
        row.as({String, String, Int32})[2].should eq(1)

        with_db do |db|
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{result.projection.id}", "pw", "s3cret-pw").should be_true
          Facet::Secrets::Staging.load(db, handle).should be_nil
        end
      end

      it "never writes the handle into the mutation" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec") }
        result = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"}))
        result = result.should be_a(Facet::Document::Create::Result)

        with_db do |db|
          args = db.query_one(
            "SELECT arguments FROM mutations WHERE doc_id = $1 AND action = 'create'",
            result.projection.id, as: JSON::Any)
          args.to_json.should_not contain(handle)
          args.to_json.should_not contain("s3cret-pw")
        end
      end

      it "keeps handles out of the search GUC" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec") }
        result = adoption_create_doc(%({"name": "findme", "pw": "#{handle}"}))
        result = result.should be_a(Facet::Document::Create::Result)

        with_db do |db|
          search = db.query_one(
            "SELECT search FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
            ADOPTION_DOMAIN, ADOPTION_DOCTYPE, result.projection.id, as: String?)
          search = search.as(String)
          search.should contain("findme")
          search.should_not contain(handle)
        end
      end

      it "adopts a staged sealed payload and reveals under the final binding" do
        handle = with_db { |db| adoption_stage_sealed(db, "key", "sk-live-123", "user-spec") }
        result = adoption_create_doc(%({"name": "n1", "key": "#{handle}"}))
        result = result.should be_a(Facet::Document::Create::Result)

        with_db do |db|
          Facet::Secrets.reveal(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{result.projection.id}", "key").should eq("sk-live-123")
        end
      end

      it "adopts a handle inside an object property" do
        handle = with_db { |db| adoption_stage_hash(db, "cred.token", "inner-secret", "user-spec") }
        result = adoption_create_doc(%({"name": "n1", "cred": {"token": "#{handle}"}}))
        result = result.should be_a(Facet::Document::Create::Result)

        marker = result.projection.content["cred"].as_h["token"].as_h
        marker["version"].as_i.should eq(1)

        with_db do |db|
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{result.projection.id}", "cred.token", "inner-secret").should be_true
        end
      end
    end

    describe "update" do
      it "sets a new handle (version bumps), keeps (absent), and clears (null)" do
        handle1 = with_db { |db| adoption_stage_hash(db, "pw", "first-pw", "user-spec") }
        created = adoption_create_doc(%({"name": "n1", "pw": "#{handle1}"}))
        created = created.should be_a(Facet::Document::Create::Result)
        doc_id = created.projection.id

        # Set — a new handle bumps the slot version and the marker.
        handle2 = with_db { |db| adoption_stage_hash(db, "pw", "second-pw", "user-spec") }
        updated = adoption_update_doc(doc_id, %({"pw": "#{handle2}"}))
        updated = updated.should be_a(Facet::Document::Update::Result)
        adoption_marker(updated.projection.content, "pw").as(Hash(String, JSON::Any))["version"].as_i.should eq(2)
        with_db do |db|
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{doc_id}", "pw", "second-pw").should be_true
        end

        # Keep — a patch that does not touch the field leaves marker and slot alone.
        kept = adoption_update_doc(doc_id, %({"name": "n2"}))
        kept = kept.should be_a(Facet::Document::Update::Result)
        adoption_marker(kept.projection.content, "pw").as(Hash(String, JSON::Any))["version"].as_i.should eq(2)
        with_db do |db|
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{doc_id}", "pw", "second-pw").should be_true
        end

        # Clear — null removes the key (merge patch) and deletes the slot.
        cleared = adoption_update_doc(doc_id, %({"pw": null}))
        cleared = cleared.should be_a(Facet::Document::Update::Result)
        cleared.projection.content.as_h.has_key?("pw").should be_false
        adoption_slot_row(doc_id, "pw").should be_nil
      end

      it "treats a clear on an unset field as a no-op success" do
        created = adoption_create_doc(%({"name": "n1"}))
        created = created.should be_a(Facet::Document::Create::Result)

        cleared = adoption_update_doc(created.projection.id, %({"pw": null}))
        cleared.should be_a(Facet::Document::Update::Result)
      end

      it "rejects a forged marker (wrong version)" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec") }
        created = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"}))
        created = created.should be_a(Facet::Document::Create::Result)

        forged = adoption_update_doc(
          created.projection.id,
          %({"pw": {"mode": "hash", "version": 99, "set_at": "2026-09-06T10:00:00Z"}}),
        )
        err = forged.should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("marker does not match")
      end

      it "rejects a marker for a slot that does not exist" do
        forged = adoption_create_doc(
          %({"name": "n1", "pw": {"mode": "hash", "version": 1, "set_at": "2026-09-06T10:00:00Z"}}),
        )
        err = forged.should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("marker does not match")
      end

      it "accepts an older marker after a rollback replay (slot stays current)" do
        handle1 = with_db { |db| adoption_stage_hash(db, "pw", "first-pw", "user-spec") }
        created = adoption_create_doc(%({"name": "n1", "pw": "#{handle1}"}))
        created = created.should be_a(Facet::Document::Create::Result)
        doc_id = created.projection.id
        v1_marker = created.projection.content["pw"]

        handle2 = with_db { |db| adoption_stage_hash(db, "pw", "second-pw", "user-spec") }
        adoption_update_doc(doc_id, %({"pw": "#{handle2}"}))

        # Rollback to the create mutation replays the v1 marker without
        # touching slots — documented semantics (locked decision 7).
        rolled = with_db do |db|
          create_mut = db.query_one(
            "SELECT id FROM mutations WHERE doc_id = $1 AND action = 'create' ORDER BY idx LIMIT 1",
            doc_id, as: String)
          Facet::Audit::Rollback.call(db, create_mut, Facet::RBAC::AuthContext.system)
        end
        rolled.should be_a(Facet::Audit::Rollback::Result)

        with_db do |db|
          proj = Facet::Mutation::Client.fetch_projection(db, ADOPTION_DOMAIN, ADOPTION_DOCTYPE, doc_id)
          proj.content["pw"].should eq(v1_marker)
          # The slot value stays current — old credentials must not resurrect.
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{doc_id}", "pw", "second-pw").should be_true
          Facet::Secrets.verify(db, "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{doc_id}", "pw", "first-pw").should be_false
        end

        # The document stays writable: an update carrying the older merged
        # marker passes verification, and the slot version never rewinds.
        after = adoption_update_doc(doc_id, %({"name": "n3"}))
        after.should be_a(Facet::Document::Update::Result)
        adoption_slot_row(doc_id, "pw").as({String, String, Int32})[2].should eq(2)
      end
    end

    describe "handle validation" do
      it "rejects an expired handle" do
        handle = with_db do |db|
          h = adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec")
          db.exec("UPDATE secret_staging SET expires_at = now() - interval '1 minute' WHERE id = $1", h)
          h
        end
        err = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"})).should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("unknown, expired, or not yours")
      end

      it "rejects a replayed handle (second use)" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-spec") }
        adoption_create_doc(%({"name": "n1", "pw": "#{handle}"})).should be_a(Facet::Document::Create::Result)

        err = adoption_create_doc(%({"name": "n2", "pw": "#{handle}"})).should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("unknown, expired, or not yours")
      end

      it "rejects a handle staged by another account" do
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "user-b") }
        err = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"}), "user-a").should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("unknown, expired, or not yours")
      end

      it "rejects a mode mismatch between the field and the staged payload" do
        handle = with_db { |db| adoption_stage_sealed(db, "pw", "s3cret-pw", "user-spec") }
        err = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"})).should be_a(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("unknown, expired, or not yours")
      end

      it "rejects a handle targeted at another doctype" do
        # Staged for the same domain but a different doctype name.
        handle = with_db { |db| adoption_stage_hash(db, "pw", "s3cret-pw", "system", doc_type: "Other") }
        err = adoption_create_doc(%({"name": "n1", "pw": "#{handle}"})).should be_a(Facet::ServiceError)
        err.status.should eq(422)
      end

      it "rejects a value the type layer could not have produced" do
        err = adoption_create_doc(%({"name": "n1", "pw": 42})).should be_a(Facet::ServiceError)
        err.status.should eq(422)
      end
    end

    describe "action carrying a handle through Lua" do
      it "adopts a handle a script passed into a secret field" do
        with_db do |db|
          adoption_create_vault_doctype(db, with_script: true)
        end

        created = adoption_create_doc(%({"name": "n1"}))
        created = created.should be_a(Facet::Document::Create::Result)

        raw_token = "tok-#{unique_suffix(12)}"
        handle = with_db { |db| adoption_stage_token(db, "otp", raw_token, "system") }
        actioned = with_db do |db|
          Facet::Document::Action.call(
            db, ADOPTION_DOMAIN, ADOPTION_DOCTYPE, created.projection.id, "bind",
            %({"h": "#{handle}"}), Facet::RBAC::AuthContext.system,
          )
        end
        actioned = actioned.should be_a(Facet::Document::Action::Result)

        marker = actioned.projection.content["otp"].as_h
        marker["mode"].as_s.should eq("token")
        adoption_slot_row(created.projection.id, "otp").should_not be_nil

        with_db do |db|
          Facet::Secrets::Staging.load(db, handle).should be_nil
        end
      end
    end

    describe "copy" do
      it "copies a sealed slot re-sealed under the target ref and strips token markers" do
        target_domain = "secretdocs-#{unique_suffix(6).downcase}"
        with_db do |db|
          ensure_domain(db, target_domain)
          Facet::Doctype::DefinitionStore.cache.clear
          # Same doctype registered in the target domain.
          body = %({
            "doctype": "#{ADOPTION_DOCTYPE}",
            "domain": "#{target_domain}",
            "schema_version": 1,
            "fields": {
              "name": { "type": "string" },
              "pw":   { "type": "secret", "mode": "hash" },
              "key":  { "type": "secret", "mode": "sealed" },
              "otp":  { "type": "secret", "mode": "token", "ttl_seconds": 3600 }
            }
          })
          result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
          raise "target doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
        end

        hash_handle = with_db { |db| adoption_stage_hash(db, "pw", "copied-pw", "user-spec") }
        sealed_handle = with_db { |db| adoption_stage_sealed(db, "key", "copied-sk", "user-spec") }
        token_handle = with_db { |db| adoption_stage_token(db, "otp", "copied-token-raw", "user-spec") }
        created = adoption_create_doc(
          %({"name": "orig", "pw": "#{hash_handle}", "key": "#{sealed_handle}", "otp": "#{token_handle}"}),
        )
        created = created.should be_a(Facet::Document::Create::Result)

        new_id = with_db do |db|
          Facet::Document::Copy.deep_copy(
            db, ADOPTION_DOMAIN, target_domain, ADOPTION_DOCTYPE, created.projection.id, "system",
          )
        end
        new_id = new_id.should be_a(String)

        from_ref = "#{ADOPTION_DOMAIN}.#{ADOPTION_DOCTYPE}.#{created.projection.id}"
        to_ref = "#{target_domain}.#{ADOPTION_DOCTYPE}.#{new_id}"

        with_db do |db|
          # Sealed: re-sealed under the target binding — the copy reveals,
          # and the source payload still opens under the source binding.
          Facet::Secrets.reveal(db, to_ref, "key").should eq("copied-sk")
          Facet::Secrets.reveal(db, from_ref, "key").should eq("copied-sk")

          # Hash: copied as-is and still verifies.
          Facet::Secrets.verify(db, to_ref, "pw", "copied-pw").should be_true

          # Token: not copied — a token must not serve two documents.
          adoption_slot_row(created.projection.id, "otp").should_not be_nil
          row = db.query_one?(
            "SELECT 1 FROM secrets WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = 'otp'",
            target_domain, ADOPTION_DOCTYPE, new_id, as: Int32)
          row.should be_nil
        end

        # Token marker stripped from the copied content.
        with_db do |db|
          proj = Facet::Mutation::Client.fetch_projection(db, target_domain, ADOPTION_DOCTYPE, new_id)
          proj.content.as_h.has_key?("otp").should be_false
          proj.content["key"].as_h["version"].as_i.should eq(1)
        end
      end
    end
  end
end
