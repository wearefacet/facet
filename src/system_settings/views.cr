# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../config"
require "./spec"
require "./service"

module Facet
  module SystemSettings
    # Builds the `MailConfig`-shaped view the mail consumers read
    # (`BaseEmail.configure!`, `BaseEmail#from`, `EmailAdapterRegistry`).
    #
    # Every non-secret key resolves from the effective cache; the SMTP
    # password resolves through `reveal_secret` at build time (adapter
    # build) — a store read per rebuild, never cached. The file-side
    # `allow_dev_adapter_in_production` hatch stays a file value: it is
    # deployment material, not a runtime knob.
    #
    # Bool resolution NEVER uses `|| file.x`: `false || x` evaluates `x`, so
    # a document-pinned `false` would be silently replaced by the file
    # default (both file bools default `true`). Bools take the effective
    # value whenever it is present and fall back only on `nil`. The
    # value-type `||` chains are redundant (the cache already resolved
    # document → file for every non-secret path) but inert — strings, ints,
    # and floats treat only `nil` as falsy, so they never mask a pin.
    module MailView
      def self.build(db : DB::Connection) : Facet::Config::MailConfig
        values = Facet::SystemSettings.effective(db)
        file = Facet::Config.instance.mail

        host = str(values, "mail.smtp.host") || file.smtp.host
        port = int(values, "mail.smtp.port") || file.smtp.port
        username = str(values, "mail.smtp.username") || file.smtp.username
        use_tls = bool_or_file(values, "mail.smtp.use_tls", file.smtp.use_tls)
        password = Facet::SystemSettings.reveal_secret(db, "mail.smtp.password") ||
                   file.smtp.password

        Facet::Config::MailConfig.new(
          adapter: str(values, "mail.adapter") || file.adapter,
          from_address: str(values, "mail.from_address") || file.from_address,
          from_name: str(values, "mail.from_name") || file.from_name,
          smtp: Facet::Config::SMTPConfig.new(
            host: host,
            port: port,
            username: username,
            password: password,
            use_tls: use_tls,
          ),
          allow_dev_adapter_in_production: file.allow_dev_adapter_in_production,
        )
      end

      # ── Coercions ──────────────────────────────────────────────────
      #
      # The cache values are JSON::Any; a document-pinned number may be
      # any JSON numeric shape, so each reader accepts both integer and
      # float forms. Unset entries (nil) fall back at the call site.

      private def self.str(values : Hash(String, JSON::Any), path : String) : String?
        values[path]?.try(&.as_s?)
      end

      private def self.int(values : Hash(String, JSON::Any), path : String) : Int32?
        v = values[path]?
        return nil unless v
        raw = v.raw
        raw.to_i32 if raw.is_a?(Int64)
      end

      private def self.bool_or_nil(values : Hash(String, JSON::Any), path : String) : Bool?
        values[path]?.try(&.as_bool?)
      end

      # The pinned-`false`-safe Bool resolution: the effective value wins
      # whenever present (including `false`); the file value applies only
      # when the path resolves to nothing.
      private def self.bool_or_file(values : Hash(String, JSON::Any), path : String, file_value : Bool) : Bool
        resolved = bool_or_nil(values, path)
        resolved.nil? ? file_value : resolved
      end
    end

    # Builds the `Assistant::Config` view for one turn. The connection
    # resolves at every turn start — endpoint, key, model, and the sampling
    # knobs — so a settings change reaches existing conversations on their
    # next turn. There is no per-conversation pin.
    #
    # `system_prompt` is the conversation-stored prompt (the main assistant
    # captures the setting at create; workspace and builder assistants build
    # their own prompts). A stored prompt wins; nil falls back to the
    # setting, then to the file. The key resolves through `reveal_secret`
    # (store read per turn start, never cached).
    module AssistantView
      # The display name every assistant surface shows — the workspace and
      # builder windows and the top-bar entry point all render one name.
      # Same resolution as every non-secret path, without the secret read
      # `build` performs: `/Api/iam/me` serves it on every login.
      def self.display_name(db : DB::Connection) : String
        Facet::SystemSettings.string_at(db, "assistant.name") ||
          Facet::Config.instance.assistant.name
      end

      # Whether an assistant API key resolves — the sealed settings slot
      # first, then the file value (via `!env?`, so an absent variable lands
      # here as nil). The one signal `/Api/iam/me` serves as
      # `assistant.configured`: `false` keeps the assistant dock visible but
      # disables conversation creation, and the settings-page probe answers
      # `422` instead of dialling. Mirrors the key resolution in `build`
      # exactly, so the flag never disagrees with what a turn would use.
      def self.configured?(db : DB::Connection) : Bool
        key = Facet::SystemSettings.reveal_secret(db, "assistant.api_key") ||
              Facet::Config.instance.assistant.api_key
        !(key.nil? || key.empty?)
      end

      def self.build(db : DB::Connection, system_prompt : String?) : Facet::Assistant::Config
        values = Facet::SystemSettings.effective(db)
        file = Facet::Config.instance.assistant

        api_key = Facet::SystemSettings.reveal_secret(db, "assistant.api_key") ||
                  file.api_key

        Facet::Assistant::Config.new(
          name: str(values, "assistant.name") || file.name,
          api_endpoint: str(values, "assistant.api_endpoint") || file.api_endpoint,
          api_key: api_key,
          model: str(values, "assistant.model") || file.model,
          system_prompt: system_prompt || str(values, "assistant.system_prompt") || file.system_prompt,
          max_tokens: int(values, "assistant.max_tokens") || file.max_tokens,
          temperature: float(values, "assistant.temperature") || file.temperature,
          max_history: int(values, "assistant.max_history") || file.max_history,
          auto_execute_tools: bool_or_file(values, "assistant.auto_execute_tools", file.auto_execute_tools?),
          cancel_ttl_seconds: file.cancel_ttl_seconds,
          turn_timeout_seconds: file.turn_timeout_seconds,
          turn_sweep_cron: file.turn_sweep_cron,
          usage_retention_days: file.usage_retention_days,
          usage_prune_cron: file.usage_prune_cron,
        )
      end

      private def self.str(values : Hash(String, JSON::Any), path : String) : String?
        values[path]?.try(&.as_s?)
      end

      private def self.int(values : Hash(String, JSON::Any), path : String) : Int32?
        v = values[path]?
        return nil unless v
        raw = v.raw
        raw.to_i32 if raw.is_a?(Int64)
      end

      private def self.float(values : Hash(String, JSON::Any), path : String) : Float64?
        v = values[path]?
        return nil unless v
        raw = v.raw
        if raw.is_a?(Float64)
          raw
        elsif raw.is_a?(Int64)
          raw.to_f
        else
          nil
        end
      end

      private def self.bool_or_nil(values : Hash(String, JSON::Any), path : String) : Bool?
        values[path]?.try(&.as_bool?)
      end

      # The pinned-`false`-safe Bool resolution — see `MailView.bool_or_file`.
      private def self.bool_or_file(values : Hash(String, JSON::Any), path : String, file_value : Bool) : Bool
        resolved = bool_or_nil(values, path)
        resolved.nil? ? file_value : resolved
      end
    end
  end
end
