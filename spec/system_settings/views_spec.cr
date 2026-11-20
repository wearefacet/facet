# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Consumer-view specs: the `MailView` / `AssistantView` shapes the mail and
# assistant read sites consume. The critical case is a document-pinned
# `false`: the effective cache carries it (resolution_spec pins that), and
# these specs pin that the VIEWS deliver it — a Bool resolved with
# `false || file_value` would silently swap in the file default (both file
# bools default `true`).
require "../../src/system_settings"
require "../../src/doctype/seed"

# Pins one patch on the settings singleton (the same save an admin makes
# through the document route) and invalidates the cache — no Redis fanout
# runs in the unit suite.
private def pin_setting(db, patch : String) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
end

describe Facet::SystemSettings::MailView do
  before_each do
    Facet::SystemSettings.reset_cache!
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "delivers a pinned false use_tls instead of the file default" do
    with_db do |db|
      pin_setting(db, %({"mail": {"smtp": {"use_tls": false}}}))
      view = Facet::SystemSettings::MailView.build(db)
      view.smtp.use_tls.should be_false
    end
  end

  it "delivers a pinned true use_tls" do
    with_db do |db|
      pin_setting(db, %({"mail": {"smtp": {"use_tls": true}}}))
      Facet::SystemSettings::MailView.build(db).smtp.use_tls.should be_true
    end
  end

  it "follows the file when use_tls is not pinned" do
    with_db do |db|
      Facet::SystemSettings::MailView.build(db).smtp.use_tls
        .should eq(Facet::Config.instance.mail.smtp.use_tls)
    end
  end

  it "delivers pinned strings and numbers alongside" do
    with_db do |db|
      pin_setting(db, %({"mail": {"adapter": "smtp", "smtp": {"host": "smtp.example.test", "port": 465}}}))
      view = Facet::SystemSettings::MailView.build(db)
      view.adapter.should eq("smtp")
      view.smtp.host.should eq("smtp.example.test")
      view.smtp.port.should eq(465)
    end
  end
end

describe Facet::SystemSettings::AssistantView do
  before_each do
    Facet::SystemSettings.reset_cache!
  end

  after_each do
    Facet::SystemSettings.reset_cache!
  end

  it "delivers a pinned false auto_execute_tools instead of the file default" do
    with_db do |db|
      pin_setting(db, %({"assistant": {"auto_execute_tools": false}}))
      view = Facet::SystemSettings::AssistantView.build(db, nil)
      view.auto_execute_tools?.should be_false
    end
  end

  it "delivers a pinned true auto_execute_tools" do
    with_db do |db|
      pin_setting(db, %({"assistant": {"auto_execute_tools": true}}))
      Facet::SystemSettings::AssistantView.build(db, nil).auto_execute_tools?.should be_true
    end
  end

  it "follows the file when auto_execute_tools is not pinned" do
    with_db do |db|
      Facet::SystemSettings::AssistantView.build(db, nil).auto_execute_tools?
        .should eq(Facet::Config.instance.assistant.auto_execute_tools?)
    end
  end

  it "delivers a pinned name and falls back to the file value" do
    with_db do |db|
      pin_setting(db, %({"assistant": {"name": "Jeeves"}}))
      Facet::SystemSettings::AssistantView.build(db, nil).name.should eq("Jeeves")
      Facet::SystemSettings::AssistantView.display_name(db).should eq("Jeeves")

      Facet::Document::Update.call(
        db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
        %({"assistant": {"name": null}}),
        Facet::RBAC::AuthContext.system,
      )
      Facet::SystemSettings.mark_stale
      Facet::SystemSettings::AssistantView.display_name(db)
        .should eq(Facet::Config.instance.assistant.name)
    end
  end
end
