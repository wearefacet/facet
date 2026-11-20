# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "yaml"

module Facet
  # ── `mail:` section of `Facet::Config` ───────────────────────────────
  #
  # The `mail:` records, their YAML loaders, and the mail-adapter gate
  # live here, next to the email concern. `Facet::Config` (src/config.cr)
  # declares the `mail` field, calls `load_mail` when it parses the file,
  # and owns the cross-section checks.
  class Config
    # ── Mail records ────────────────────────────────────────────────────
    #
    # `adapter` defaults to `dev` (Carbon::DevAdapter — emails print to
    # stdout). Production refuses to load that default; see
    # `validate_mail_adapter`. `allow_dev_adapter_in_production` is the
    # explicit escape hatch for air-gapped installs.
    record MailConfig,
      adapter : String = "dev",
      from_address : String = "no-reply@facet.local",
      from_name : String = "Facet",
      smtp : SMTPConfig = SMTPConfig.new,
      allow_dev_adapter_in_production : Bool = false

    record SMTPConfig,
      host : String = "localhost",
      port : Int32 = 587,
      username : String? = nil,
      password : String? = nil,
      use_tls : Bool = true

    # Parses mail/SMTP config from the YAML document. Every key keeps a
    # default, so an absent `mail:` section still resolves to the dev
    # adapter — `validate_mail_adapter` decides whether that default may
    # boot.
    private def self.load_mail(raw : YAML::Any) : MailConfig
      mail_raw = raw["mail"]?
      return MailConfig.new if mail_raw.nil? || mail_raw.raw.nil?

      smtp = load_smtp(mail_raw["smtp"]?)

      MailConfig.new(
        adapter: read_str(mail_raw["adapter"]?) || "dev",
        from_address: read_str(mail_raw["from_address"]?) || "no-reply@facet.local",
        from_name: read_str(mail_raw["from_name"]?) || "Facet",
        smtp: smtp,
        allow_dev_adapter_in_production: read_bool(mail_raw["allow_dev_adapter_in_production"]?, false),
      )
    end

    # Parses the SMTP sub-config. Returns the default when `smtp_raw` is nil.
    private def self.load_smtp(smtp_raw : YAML::Any?) : SMTPConfig
      return SMTPConfig.new if smtp_raw.nil? || smtp_raw.raw.nil?

      SMTPConfig.new(
        host: read_str(smtp_raw["host"]?) || "localhost",
        port: read_int(smtp_raw["port"]?, 587),
        username: read_str(smtp_raw["username"]?),
        password: read_str(smtp_raw["password"]?),
        use_tls: read_bool(smtp_raw["use_tls"]?, true),
      )
    end

    # Fails closed when the dev mail adapter reaches production. The dev
    # adapter prints emails to stdout — password-reset, invite, and MFA
    # links never reach users. Production must set real delivery, or
    # accept stdout delivery with the explicit air-gapped override. The
    # dev-adapter warning is emitted by the CLI boot after the log
    # binding installs — see `warn_dev_mail_adapter_once`; the config
    # load itself never logs.
    private def self.validate_mail_adapter(mail : MailConfig) : Nil
      return unless mail.adapter == "dev"

      if app_env == "production" && !mail.allow_dev_adapter_in_production
        raise "Mail adapter 'dev' is not allowed in APP_ENV=production: it prints " \
              "emails to stdout, so password-reset, invite, and MFA links never " \
              "reach users. Set real delivery in config.#{app_env}.yml:\n" \
              "  mail:\n" \
              "    adapter: smtp\n" \
              "    smtp:\n" \
              "      host: smtp.example.tld\n" \
              "      port: 587\n" \
              "      username: ...\n" \
              "      password: ...\n" \
              "      use_tls: true\n" \
              "Air-gapped installs that must keep stdout delivery set:\n" \
              "  mail:\n" \
              "    allow_dev_adapter_in_production: true"
      end
    end

    @@dev_adapter_warned : Bool = false

    # Emits the stdout-delivery warning once per process — not once per
    # parse. Called by the CLI boot after `Facet::Logging.setup`, so the
    # line honours the configured log format. Specs re-arm it with
    # `reset_dev_adapter_warning!`.
    def self.warn_dev_mail_adapter_once : Nil
      return if @@dev_adapter_warned
      @@dev_adapter_warned = true
      ::Log.for("facet.config").warn do
        "Mail adapter is 'dev': emails print to stdout. They are not delivered. " \
        "Set 'mail.adapter: smtp' with the 'mail.smtp.*' keys in " \
        "config.#{app_env}.yml for real delivery."
      end
    end

    # Re-arms the once-per-process dev-adapter warning. Specs only —
    # production code never calls this.
    def self.reset_dev_adapter_warning! : Nil
      @@dev_adapter_warned = false
    end
  end
end
