# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/system_settings"

# Unit specs for the `Facet::SystemSettings` registry: the registered path
# set, kinds, consumer tags, secret flags, and the file-side fallback
# readers.
describe Facet::SystemSettings do
  describe "SPEC registry" do
    it "registers exactly the phase-1 tier paths plus the localization and policy paths" do
      paths = Facet::SystemSettings::SPEC.keys
      paths.sort!.should eq([
        "artifact.grant_ttl_media_seconds",
        "artifact.grant_ttl_seconds",
        "artifact.prune_after_days",
        "artifact.storage.type",
        "assistant.api_endpoint",
        "assistant.api_key",
        "assistant.auto_execute_tools",
        "assistant.max_history",
        "assistant.max_tokens",
        "assistant.model",
        "assistant.name",
        "assistant.system_prompt",
        "assistant.temperature",
        "iam.auth.mode",
        "iam.change_password_expiration",
        "iam.mfa.enforcement",
        "iam.mfa.type",
        "iam.oidc.provision_roles",
        "localization.default_language",
        "localization.default_timezone",
        "mail.adapter",
        "mail.from_address",
        "mail.from_name",
        "mail.smtp.host",
        "mail.smtp.password",
        "mail.smtp.port",
        "mail.smtp.use_tls",
        "mail.smtp.username",
        "mutations.retention_days",
        "tombstone.content_retention_days",
      ])
    end

    it "declares the two secret paths" do
      spec = Facet::SystemSettings::SPEC
      spec["assistant.api_key"].secret?.should be_true
      spec["mail.smtp.password"].secret?.should be_true
      spec.values.count(&.secret?).should eq(2)
    end

    it "keys every entry by its own path" do
      Facet::SystemSettings::SPEC.each do |path, entry|
        entry.path.should eq(path)
      end
    end

    it "carries this module's Kind enum, not the account-settings one" do
      spec = Facet::SystemSettings::SPEC
      Facet::SystemSettings::Kind.names.sort.should eq(["Bool", "Number", "Secret", "String", "StringList", "Text"])
      spec["assistant.system_prompt"].kind.should eq(Facet::SystemSettings::Kind::Text)
      spec["assistant.name"].kind.should eq(Facet::SystemSettings::Kind::String)
      spec["assistant.max_tokens"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["assistant.auto_execute_tools"].kind.should eq(Facet::SystemSettings::Kind::Bool)
      spec["mail.adapter"].kind.should eq(Facet::SystemSettings::Kind::String)
      spec["artifact.grant_ttl_seconds"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["iam.change_password_expiration"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["artifact.grant_ttl_media_seconds"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["artifact.prune_after_days"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["artifact.storage.type"].kind.should eq(Facet::SystemSettings::Kind::String)
      spec["mutations.retention_days"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["tombstone.content_retention_days"].kind.should eq(Facet::SystemSettings::Kind::Number)
      spec["iam.oidc.provision_roles"].kind.should eq(Facet::SystemSettings::Kind::StringList)
    end
  end

  describe "fallback readers" do
    it "read the file side at the same path" do
      config = Facet::Config.instance
      spec = Facet::SystemSettings::SPEC

      spec["assistant.api_endpoint"].fallback.call(config)
        .try(&.as_s).should eq(config.assistant.api_endpoint)
      spec["assistant.name"].fallback.call(config)
        .try(&.as_s).should eq(config.assistant.name)
      spec["assistant.model"].fallback.call(config)
        .try(&.as_s).should eq(config.assistant.model)
      spec["mail.adapter"].fallback.call(config)
        .try(&.as_s).should eq(config.mail.adapter)
      spec["mail.smtp.port"].fallback.call(config)
        .try(&.as_i64).should eq(config.mail.smtp.port.to_i64)
      spec["mail.smtp.use_tls"].fallback.call(config)
        .try(&.as_bool).should eq(config.mail.smtp.use_tls)
      spec["artifact.grant_ttl_seconds"].fallback.call(config)
        .try(&.as_i64).should eq(config.artifact.grant_ttl_seconds.to_i64)
      spec["artifact.grant_ttl_media_seconds"].fallback.call(config)
        .try(&.as_i64).should eq(config.artifact.grant_ttl_media_seconds.to_i64)
      spec["artifact.prune_after_days"].fallback.call(config)
        .try(&.as_i64).should eq(config.artifact.prune_after_days.to_i64)
      spec["artifact.storage.type"].fallback.call(config)
        .try(&.as_s).should eq(config.artifact.storage.type)
      spec["mutations.retention_days"].fallback.call(config)
        .try(&.as_i64).should eq(config.mutations.retention_days.to_i64)
      spec["tombstone.content_retention_days"].fallback.call(config)
        .try(&.as_i64).should eq(config.tombstone.content_retention_days.to_i64)
      spec["localization.default_timezone"].fallback.call(config)
        .try(&.as_s).should eq(config.localization.default_timezone)
      spec["localization.default_language"].fallback.call(config)
        .try(&.as_s).should eq(config.localization.default_language)
      spec["iam.mfa.enforcement"].fallback.call(config)
        .try(&.as_s).should eq(config.iam.mfa.enforcement)
      spec["iam.auth.mode"].fallback.call(config)
        .try(&.as_s).should eq(config.iam.auth.mode)
      spec["iam.change_password_expiration"].fallback.call(config)
        .try(&.as_i64).should eq(config.iam.change_password_expiration.to_i64)
      spec["iam.oidc.provision_roles"].fallback.call(config)
        .try(&.as_a.map(&.as_s)).should eq(config.iam.oidc.provision_roles)
    end

    it "translates the file's totp.enabled boolean into the iam.mfa.type grammar" do
      # The one fallback that reads a *different* path than its own (the
      # Spec doc comment records the exception): true → totp, false → none.
      spec = Facet::SystemSettings::SPEC
      config = Facet::Config.instance
      expected = config.iam.mfa.totp.enabled? ? "totp" : "none"
      spec["iam.mfa.type"].fallback.call(config).try(&.as_s).should eq(expected)
    end

    it "return null for nullable file keys" do
      # config.test.yml leaves these unset — the built-in default is null.
      spec = Facet::SystemSettings::SPEC
      spec["assistant.max_tokens"].fallback
        .call(Facet::Config.instance).try(&.raw).should be_nil
      spec["mail.smtp.username"].fallback
        .call(Facet::Config.instance).try(&.raw).should be_nil
    end

    it "never raise for secret paths — the file value may be absent" do
      Facet::SystemSettings::SPEC["assistant.api_key"].fallback
        .call(Facet::Config.instance).try(&.raw).should be_nil
    end
  end
end
