# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/iam_helper"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/document"
require "../../src/secrets/staging"
require "../../src/secrets/codec"
require "../../src/util/script_helpers"

# Unit specs for the write-time semantic gate (`SystemSettings::WriteGate`).
# The definition owns shape; these cover every rule the definition cannot
# express — per-path kinds and bounds, and the mail adapter rules with
# escape-hatch parity.

private def errors_for(body : String) : Array(Facet::ValidationError)
  with_db do |db|
    Facet::SystemSettings::WriteGate.validate(JSON.parse(body), db)
  end
end

private def field_messages(errors : Array(Facet::ValidationError), field : String) : Array(String)
  errors.select { |e| e.field == field }.map(&.message)
end

# Builds a config whose mail section carries the production escape hatch,
# mirroring an air-gapped install (`mail.allow_dev_adapter_in_production`).
private def build_production_hatch_config : Facet::Config
  Facet::Config.from_yaml_node(YAML.parse(%(
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "spec-secret"
    event:
      url: "redis://localhost:6379/15"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
    mail:
      adapter: dev
      allow_dev_adapter_in_production: true
  )))
end

describe Facet::SystemSettings::WriteGate do
  describe "kind checks" do
    it "accepts every registered kind when unset — nulls follow the file" do
      errors_for(%({
        "assistant": {"model": null, "max_tokens": null, "temperature": null,
                      "auto_execute_tools": null, "system_prompt": null},
        "mail": {"adapter": null, "smtp": {"use_tls": null}}
      })).should be_empty
    end

    it "rejects a string where a number belongs" do
      errors = errors_for(%({"assistant": {"temperature": "hot"}}))
      errors.should_not be_empty
      errors.first.code.should eq("invalid_type")
    end

    it "rejects a boolean where a number belongs" do
      errors_for(%({"assistant": {"temperature": true}})).should_not be_empty
    end

    it "rejects a number where a string belongs" do
      errors_for(%({"mail": {"from_address": 42}})).should_not be_empty
    end

    it "rejects a string where a boolean belongs" do
      errors_for(%({"assistant": {"auto_execute_tools": "yes"}})).should_not be_empty
    end

    it "accepts integer and float forms on a number path" do
      errors_for(%({"assistant": {"temperature": 1, "max_tokens": 4096}})).should be_empty
      errors_for(%({"assistant": {"temperature": 0.5}})).should be_empty
    end

    it "skips secret paths — the adoption pipeline owns their shape" do
      errors_for(%({"assistant": {"api_key": "totally-not-a-handle"}})).should be_empty
    end
  end

  describe "bounds" do
    it "rejects a non-positive max_tokens" do
      errors_for(%({"assistant": {"max_tokens": 0}})).should_not be_empty
      errors_for(%({"assistant": {"max_tokens": -5}})).should_not be_empty
      errors_for(%({"assistant": {"max_tokens": 100}})).should be_empty
    end

    it "rejects a negative max_history but accepts zero" do
      errors_for(%({"assistant": {"max_history": -1}})).should_not be_empty
      errors_for(%({"assistant": {"max_history": 0}})).should be_empty
    end

    it "rejects a temperature outside 0.0..2.0" do
      errors = errors_for(%({"assistant": {"temperature": 2.5}}))
      field_messages(errors, "assistant.temperature").should_not be_empty

      errors_for(%({"assistant": {"temperature": 0.0}})).should be_empty
      errors_for(%({"assistant": {"temperature": 2.0}})).should be_empty
    end

    it "rejects a port outside 1..65535" do
      errors_for(%({"mail": {"smtp": {"port": 0}}})).should_not be_empty
      errors_for(%({"mail": {"smtp": {"port": 70000}}})).should_not be_empty
      errors_for(%({"mail": {"smtp": {"port": 587}}})).should be_empty
    end

    it "rejects non-positive artifact TTLs but lets the prune window be zero (keep forever)" do
      errors_for(%({"artifact": {"grant_ttl_seconds": 0}})).should_not be_empty
      errors_for(%({"artifact": {"grant_ttl_media_seconds": -1}})).should_not be_empty
      errors_for(%({"artifact": {"prune_after_days": 0}})).should be_empty
      errors_for(%({"artifact": {"prune_after_days": -1}})).should_not be_empty
      errors_for(%({
        "artifact": {"grant_ttl_seconds": 3600, "grant_ttl_media_seconds": 21600, "prune_after_days": 7}
      })).should be_empty
    end

    it "lets the retention windows be zero (keep forever) but rejects negatives" do
      errors_for(%({"mutations": {"retention_days": 0}, "tombstone": {"content_retention_days": 0}}))
        .should be_empty
      errors_for(%({"mutations": {"retention_days": -1}})).should_not be_empty
      errors_for(%({"tombstone": {"content_retention_days": -5}})).should_not be_empty
      errors_for(%({"mutations": {"retention_days": 90}, "tombstone": {"content_retention_days": 14}}))
        .should be_empty
    end
  end

  describe "assistant name rules" do
    it "accepts a normal name" do
      errors_for(%({"assistant": {"name": "Jeeves"}})).should be_empty
    end

    it "refuses a blank name — whitespace only counts as blank" do
      errors = errors_for(%({"assistant": {"name": "   "}}))
      field_messages(errors, "assistant.name").should_not be_empty
    end

    it "refuses a name over the 40-character chrome bound" do
      long_name = "a" * 41
      errors = errors_for(%({"assistant": {"name": "#{long_name}"}}))
      field_messages(errors, "assistant.name").should_not be_empty

      errors_for(%({"assistant": {"name": "#{"a" * 40}"}})).should be_empty
    end
  end

  describe "mail adapter rules" do
    it "requires a host in the merged state when the adapter is smtp" do
      errors = errors_for(%({"mail": {"adapter": "smtp"}}))
      field_messages(errors, "mail.smtp.host").should_not be_empty
    end

    it "accepts an smtp switch when the merged state carries a host" do
      errors_for(%({"mail": {"adapter": "smtp", "smtp": {"host": "smtp.example.test"}}})).should be_empty
    end

    it "keeps a previously pinned host through a patch that only switches the adapter" do
      # The deep merge is the caller's job (Document::Update); the gate sees
      # the merged state — here the host survives from the existing content.
      errors_for(%({"mail": {"adapter": "smtp", "smtp": {"host": "kept-host"}}})).should be_empty
    end

    it "rejects an empty host as missing" do
      errors = errors_for(%({"mail": {"adapter": "smtp", "smtp": {"host": ""}}}))
      field_messages(errors, "mail.smtp.host").should_not be_empty
    end

    it "ignores the rule when the adapter stays null (follows the file)" do
      errors_for(%({"mail": {"smtp": {"host": null}}})).should be_empty
    end

    it "allows the dev adapter outside production" do
      errors_for(%({"mail": {"adapter": "dev"}})).should be_empty
    end
  end

  describe "artifact deployment rules" do
    it "refuses any pinned artifact.storage.type — the adapter wires at boot" do
      errors = errors_for(%({"artifact": {"storage": {"type": "s3"}}}))
      field_messages(errors, "artifact.storage.type").should_not be_empty
    end

    it "accepts a null storage type — the document never pins it" do
      errors_for(%({"artifact": {"storage": {"type": null}}})).should be_empty
    end

    it "names the config-file remedy for the intermediate artifact.storage node (F09-05)" do
      # The definition declares only `artifact.storage.type`; a PATCH on the
      # intermediate node fails shape validation first. `refusal` carries the
      # gate's sentence for it, and `Document::Update` swaps it in.
      error = Facet::SystemSettings::WriteGate.refusal("artifact.storage")
      error.should_not be_nil
      error.not_nil!.field.should eq("artifact.storage")
      error.not_nil!.code.should eq("invalid_format")
      error.not_nil!.message.should contain("Change artifact.storage in the config file and restart")

      Facet::SystemSettings::WriteGate.refusal("artifact.storage.type").should_not be_nil
      Facet::SystemSettings::WriteGate.refusal("assistant.model").should be_nil
    end
  end

  describe "localization rules" do
    it "accepts a loadable IANA timezone and an allowlisted language" do
      errors_for(%({"localization": {"default_timezone": "Europe/Paris", "default_language": "en"}}))
        .should be_empty
    end

    it "refuses a timezone the runtime cannot load" do
      errors = errors_for(%({"localization": {"default_timezone": "Bogus/Nowhere"}}))
      field_messages(errors, "localization.default_timezone").should_not be_empty
    end

    it "refuses a language outside the allowlist" do
      errors = errors_for(%({"localization": {"default_language": "xx"}}))
      field_messages(errors, "localization.default_language").should_not be_empty
    end

    it "ignores unset values (follow the file)" do
      errors_for(%({"localization": {"default_timezone": null, "default_language": null}})).should be_empty
    end
  end

  describe "iam policy rules" do
    it "accepts the enum values" do
      errors_for(%({
        "iam": {
          "mfa": {"type": "totp", "enforcement": "always"},
          "auth": {"mode": "hybrid"}
        }
      })).should be_empty
      errors_for(%({
        "iam": {
          "mfa": {"type": "none", "enforcement": "preferred"},
          "auth": {"mode": "hybrid"}
        }
      })).should be_empty
    end

    it "refuses a factor type outside none/totp" do
      errors = errors_for(%({"iam": {"mfa": {"type": "sms"}}}))
      field_messages(errors, "iam.mfa.type").should_not be_empty
    end

    it "refuses an enforcement outside preferred/always" do
      errors = errors_for(%({"iam": {"mfa": {"enforcement": "sometimes"}}}))
      field_messages(errors, "iam.mfa.enforcement").should_not be_empty
    end

    it "refuses an auth mode outside hybrid/oidc_only" do
      errors = errors_for(%({"iam": {"auth": {"mode": "passwords_only"}}}))
      field_messages(errors, "iam.auth.mode").should_not be_empty
    end

    it "refuses oidc_only with zero enabled providers" do
      errors = errors_for(%({"iam": {"auth": {"mode": "oidc_only"}}}))
      field_messages(errors, "iam.auth.mode").should_not be_empty
    end

    it "accepts oidc_only when one enabled provider document exists" do
      with_db do |db|
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "OIDCProvider")
        handle = "sh_" + Facet::Util::ScriptHelpers.ulid
        payload = Facet::Secrets::Codec.seal("write-gate-secret",
          Facet::Secrets::Staging.doc_ref(handle), "client_secret")
        Facet::Secrets::Staging.insert(db, "sealed", payload, "iam", "OIDCProvider",
          "client_secret", "system", handle: handle)
        created = Facet::Document::Create.call(db, "iam", "OIDCProvider",
          %({"name": "solo", "issuer": "https://idp.example.test", "client_id": "cid",
             "client_secret": "#{handle}", "default_role": null}),
          Facet::RBAC::AuthContext.system)
        raise "provider seed failed: #{created.inspect}" if created.is_a?(Facet::ServiceError)

        Facet::SystemSettings::WriteGate.validate(
          JSON.parse(%({"iam": {"auth": {"mode": "oidc_only"}}})), db).should be_empty
      end
    end
  end

  describe "iam.oidc.provision_roles" do
    it "accepts an unset value and an empty list" do
      errors_for(%({"iam": {"oidc": {"provision_roles": null}}})).should be_empty
      errors_for(%({"iam": {"oidc": {"provision_roles": []}}})).should be_empty
    end

    it "accepts a list of live role references" do
      with_db do |db|
        seed_test_roles(db)
        errors_for(%({"iam": {"oidc": {"provision_roles": ["iam.Roles.editor", "iam.Roles.viewer"]}}}))
          .should be_empty
      end
    end

    it "rejects a non-array and a non-string entry" do
      errors = errors_for(%({"iam": {"oidc": {"provision_roles": "iam.Roles.admin"}}}))
      errors.first.code.should eq("invalid_type")
      errors_for(%({"iam": {"oidc": {"provision_roles": ["iam.Roles.admin", 42]}}}))
        .should_not be_empty
    end

    it "refuses an entry that names no live iam.Roles document" do
      with_db do |db|
        seed_test_roles(db)
        errors = errors_for(%({"iam": {"oidc": {"provision_roles": ["iam.Roles.employee"]}}}))
        messages = field_messages(errors, "iam.oidc.provision_roles")
        messages.should_not be_empty
        messages.first.should contain("iam.Roles.employee")
      end
    end

    it "refuses a duplicated role" do
      with_db do |db|
        seed_test_roles(db)
        errors = errors_for(%({"iam": {"oidc": {"provision_roles": ["iam.Roles.editor", "iam.Roles.editor"]}}}))
        field_messages(errors, "iam.oidc.provision_roles").should_not be_empty
      end
    end
  end

  describe "production dev-adapter gate" do
    it "refuses a dev switch under APP_ENV=production unless the file hatch is set" do
      previous = ENV["APP_ENV"]?
      ENV["APP_ENV"] = "production"
      begin
        errors = errors_for(%({"mail": {"adapter": "dev"}}))
        field_messages(errors, "mail.adapter").should_not be_empty
      ensure
        if previous
          ENV["APP_ENV"] = previous
        else
          ENV.delete("APP_ENV")
        end
      end
    end

    it "honors the file escape hatch with the same parity as the loader" do
      previous = ENV["APP_ENV"]?
      ENV["APP_ENV"] = "production"
      config = Facet::Config.instance
      begin
        # Swap in a config whose file sets the air-gapped hatch.
        Facet::Config.instance = build_production_hatch_config
        errors_for(%({"mail": {"adapter": "dev"}})).should be_empty
      ensure
        Facet::Config.instance = config
        if previous
          ENV["APP_ENV"] = previous
        else
          ENV.delete("APP_ENV")
        end
      end
    end
  end
end
