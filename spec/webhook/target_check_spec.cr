# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/webhook_helper"

# Unit specs for the B-76 target gate. The URL-level examples ride IP
# literals (no DNS) and one RFC 2606 name that can never resolve, so the
# file passes in any environment; the address-classification examples are
# pure (no resolution at all).
# The address classifier through the public gate: every resolved-form
# family the deny-list covers, as literals (no DNS anywhere).
def target_rejected?(url : String) : Bool
  with_webhook_config_raw([] of String, Facet::Config::WebhookConfig.new(allow_insecure_urls: true)) do
    Facet::Webhook::TargetCheck.check(url) == Facet::Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE
  end
end

module Facet
  describe Webhook::TargetCheck do
    describe ".check" do
      it "passes a public IP-literal https target" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
          Webhook::TargetCheck.check("https://1.1.1.1/hook").should be_nil
        end
      end

      it "passes a public IPv6-literal target" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
          # 2606:4700:4700::1111 — a public Cloudflare resolver address.
          Webhook::TargetCheck.check("https://[2606:4700:4700::1111]/hook").should be_nil
        end
      end

      it "rejects a non-https target with the B-77 message" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
          Webhook::TargetCheck.check("http://1.1.1.1/hook")
            .should eq(Webhook::TargetCheck::INSECURE_TARGET_MESSAGE)
        end
      end

      it "skips the scheme check when allow_insecure_urls is on" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://1.1.1.1/hook").should be_nil
        end
      end

      it "rejects a URL without a host" do
        Webhook::TargetCheck.check("https:///hook").should eq(Webhook::TargetCheck::INVALID_TARGET_MESSAGE)
      end

      it "rejects a non-http(s) scheme" do
        Webhook::TargetCheck.check("ftp://1.1.1.1/hook").should eq(Webhook::TargetCheck::INVALID_TARGET_MESSAGE)
      end

      it "rejects a URL with no host after the scheme" do
        Webhook::TargetCheck.check("https://").should eq(Webhook::TargetCheck::INVALID_TARGET_MESSAGE)
      end

      it "rejects an out-of-range port via the dial-time socket error class" do
        # URI.parse accepts a huge port; the gate must not crash on it —
        # it classifies by host, and the host here is public.
        with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
          Webhook::TargetCheck.check("https://1.1.1.1:99999999/hook").should be_nil
        end
      end

      it "rejects the run-27 loopback literal with the private message" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://127.0.0.1:9/hook")
            .should eq(Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE)
        end
      end

      it "rejects the run-27 metadata literal" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
          Webhook::TargetCheck.check("https://169.254.169.254/latest/meta-data/")
            .should eq(Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE)
        end
      end

      it "rejects an unresolvable host with the unresolved message" do
        with_fake_resolver do
          with_webhook_config_raw([] of String, Config::WebhookConfig.new) do
            Webhook::TargetCheck.check("https://b76-does-not-resolve.invalid/hook")
              .should eq(Webhook::TargetCheck::UNRESOLVED_TARGET_MESSAGE)
          end
        end
      end

      it "passes a private target named on the allowlist (hostname entry)" do
        with_webhook_config_raw(["127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://127.0.0.1:9/hook").should be_nil
        end
      end

      it "passes a private target whose resolved address matches an allowlist CIDR" do
        with_webhook_config_raw(["127.0.0.0/8"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://127.0.0.1:9/hook").should be_nil
        end
      end

      it "rejects a private target when the allowlist names a different host" do
        with_webhook_config_raw(["10.0.0.0/8"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://127.0.0.1:9/hook")
            .should eq(Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE)
        end
      end
    end

    describe ".allowed_hosts IP-literal entries" do
      it "matches a bare IPv4 entry against a host that resolves to it (B-84)" do
        with_fake_resolver({"localhost" => ["127.0.0.1"]}) do
          with_webhook_config_raw(["127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
            Webhook::TargetCheck.check("http://localhost:8099/sink").should be_nil
          end
        end
      end

      it "treats a bare IPv4 entry and its ::ffff: spelling as one address" do
        with_fake_resolver({"localhost" => ["127.0.0.1"]}) do
          with_webhook_config_raw(["::ffff:127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
            Webhook::TargetCheck.check("http://localhost/sink").should be_nil
          end
        end
        with_webhook_config_raw(["127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://[::ffff:127.0.0.1]/sink").should be_nil
        end
      end

      it "still passes the literal host text without DNS" do
        with_webhook_config_raw(["127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://127.0.0.1:9/sink").should be_nil
        end
      end

      it "does not widen: the entry passes only hosts that resolve to it" do
        with_webhook_config_raw(["127.0.0.1"], Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.check("http://169.254.169.254/sink")
            .should eq(Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE)
          Webhook::TargetCheck.check("http://10.1.2.3/sink")
            .should eq(Webhook::TargetCheck::PRIVATE_TARGET_MESSAGE)
        end
      end
    end

    describe ".host_safe?" do
      it "judges only the host — a rejected host answers false regardless of scheme flag" do
        with_webhook_config_raw([] of String, Config::WebhookConfig.new(allow_insecure_urls: true)) do
          Webhook::TargetCheck.host_safe?("http://127.0.0.1:9/hook").should be_false
          Webhook::TargetCheck.host_safe?("http://[::ffff:127.0.0.1]/hook").should be_false
          Webhook::TargetCheck.host_safe?("https://1.1.1.1/hook").should be_true
        end
      end

      it "answers false for a URL without a host" do
        Webhook::TargetCheck.host_safe?("https:///hook").should be_false
      end
    end

    # The address classifier through the public gate: every resolved-form
    # family the deny-list covers, as literals (no DNS anywhere).
    describe "address classification (via .check with allow_insecure_urls)" do
      it "denies every deny-listed IPv4 family" do
        [
          "http://127.0.0.1/hook",                    # loopback
          "http://127.254.9.9/hook",                  # loopback /8 edge
          "http://10.1.2.3/hook",                     # RFC 1918
          "http://172.16.0.1/hook",                   # RFC 1918
          "http://172.31.255.255/hook",               # RFC 1918 top edge
          "http://192.168.1.1/hook",                  # RFC 1918
          "http://169.254.169.254/latest/meta-data/", # link-local / metadata
          "http://100.64.1.1/hook",                   # carrier NAT
          "http://0.0.0.0/hook",                      # unspecified
          "http://224.0.0.1/hook",                    # multicast
          "http://240.0.0.1/hook",                    # reserved
          "http://255.255.255.255/hook",              # broadcast
          "http://192.0.2.1/hook",                    # TEST-NET-1
          "http://198.18.0.1/hook",                   # benchmarking
        ].each do |url|
          target_rejected?(url).should be_true, "expected denied: #{url}"
        end
      end

      it "denies IPv4-mapped IPv6 spellings of private targets" do
        [
          "http://[::ffff:127.0.0.1]/hook",
          "http://[::ffff:10.0.0.1]/hook",
          "http://[::ffff:169.254.169.254]/hook",
        ].each do |url|
          target_rejected?(url).should be_true, "expected denied: #{url}"
        end
      end

      it "denies the deny-listed IPv6 families" do
        [
          "http://[::1]/hook",          # loopback
          "http://[fe80::1]/hook",      # link-local
          "http://[fc00::1]/hook",      # unique local
          "http://[fd12:3456::1]/hook", # unique local (fd00::/8)
          "http://[ff02::1]/hook",      # multicast
          "http://[2001:db8::1]/hook",  # documentation
        ].each do |url|
          target_rejected?(url).should be_true, "expected denied: #{url}"
        end
      end

      it "passes public literals of both families" do
        [
          "http://8.8.8.8/hook",
          "http://1.0.0.1/hook",
          "http://[2606:4700:4700::1111]/hook",
          "http://[2620:fe::fe]/hook",
        ].each do |url|
          target_rejected?(url).should be_false, "expected allowed: #{url}"
        end
      end

      it "judges a hostname by its resolved addresses" do
        # `localhost` resolves to loopback in every environment.
        target_rejected?("http://localhost/hook").should be_true
      end
    end
  end
end
