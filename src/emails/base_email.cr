# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "carbon"
require "./config"
require "../config"
require "../system_settings"
require "./email_adapter_registry"

module Facet
  # Base class for all outbound emails.
  #
  # The Carbon adapter is configured from the effective mail settings — the
  # `core.SystemSettings` document merged over the `mail:` section of
  # `config.{env}.yml` (`SystemSettings::MailView`). Resolution is delegated
  # to `EmailAdapterRegistry` so the set of known adapters lives in one
  # place.
  #
  # The adapter is configured lazily on first email send via `configure!`,
  # which re-runs when the settings cache is no longer fresh: the
  # `SystemSettingsCache` subscriber marks the cache stale on every settings
  # mutation (the fast path), and `cache.staleness_ttl_s` bounds the
  # worst case when a fanout is lost. `before_send` re-runs `configure!` on
  # every send, so a settings change reaches the next send without a
  # restart.
  abstract class BaseEmail < Carbon::Email
    # ── Memo state ──────────────────────────────────────────────────
    #
    # Both variables are accessed ONLY through the class methods below.
    # Crystal resolves a bare `@@var` inside an instance method against
    # `self.class`, so a subclass instance (`InviteEmail`…) would read its
    # own, separately-initialized storage and silently miss every write
    # `configure!` made on the base — the memo would never be seen.
    @@configured : Bool = false

    # The effective mail view the adapter was built from. `from` reads it
    # so the header and the adapter always come from the same resolution.
    @@mail_view : Config::MailConfig? = nil

    # Memo accessors. Deliberately class methods (not bare `@@var` reads):
    # an instance method resolving `@@var` against `self.class` would give
    # every subclass its own storage — see the note on the variables above.
    def self.memo_configured? : Bool
      @@configured
    end

    def self.memo_mail_view : Config::MailConfig?
      @@mail_view
    end

    # Configures Carbon's adapter from the effective mail settings if not
    # already done — or if the settings cache is no longer fresh, so a
    # stale memo cannot outlive a settings change. Safe to call repeatedly;
    # the hot path (configured + fresh cache) is a flag check with no DB
    # access. A rebuild acquires the DB through the standard pool.
    def self.configure! : Nil
      return if memo_configured? && SystemSettings.fresh?

      mail = Database.with_db do |db|
        SystemSettings::MailView.build(db)
      end

      adapter = EmailAdapterRegistry.build(mail.adapter, mail)
      unless adapter
        raise "Unknown mail adapter: '#{mail.adapter}'. Registered adapters: " \
              "#{EmailAdapterRegistry.names.join(", ")}. Set mail.adapter in the " \
              "system settings or the config file to one of those, or register a " \
              "custom adapter via EmailAdapterRegistry.register."
      end

      store_adapter(adapter, mail)
    end

    # The write side of the memo. A class method so the assignment lands on
    # `Facet::BaseEmail`'s own storage (see the accessors above).
    private def self.store_adapter(adapter : Carbon::Adapter, mail : Config::MailConfig) : Nil
      BaseEmail.settings.adapter = adapter
      @@mail_view = mail
      @@configured = true
    end

    # Forces reconfiguration on the next send (the settings subscriber's
    # rebuild hook; also used by tests).
    def self.reset_configuration! : Nil
      @@configured = false
    end

    # Hook called by Carbon before sending — ensures the adapter matches
    # the current settings (a change may have landed since the last send).
    def before_send : Nil
      BaseEmail.configure!
    end

    # `from` is defined as a method (not the macro form) so it can read the
    # effective configuration. Carbon's `from` macro ultimately defines a
    # method like this; defining it directly satisfies the abstract
    # contract. The read routes through `configure!`, so the header checks
    # the settings-cache generation exactly like the adapter build does.
    def from : Carbon::Address
      BaseEmail.configure!
      mail = BaseEmail.memo_mail_view || Facet::Config.instance.mail
      Carbon::Address.new(mail.from_name, mail.from_address)
    end
  end
end
