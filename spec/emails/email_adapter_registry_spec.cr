# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/emails/email_adapter_registry"

describe Facet::EmailAdapterRegistry do
  describe ".build" do
    it "returns a DevAdapter when name is 'dev'" do
      mail = Facet::Config::MailConfig.new

      adapter = Facet::EmailAdapterRegistry.build("dev", mail)
      adapter.should_not be_nil
      adapter.should be_a(Carbon::DevAdapter)
    end

    it "returns an SmtpAdapter when name is 'smtp'" do
      mail = Facet::Config::MailConfig.new(
        smtp: Facet::Config::SMTPConfig.new(
          host: "smtp.example.test", port: 587,
          username: "u", password: "p", use_tls: true,
        )
      )

      adapter = Facet::EmailAdapterRegistry.build("smtp", mail)
      adapter.should_not be_nil
      adapter.should be_a(Carbon::SmtpAdapter)
    end

    it "returns nil for an unregistered adapter name" do
      mail = Facet::Config::MailConfig.new

      adapter = Facet::EmailAdapterRegistry.build("sendgrid", mail)
      adapter.should be_nil
    end
  end

  describe ".registered?" do
    it "returns true for in-box adapter names" do
      Facet::EmailAdapterRegistry.registered?("dev").should be_true
      Facet::EmailAdapterRegistry.registered?("smtp").should be_true
    end

    it "returns false for unknown adapter names" do
      Facet::EmailAdapterRegistry.registered?("ses").should be_false
    end

    it "returns true after registering a custom adapter" do
      counter = 0
      Facet::EmailAdapterRegistry.register("__test_counter") do |_mail|
        counter += 1
        Carbon::DevAdapter.new(print_emails: false)
      end

      Facet::EmailAdapterRegistry.registered?("__test_counter").should be_true

      # Build via the registry — the custom builder should be invoked.
      adapter = Facet::EmailAdapterRegistry.build("__test_counter", Facet::Config::MailConfig.new)
      counter.should eq(1)
      adapter.should be_a(Carbon::DevAdapter)
    end
  end

  describe ".names" do
    it "includes at least the in-box adapters" do
      names = Facet::EmailAdapterRegistry.names
      names.should contain("dev")
      names.should contain("smtp")
    end
  end
end
