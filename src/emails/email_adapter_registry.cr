# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "carbon"
require "carbon_smtp_adapter"
require "../config"

module Facet
  # Maps a mail adapter name to a Carbon adapter.
  #
  # The caller supplies the effective `MailConfig` — `BaseEmail` builds it
  # from the runtime settings (`core.SystemSettings`) merged over the
  # `mail:` section of `config.{env}.yml` (see
  # `doc/backend/system-settings.md`). The registry owns only the name →
  # adapter mapping, so the set of known adapters lives in one place.
  #
  # In-box adapters:
  #
  # | Name   | Class                  | Notes                                              |
  # |--------|------------------------|----------------------------------------------------|
  # | `dev`  | `Carbon::DevAdapter`   | Prints emails to stdout. Default for dev/test.     |
  # | `smtp` | `Carbon::SmtpAdapter`  | Real SMTP delivery (from carbon_smtp_adapter).     |
  #
  # ## Adding a custom adapter
  #
  # To use a Carbon adapter that isn't bundled here (e.g. SendGrid, Postmark,
  # Mailgun), the user rebuilds the app with their chosen shard and registers
  # it at startup:
  #
  # ```
  # Facet::EmailAdapterRegistry.register("sendgrid") do |mail|
  #   MySendGridAdapter.new(api_key: mail.smtp.password)
  # end
  # ```
  #
  # The block receives the `MailConfig` so it can pull credentials from the
  # effective `mail.smtp.*` fields (the resolved view, not the raw file).
  module EmailAdapterRegistry
    @@builders = {} of String => (Facet::Config::MailConfig -> Carbon::Adapter)

    # Registers an adapter `name` with a builder block. The block receives
    # the mail config and returns a configured `Carbon::Adapter` instance.
    def self.register(name : String, &builder : Facet::Config::MailConfig -> Carbon::Adapter) : Nil
      @@builders[name] = builder
    end

    # Returns the adapter for `name`, or nil if no builder is registered.
    def self.build(name : String, mail : Facet::Config::MailConfig) : Carbon::Adapter?
      builder = @@builders[name]?
      builder.try(&.call(mail))
    end

    # Returns true if an adapter with `name` is registered.
    def self.registered?(name : String) : Bool
      @@builders.has_key?(name)
    end

    # Returns the names of all registered adapters.
    def self.names : Array(String)
      @@builders.keys
    end

    # ── Built-in adapters ───────────────────────────────────────────

    # The `dev` adapter prints emails to stdout via `Carbon::DevAdapter`.
    # Always available; safe default for tests and local dev.
    register("dev") do |_mail|
      Carbon::DevAdapter.new(print_emails: true)
    end

    # The `smtp` adapter requires the `carbon_smtp_adapter` shard (bundled).
    # Host, port, TLS, username, and password all come from `mail.smtp.*`
    # in the YAML config; if username is set without a password (or vice
    # versa) the adapter raises a clear error on first send.
    register("smtp") do |mail|
      smtp = Carbon::SmtpAdapter.settings
      smtp.host = mail.smtp.host
      smtp.port = mail.smtp.port
      smtp.use_tls = mail.smtp.use_tls
      smtp.username = mail.smtp.username
      smtp.password = mail.smtp.password
      Carbon::SmtpAdapter.new
    end
  end
end
