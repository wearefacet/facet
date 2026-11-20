# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/secrets/staging"
require "../../src/document"

# Resolution specs: document value wins, null follows the file, the file
# default fills what the file leaves unset, a missing document follows the
# file everywhere, and pins mirror the document state. Secret values
# resolve through the store and never enter the cache.
#
# The per-example truncation wipes every projection — doctype definitions
# included — so each example re-seeds the `core.SystemSettings` doctype
# through `Doctype::Seed.ensure_doctype` (definition + the null singleton
# document, exactly the production posture).
#
# NOTE: spec-local helpers live at file top level (a def inside `describe`
# does not compile).

private def patch_settings(db, patch : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  # No Redis fanout runs in the unit suite — invalidate like the subscriber.
  Facet::SystemSettings.mark_stale
end

private def drop_settings(db) : Nil
  db.exec(
    "DELETE FROM projections WHERE domain = 'core' AND doc_type = 'SystemSettings' AND id = $1",
    Facet::SystemSettings::DOC_ID,
  )
  Facet::SystemSettings.mark_stale
end

private def stage_secret(db, field_path : String, plaintext : String) : String
  handle = "sh_" + Facet::Util::ScriptHelpers.ulid
  payload = Facet::Secrets::Codec.seal(plaintext, Facet::Secrets::Staging.doc_ref(handle), field_path)
  Facet::Secrets::Staging.insert(db, "sealed", payload, "core", "SystemSettings", field_path, "system", handle: handle)
  handle
end

describe Facet::SystemSettings do
  before_each do
    Facet::SystemSettings.reset_cache!
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  describe "effective / value_at" do
    it "follows the file when the document is missing" do
      with_db do |db|
        drop_settings(db)
        values = Facet::SystemSettings.effective(db)
        config = Facet::Config.instance
        values["assistant.model"].as_s.should eq(config.assistant.model)
        values["mail.adapter"].as_s.should eq(config.mail.adapter)
        values["mail.from_address"].as_s.should eq(config.mail.from_address)
      end
    end

    it "follows the file when every document field is null" do
      with_db do |db|
        values = Facet::SystemSettings.effective(db)
        values["assistant.model"].as_s.should eq(Facet::Config.instance.assistant.model)
      end
    end

    it "lets the document value win when pinned" do
      with_db do |db|
        patch_settings(db, %({"assistant": {"model": "spec-model", "max_tokens": 512, "temperature": 0.7, "auto_execute_tools": false}}))
        values = Facet::SystemSettings.effective(db)
        values["assistant.model"].as_s.should eq("spec-model")
        values["assistant.max_tokens"].as_i64.should eq(512)
        values["assistant.temperature"].as_f.should eq(0.7)
        values["assistant.auto_execute_tools"].as_bool.should be_false
      end
    end

    it "falls back to the built-in default when file and document leave a key unset" do
      with_db do |db|
        # config.test.yml sets no assistant.max_tokens; the null document
        # pins nothing, so the built-in default (null = no cap) shows.
        Facet::SystemSettings.value_at(db, "assistant.max_tokens").try(&.raw).should be_nil
        # A defaulted key still resolves through the file even unset everywhere.
        Facet::SystemSettings.value_at(db, "assistant.model")
          .try(&.as_s).should eq(Facet::Config.instance.assistant.model)
      end
    end

    it "resolves the artifact and retention windows when pinned" do
      with_db do |db|
        patch_settings(db, %({
          "artifact": {"grant_ttl_seconds": 7200, "prune_after_days": 7},
          "mutations": {"retention_days": 90},
          "tombstone": {"content_retention_days": 14}
        }))
        Facet::SystemSettings.int_at(db, "artifact.grant_ttl_seconds").should eq(7200)
        Facet::SystemSettings.int_at(db, "artifact.prune_after_days").should eq(7)
        Facet::SystemSettings.int_at(db, "mutations.retention_days").should eq(90)
        Facet::SystemSettings.int_at(db, "tombstone.content_retention_days").should eq(14)
        Facet::SystemSettings.pinned(db).sort.should eq([
          "artifact.grant_ttl_seconds",
          "artifact.prune_after_days",
          "mutations.retention_days",
          "tombstone.content_retention_days",
        ])
      end
    end

    it "follows the file for the artifact and retention paths when unpinned" do
      with_db do |db|
        config = Facet::Config.instance
        Facet::SystemSettings.int_at(db, "artifact.grant_ttl_seconds")
          .should eq(config.artifact.grant_ttl_seconds)
        Facet::SystemSettings.int_at(db, "mutations.retention_days")
          .should eq(config.mutations.retention_days)
        Facet::SystemSettings.int_at(db, "tombstone.content_retention_days")
          .should eq(config.tombstone.content_retention_days)
        Facet::SystemSettings.value_at(db, "artifact.storage.type")
          .try(&.as_s).should eq(config.artifact.storage.type)
      end
    end

    it "raises on an unknown path in value_at" do
      with_db do |db|
        expect_raises(ArgumentError, "Unknown system setting path") do
          Facet::SystemSettings.value_at(db, "assistant.wat")
        end
      end
    end

    it "excludes secret paths from the effective values" do
      with_db do |db|
        values = Facet::SystemSettings.effective(db)
        values.has_key?("assistant.api_key").should be_false
        values.has_key?("mail.smtp.password").should be_false
        values.size.should eq(Facet::SystemSettings::SPEC.size - 2)
      end
    end
  end

  describe "pinned" do
    it "is empty when the document is missing or all-null" do
      with_db do |db|
        Facet::SystemSettings.pinned(db).should be_empty
        drop_settings(db)
        Facet::SystemSettings.pinned(db).should be_empty
      end
    end

    it "lists exactly the non-null document fields" do
      with_db do |db|
        patch_settings(db, %({"assistant": {"model": "m"}, "mail": {"smtp": {"host": "smtp.example.test"}}}))
        Facet::SystemSettings.pinned(db).should eq(["assistant.model", "mail.smtp.host"])
      end
    end

    it "matches the document state after a sparse PATCH" do
      with_db do |db|
        patch_settings(db, %({"assistant": {"model": "patched-model"}}))
        Facet::SystemSettings.pinned(db).should eq(["assistant.model"])
        Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s).should eq("patched-model")
        # Untouched fields stay unpinned and keep following the file.
        Facet::SystemSettings.value_at(db, "mail.adapter")
          .try(&.as_s).should eq(Facet::Config.instance.mail.adapter)
      end
    end
  end

  describe "cache lifecycle" do
    it "serves stale-flag rebuilds without a fanout" do
      with_db do |db|
        patch_settings(db, %({"assistant": {"model": "cached-model"}}))
        Facet::SystemSettings.mark_stale
        Facet::SystemSettings.stale?.should be_true
        Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s).should eq("cached-model")
        Facet::SystemSettings.stale?.should be_false
      end
    end

    it "keeps serving the cache when fresh — a truncation alone does not change reads" do
      with_db do |db|
        patch_settings(db, %({"assistant": {"model": "warm-model"}}))
        Facet::SystemSettings.value_at(db, "assistant.model")

        # The row disappears but the cache is fresh: reads stay on the
        # cached values until an invalidation.
        db.exec("DELETE FROM projections WHERE domain = 'core' AND doc_type = 'SystemSettings'")
        Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s).should eq("warm-model")
      end
    end

    it "treats a missing document as follow-the-file after a rebuild" do
      with_db do |db|
        drop_settings(db)
        Facet::SystemSettings.value_at(db, "assistant.model")
          .try(&.as_s).should eq(Facet::Config.instance.assistant.model)
      end
    end
  end

  describe "uncached_string_at" do
    it "reads the document tier when pinned, bypassing a fresh cache" do
      with_db do |db|
        # Warm the cache, then change the row without invalidating it —
        # exactly what an out-of-band writer (a CLI command before its
        # flush, or any direct row edit) produces. The cached read stays
        # on the old value; the uncached read sees the row.
        patch_settings(db, %({"assistant": {"model": "stale-model"}}))
        Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s)
          .should eq("stale-model")

        db.exec(
          "UPDATE projections SET content = jsonb_set(content, '{assistant,model}', ('\"' || $1 || '\"')::jsonb) " \
          "WHERE domain = 'core' AND doc_type = 'SystemSettings' AND id = $2",
          "fresh-model", Facet::SystemSettings::DOC_ID,
        )
        Facet::SystemSettings.value_at(db, "assistant.model").try(&.as_s)
          .should eq("stale-model")
        Facet::SystemSettings.uncached_string_at(db, "assistant.model")
          .should eq("fresh-model")
      end
    end

    it "follows the file tier when the document does not pin the path" do
      with_db do |db|
        config = Facet::Config.instance
        Facet::SystemSettings.uncached_string_at(db, "iam.auth.mode")
          .should eq(config.iam.auth.mode)
        Facet::SystemSettings.uncached_string_at(db, "iam.mfa.enforcement")
          .should eq(config.iam.mfa.enforcement)
        # The type fallback translates `iam.mfa.totp.enabled` (true → totp).
        Facet::SystemSettings.uncached_string_at(db, "iam.mfa.type")
          .should eq(config.iam.mfa.totp.enabled? ? "totp" : "none")
      end
    end

    it "tolerates a missing document" do
      with_db do |db|
        drop_settings(db)
        Facet::SystemSettings.uncached_string_at(db, "iam.auth.mode")
          .should eq(Facet::Config.instance.iam.auth.mode)
      end
    end

    it "reads the document tier over a null leaf" do
      with_db do |db|
        # The seeded singleton pins nothing (every leaf null) — the file
        # tier fills, exactly like the cached chain.
        Facet::SystemSettings.uncached_string_at(db, "assistant.model")
          .should eq(Facet::Config.instance.assistant.model)
      end
    end

    it "raises on unknown and secret paths" do
      with_db do |db|
        expect_raises(ArgumentError, "Unknown system setting path") do
          Facet::SystemSettings.uncached_string_at(db, "assistant.wat")
        end
        expect_raises(ArgumentError, "is a secret") do
          Facet::SystemSettings.uncached_string_at(db, "assistant.api_key")
        end
      end
    end
  end

  describe "reveal_secret" do
    it "follows the file when no slot is pinned" do
      with_db do |db|
        # config.test.yml leaves assistant.api_key unset.
        Facet::SystemSettings.reveal_secret(db, "assistant.api_key").should be_nil
      end
    end

    it "raises on unknown and non-secret paths" do
      with_db do |db|
        expect_raises(ArgumentError) { Facet::SystemSettings.reveal_secret(db, "assistant.wat") }
        expect_raises(ArgumentError, "not a secret") do
          Facet::SystemSettings.reveal_secret(db, "assistant.model")
        end
      end
    end

    it "reveals a sealed slot after stage and adopt, without caching the value" do
      with_db do |db|
        handle = stage_secret(db, "assistant.api_key", "sk-spec-key")
        patch_settings(db, %({"assistant": {"api_key": "#{handle}"}}))

        Facet::SystemSettings.reveal_secret(db, "assistant.api_key").should eq("sk-spec-key")

        # The effective surface carries the pin, never the value.
        Facet::SystemSettings.pinned(db).should eq(["assistant.api_key"])
        Facet::SystemSettings.effective(db).has_key?("assistant.api_key").should be_false
      end
    end

    it "returns to the file value when the pin is cleared" do
      with_db do |db|
        handle = stage_secret(db, "assistant.api_key", "sk-rotate-me")
        patch_settings(db, %({"assistant": {"api_key": "#{handle}"}}))
        Facet::SystemSettings.reveal_secret(db, "assistant.api_key").should eq("sk-rotate-me")

        # Explicit null clears the slot; the file value (unset here) returns.
        patch_settings(db, %({"assistant": {"api_key": null}}))
        Facet::SystemSettings.reveal_secret(db, "assistant.api_key").should be_nil
        Facet::SystemSettings.pinned(db).should be_empty
      end
    end
  end
end
