# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Stage-2 hot-change specs for the mail connector: `BaseEmail` reads the
# effective mail view (`SystemSettings::MailView`), and a settings save
# reaches the adapter and the `from` header before the next send — the
# `SystemSettingsCache` subscriber re-arms the memo flag, and `configure!`
# checks the settings-cache generation so a lost fanout self-heals.
require "../../src/emails/base_email"
require "../../src/system_settings"
require "../../src/doctype/seed"

# A concrete probe on the real base class: the abstract Carbon surface
# (`subject` / `to`) exists only to satisfy the compiler — `from` and
# `before_send` are the inherited `Facet::BaseEmail` implementations under
# test.
private class SpecProbeEmail < Facet::BaseEmail
  def subject : String
    "probe"
  end

  def to : Array(Carbon::Address)
    [Carbon::Address.new("Spec", "to@example.test")]
  end
end

# Pins one mail settings patch on the singleton (the same save an admin
# makes through the document route).
private def pin_mail(db, patch : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

describe "Mail hot settings" do
  before_each do
    Facet::SystemSettings.reset_cache!
    Facet::BaseEmail.reset_configuration!
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
    Facet::BaseEmail.reset_configuration!
  end

  it "follows the file when no mail key is pinned" do
    with_db do |db|
      file = Facet::Config.instance.mail
      view = Facet::SystemSettings::MailView.build(db)
      view.adapter.should eq(file.adapter)
      view.from_address.should eq(file.from_address)
      view.from_name.should eq(file.from_name)
      view.smtp.host.should eq(file.smtp.host)
      view.smtp.use_tls.should eq(file.smtp.use_tls)
      view.smtp.password.should eq(file.smtp.password)
    end
  end

  it "rebuilds the adapter from the effective view after a settings change" do
    with_db do |db|
      # First send path: dev adapter (the file default in tests).
      SpecProbeEmail.new.before_send
      Facet::BaseEmail.settings.adapter.should be_a(Carbon::DevAdapter)

      # The admin switches the adapter to smtp with a host — a normal save.
      pin_mail(db, %({"mail": {"adapter": "smtp", "smtp": {"host": "smtp.example.test", "port": 2525}}}))

      # The subscriber's hook already ran (reset_configuration!) — the next
      # send rebuilds from the settings, no restart.
      SpecProbeEmail.new.before_send
      Facet::BaseEmail.settings.adapter.should be_a(Carbon::SmtpAdapter)
      Carbon::SmtpAdapter.settings.host.should eq("smtp.example.test")
      Carbon::SmtpAdapter.settings.port.should eq(2525)
    end
  end

  it "uses the new from header after a settings change" do
    with_db do |db|
      pin_mail(db, %({"mail": {"from_address": "platform@example.test", "from_name": "Platform"}}))

      from = SpecProbeEmail.new.from
      from.address.should eq("platform@example.test")
      from.name.should eq("Platform")
    end
  end

  it "resolves the smtp password through the secret store" do
    with_db do |db|
      handle = "sh_" + Facet::Util::ScriptHelpers.ulid
      payload = Facet::Secrets::Codec.seal("smtp-secret", Facet::Secrets::Staging.doc_ref(handle), "mail.smtp.password")
      Facet::Secrets::Staging.insert(db, "sealed", payload, "core", "SystemSettings", "mail.smtp.password", "system", handle: handle)
      pin_mail(db, %({"mail": {"smtp": {"password": "#{handle}"}}}))

      view = Facet::SystemSettings::MailView.build(db)
      view.smtp.password.should eq("smtp-secret")
    end
  end
end
