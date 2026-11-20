# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/system_settings"
require "../../src/emails/test_email"
require "../../src/doctype/seed"
require "../support/http_helper"
require "../support/iam_helper"
require "../../src/http/server"
require "json"

# The mail probe. Two layers are covered:
#
# - `Facet::SystemSettings::MailTest` directly — the resolution (saved
#   adapter, From header), the Facet-side rejections, and the `502` mapping
#   for a transport failure. The `deliver` seam replaces the send, so no
#   SMTP server is involved.
# - The HTTP route — the write gate, the CSRF check, and the JSON shapes.
#
# The saved adapter stays `smtp` throughout: the doctype enum admits only
# `dev` and `smtp`, and the seam replaces the transport regardless.

HTTPTest.init

private def role_context(db, role_id : String, account_id : String = "acct_" + Facet::Util::ScriptHelpers.ulid[0..10]) : Facet::RBAC::AuthContext
  content = Facet::IAM::RoleStore.fetch(db, role_id)
  raise "seeded role #{role_id} missing" if content.nil?
  role = Facet::RBAC::ActiveRole.from_projection_content(content.as(JSON::Any))
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

private def pin_mail(db, patch : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch, Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale
  Facet::BaseEmail.reset_configuration!
end

private def smtp_saved_patch : String
  %({"mail": {"adapter": "smtp", "from_address": "probe@example.test", "smtp": {"host": "smtp.example.test"}}})
end

private def mail_test_request(body : String) : HTTP::Request
  HTTP::Request.new(
    "POST", "/Api/SystemSettings/mail/test",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
    body: body,
  )
end

describe Facet::SystemSettings::MailTest do
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

  it "delivers through the saved adapter and reports the transport details" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)

      captured = [] of Facet::TestEmail
      result = Facet::SystemSettings::MailTest.call(db, "operator@example.test", ->(email : Facet::TestEmail) {
        captured << email
        nil
      })

      result = result.as(Facet::SystemSettings::MailTest::Result)
      result.adapter.should eq("smtp")
      result.from_address.should eq("probe@example.test")
      result.to.should eq("operator@example.test")

      captured.size.should eq(1)
      email = captured.first
      email.to.first.address.should eq("operator@example.test")
      email.from.address.should eq("probe@example.test")
      email.text_body.should contain("test email from Facet")
      email.text_body.should contain("smtp")
    end
  end

  it "answers 422 with the adapter field when the connector is 'dev'" do
    with_db do |db|
      pin_mail(db, %({"mail": {"adapter": "dev"}}))

      result = Facet::SystemSettings::MailTest.call(db, "operator@example.test", ->(_email : Facet::TestEmail) { nil })

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.details.not_nil!.any? { |d| d.field == "mail.adapter" }.should be_true
    end
  end

  it "answers 422 with the 'to' field for a malformed address" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)

      result = Facet::SystemSettings::MailTest.call(db, "not-an-address", ->(_email : Facet::TestEmail) { nil })

      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.details.not_nil!.any? { |d| d.field == "to" }.should be_true
    end
  end

  it "answers 502 carrying the transport message when the send fails" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)

      result = Facet::SystemSettings::MailTest.call(db, "operator@example.test", ->(_email : Facet::TestEmail) {
        raise "535 authentication failed"
      })

      error = result.as(Facet::ServiceError)
      error.status.should eq(502)
      error.message.should contain("535 authentication failed")
    end
  end
end

describe "POST /Api/SystemSettings/mail/test" do
  before_each do
    Facet::SystemSettings.reset_cache!
    Facet::BaseEmail.reset_configuration!
    with_db do |db|
      %w[core.DocType core.Domain core.SystemSettings].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
      seed_test_roles(db)
    end
  end

  after_each do
    Facet::SystemSettings.reset_cache!
    Facet::BaseEmail.reset_configuration!
  end

  it "answers 403 for editor and viewer (the settings write gate)" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)
      request = mail_test_request(%({"to": "operator@example.test"}))

      assert_http_status(call_api_as(request, role_context(db, "iam.Roles.editor")), 403)
      assert_http_status(call_api_as(request, role_context(db, "iam.Roles.viewer")), 403)
    end
  end

  it "answers 422 when the connector is 'dev' (no delivery)" do
    with_db do |db|
      pin_mail(db, %({"mail": {"adapter": "dev"}}))
      admin = role_context(db, "iam.Roles.admin")

      response = call_api_as(mail_test_request(%({"to": "operator@example.test"})), admin)

      assert_http_status(response, 422)
      details = JSON.parse(response.body)["details"].as_a
      details.any? { |d| d["field"].as_s == "mail.adapter" }.should be_true
    end
  end

  it "answers 422 for a malformed recipient" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)
      admin = role_context(db, "iam.Roles.admin")

      response = call_api_as(mail_test_request(%({"to": "not-an-address"})), admin)

      assert_http_status(response, 422)
      details = JSON.parse(response.body)["details"].as_a
      details.any? { |d| d["field"].as_s == "to" }.should be_true
    end
  end

  it "answers 422 when 'to' is missing or the body is absent" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)
      admin = role_context(db, "iam.Roles.admin")

      assert_http_status(call_api_as(mail_test_request(%({"other": 1})), admin), 422)
      assert_http_status(call_api_as(mail_test_request(""), admin), 422)
    end
  end

  it "answers 403 without the CSRF header" do
    with_db do |db|
      pin_mail(db, smtp_saved_patch)
      admin = role_context(db, "iam.Roles.admin")
      request = mail_test_request(%({"to": "operator@example.test"}))

      assert_http_status(call_api_raw_as(request, admin), 403)
    end
  end
end
