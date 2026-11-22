# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../config"
require "../settings/keys"
require "../service"
require "../error"
require "../validation_error"
require "../util/projections"
require "./spec"
require "./service"

module Facet
  module SystemSettings
    # Write-time semantic gate for `core.SystemSettings` saves. Runs from
    # the doctype-keyed branch in `Document::Update` (the
    # `validate_rbac_definitions?` precedent), after the deep merge, so it
    # sees the exact state the mutation would land on.
    #
    # The validation split (plan D9):
    # - *Shape* — the doctype definition: field kinds, the `mail.adapter`
    #   enum, secret placement. Answered by the standard patch validation.
    # - *Singleton* — the Lua lifecycle script: create refuses non-system
    #   principals, delete refuses unconditionally.
    # - *Semantics* — this gate: every rule the definition cannot express.
    #   Bad values answer `422` at save time, never at send time.
    #
    # The production mail gate honors the file-only escape hatch
    # (`mail.allow_dev_adapter_in_production`) with the exact parity the
    # config loader enforces at boot (`validate_mail_adapter`). The hatch
    # stays file-only — deployment material, not a runtime knob.
    #
    # The IAM-policy rules (the `iam.mfa.*` / `iam.auth.mode` enums, the
    # localization IANA / allowlist checks) mirror the account-settings
    # validation (`Settings::Keys`) and the config loader's own load-time
    # checks, so a save can never land a value the consumers refuse. The
    # `oidc_only` mode is additionally refused while no enabled
    # `iam.OIDCProvider` document exists — locking every login path out in
    # one save must be impossible through the UI (the config file tier
    # stays the operator's explicit escape).
    module WriteGate
      # The longest display name a save may pin.
      NAME_MAX_LENGTH = 40

      # The refusal for `artifact.storage` and every value beneath it. The
      # storage adapter is deployment material, not a runtime knob: it wires
      # once per process from the config file, and every artifact row lives
      # under the one constant storage key, so a runtime switch would strand
      # the existing bytes in the old backend. One constant so the REST door
      # answers the same sentence for the intermediate node and for the leaf
      # (F09-05 — the schema layer refuses the undeclared node before this
      # gate could run, so `WriteGate.refusal` reuses the text there too).
      STORAGE_FIXED_MESSAGE = "is fixed at deployment: the storage adapter wires at boot from the config " \
                              "file and existing artifact bytes stay in the previous backend. Change " \
                              "artifact.storage in the config file and restart"

      # Returns the gate's `ValidationError` for the deployment-material
      # field named by `path`, or `nil` when `path` is not that subtree.
      # Used by the patch-validation layer to answer the right sentence for
      # `artifact.storage` (an intermediate node the schema has no leaf
      # for) instead of "is not a defined field".
      def self.refusal(path : String) : ValidationError?
        return nil unless path == "artifact.storage" || path.starts_with?("artifact.storage.")

        ValidationError.new(
          field: path,
          message: STORAGE_FIXED_MESSAGE,
          code: "invalid_format",
        )
      end

      # Validates the merged document state. Returns the structured
      # validation errors (empty = valid). `db` serves the save-time query
      # the `oidc_only` rule runs (one indexed count over the provider
      # projections).
      def self.validate(merged : JSON::Any, db : DB::Connection) : Array(ValidationError)
        errors = [] of ValidationError
        validate_kinds(merged, errors)
        validate_bounds(merged, errors)
        validate_assistant_name(merged, errors)
        validate_mail_rules(merged, errors)
        validate_artifact_rules(merged, errors)
        validate_localization_rules(merged, errors)
        validate_iam_rules(merged, db, errors)
        errors
      end

      # ── Kind checks ────────────────────────────────────────────────
      #
      # The doctype definition owns the field kinds, but the gate re-checks
      # every registered path so the registry stays the single semantic
      # authority: if a definition type ever loosens (or a future tier adds
      # an `any`-typed path like `temperature`), the gate still holds.

      private def self.validate_kinds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        SPEC.each do |path, entry|
          value = content_at(merged, path)
          next if value.nil? || value.raw.nil?
          next if entry.secret?

          message = kind_error(entry.kind, value)
          unless message.nil?
            errors << ValidationError.new(
              field: path,
              message: "must be #{message}",
              code: "invalid_type",
              params: {"expected" => message.to_s},
            )
          end
        end
      end

      private def self.kind_error(kind : Kind, value : JSON::Any) : String?
        case kind
        when Kind::String, Kind::Text
          value.as_s? ? nil : "a string"
        when Kind::Bool
          value.raw.is_a?(Bool) ? nil : "a boolean"
        when Kind::Number
          number?(value) ? nil : "a number"
        when Kind::StringList
          string_list?(value) ? nil : "an array of strings"
        when Kind::Secret
          nil
        end
      end

      private def self.string_list?(value : JSON::Any) : Bool
        arr = value.as_a?
        return false if arr.nil?
        arr.all?(&.as_s?)
      end

      private def self.number?(value : JSON::Any) : Bool
        value.as_i64? || value.as_f? ? true : false
      end

      # ── Bounds ─────────────────────────────────────────────────────
      #
      # The schema cannot express numeric ranges, so the gate owns them.
      # One helper per concern keeps each method's branch count small.

      private def self.validate_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        validate_assistant_bounds(merged, errors)
        validate_mail_bounds(merged, errors)
        validate_artifact_bounds(merged, errors)
        validate_retention_bounds(merged, errors)
        validate_iam_bounds(merged, errors)
      end

      private def self.validate_assistant_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        check_bound(merged, "assistant.max_tokens", errors) do |n|
          n > 0 || "must be a positive integer"
        end
        check_bound(merged, "assistant.max_history", errors) do |n|
          n >= 0 || "must be zero or greater (empty means unlimited)"
        end

        temperature = number_at(merged, "assistant.temperature")
        unless temperature.nil?
          unless temperature >= 0.0 && temperature <= 2.0
            errors << ValidationError.new(
              field: "assistant.temperature",
              message: "must be between 0.0 and 2.0",
              code: "out_of_range",
              params: {"value" => temperature.to_s, "min" => "0.0", "max" => "2.0"},
            )
          end
        end
      end

      private def self.validate_mail_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        check_bound(merged, "mail.smtp.port", errors) do |n|
          (n >= 1 && n <= 65535) || "must be between 1 and 65535"
        end
      end

      private def self.validate_artifact_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        check_bound(merged, "artifact.grant_ttl_seconds", errors) do |n|
          n >= 1 || "must be a positive number of seconds"
        end
        check_bound(merged, "artifact.grant_ttl_media_seconds", errors) do |n|
          n >= 1 || "must be a positive number of seconds"
        end
        check_bound(merged, "artifact.prune_after_days", errors) do |n|
          n >= 0 || "must be zero (keep forever) or a positive number of days"
        end
      end

      private def self.validate_retention_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        check_bound(merged, "mutations.retention_days", errors) do |n|
          n >= 0 || "must be zero (keep forever) or a positive number of days"
        end
        check_bound(merged, "tombstone.content_retention_days", errors) do |n|
          n >= 0 || "must be zero (keep forever) or a positive number of days"
        end
      end

      private def self.validate_iam_bounds(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        check_bound(merged, "iam.change_password_expiration", errors) do |n|
          n >= 1 || "must be a positive number of seconds"
        end
      end

      # ── Assistant name ───────────────────────────────────────────
      #
      # The name renders in tight chrome — the top-bar pill, the window
      # headers, the turn headers — so a blank or oversized value is
      # refused at save time instead of leaking into every surface.
      private def self.validate_assistant_name(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        name = str_at(merged, "assistant.name")
        return if name.nil?

        if name.strip.empty?
          errors << ValidationError.new(
            field: "assistant.name",
            message: "must not be blank",
            code: "invalid_format",
            params: {"value" => name},
          )
        elsif name.size > NAME_MAX_LENGTH
          errors << ValidationError.new(
            field: "assistant.name",
            message: "must be #{NAME_MAX_LENGTH} characters or fewer",
            code: "out_of_range",
            params: {"value" => name, "max" => NAME_MAX_LENGTH.to_s},
          )
        end
      end

      # Runs *block* on the numeric value at *path* when one is set; the
      # block returns `true` (or a truthy string message) when valid.
      private def self.check_bound(merged : JSON::Any, path : String, errors : Array(ValidationError), &)
        n = number_at(merged, path)
        return if n.nil?
        result = yield n
        return if result.is_a?(Bool) && result

        errors << ValidationError.new(
          field: path,
          message: result.to_s,
          code: "out_of_range",
          params: {"value" => n.to_s},
        )
      end

      private def self.number_at(merged : JSON::Any, path : String) : Float64?
        value = content_at(merged, path)
        return nil if value.nil? || value.raw.nil?
        if i = value.as_i64?
          i.to_f
        elsif f = value.as_f?
          f
        else
          nil
        end
      end

      # ── Mail rules ─────────────────────────────────────────────────

      private def self.validate_mail_rules(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        adapter = str_at(merged, "mail.adapter")
        return if adapter.nil?

        if adapter == "smtp"
          validate_smtp_host(merged, errors)
        elsif adapter == "dev"
          validate_dev_in_production(errors)
        end
      end

      # `mail.adapter: smtp` requires a non-null `mail.smtp.host` in the
      # merged state. The deep merge already keeps a previously pinned host
      # through a patch that does not touch it, so the merged state is the
      # whole truth: an smtp switch with no host anywhere in the document
      # would depend on the file staying put — a silent break on restart.
      private def self.validate_smtp_host(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        host = str_at(merged, "mail.smtp.host")
        return unless host.nil? || host.empty?

        errors << ValidationError.new(
          field: "mail.smtp.host",
          message: "is required when mail.adapter is 'smtp'",
          code: "invalid_format",
          params: {"reason" => "the smtp adapter needs a host in the saved state"},
        )
      end

      # `mail.adapter: dev` is refused under `APP_ENV=production` unless the
      # file sets `mail.allow_dev_adapter_in_production` — the same gate the
      # config loader applies at boot, repeated at write time so a runtime
      # change cannot weaken it.
      private def self.validate_dev_in_production(errors : Array(ValidationError)) : Nil
        return unless Facet::Config.app_env == "production"
        return if Facet::Config.instance.mail.allow_dev_adapter_in_production

        errors << ValidationError.new(
          field: "mail.adapter",
          message: "'dev' is not allowed in production: it prints emails to stdout, so " \
                   "password-reset, invite, and MFA links never reach users. Set the smtp " \
                   "adapter with mail.smtp.host, or accept stdout delivery with " \
                   "mail.allow_dev_adapter_in_production: true in the config file",
          code: "invalid_format",
        )
      end

      # ── Artifact rules ─────────────────────────────────────────────

      # `artifact.storage.type` is deployment material, not a runtime knob:
      # the shrine storage wires once per process from the config file, and
      # every artifact row lives under the one constant storage key, so a
      # runtime switch would strand the existing bytes in the old backend.
      # The registry registers the path for read visibility only; this rule
      # refuses any value that reaches it through another route.
      private def self.validate_artifact_rules(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        adapter = content_at(merged, "artifact.storage.type")
        return if adapter.nil? || adapter.raw.nil?

        errors << ValidationError.new(
          field: "artifact.storage.type",
          message: STORAGE_FIXED_MESSAGE,
          code: "invalid_format",
        )
      end

      # ── Localization rules ──────────────────────────────────────

      # The instance defaults validate like the account-level values they
      # generalize (`Settings::Keys.validate_value`): a loadable IANA
      # timezone, a language inside the allowlist.
      private def self.validate_localization_rules(merged : JSON::Any, errors : Array(ValidationError)) : Nil
        if timezone = str_at(merged, "localization.default_timezone")
          begin
            Time::Location.load(timezone)
          rescue ex
            errors << ValidationError.new(
              field: "localization.default_timezone",
              message: "is not a loadable IANA timezone (#{ex.message})",
              code: "invalid_format",
              params: {"value" => timezone},
            )
          end
        end

        if language = str_at(merged, "localization.default_language")
          unless Facet::Settings::Keys::ALLOWED_LANGUAGES.includes?(language)
            errors << ValidationError.new(
              field: "localization.default_language",
              message: "is not a supported language (allowed: " \
                       "#{Facet::Settings::Keys::ALLOWED_LANGUAGES.to_a.sort.join(", ")})",
              code: "invalid_format",
              params: {"value" => language},
            )
          end
        end
      end

      # ── IAM policy rules ─────────────────────────────────────────

      # The policy enums mirror the config loader (`load_mfa`, `load_auth`):
      # a typo fails closed at save instead of silently downgrading the
      # policy. `oidc_only` additionally requires one enabled provider
      # document — with zero enabled providers it would lock every login
      # path out at once.
      private def self.validate_iam_rules(merged : JSON::Any, db : DB::Connection, errors : Array(ValidationError)) : Nil
        if type = str_at(merged, "iam.mfa.type")
          unless type == "none" || type == "totp"
            errors << enum_error("iam.mfa.type", type, %w[none totp])
          end
        end

        if enforcement = str_at(merged, "iam.mfa.enforcement")
          unless enforcement == "preferred" || enforcement == "always"
            errors << enum_error("iam.mfa.enforcement", enforcement, %w[preferred always])
          end
        end

        if mode = str_at(merged, "iam.auth.mode")
          if mode != "hybrid" && mode != "oidc_only"
            errors << enum_error("iam.auth.mode", mode, %w[hybrid oidc_only])
          elsif mode == "oidc_only" && enabled_provider_count(db).zero?
            errors << ValidationError.new(
              field: "iam.auth.mode",
              message: "'oidc_only' requires at least one enabled iam.OIDCProvider — " \
                       "with none configured it would refuse every login. Create and " \
                       "enable a provider first, or keep 'hybrid'",
              code: "invalid_format",
              params: {"value" => mode},
            )
          end
        end

        validate_provision_roles(merged, db, errors)
      end

      # `iam.oidc.provision_roles` — every entry must name a live
      # `iam.Roles` document (the projections id IS the qualified form,
      # `iam.Roles.employee`), and the list must carry no duplicates: the
      # JIT provisioning copies the list onto the account verbatim, and a
      # duplicate would crash the account editor's keyed render.

      private def self.enum_error(field : String, value : String, allowed : Array(String)) : ValidationError
        ValidationError.new(
          field: field,
          message: "must be #{allowed.join(" or ")} (got '#{value}')",
          code: "invalid_format",
          params: {"value" => value, "allowed" => allowed.join(", ")},
        )
      end

      private def self.validate_provision_roles(merged : JSON::Any, db : DB::Connection, errors : Array(ValidationError)) : Nil
        value = content_at(merged, "iam.oidc.provision_roles")
        return if value.nil? || value.raw.nil?
        arr = value.as_a?
        return if arr.nil? # kind check already reported

        seen = Set(String).new
        arr.each do |entry|
          role_id = entry.as_s?
          next if role_id.nil? # kind check already reported
          if seen.includes?(role_id)
            errors << ValidationError.new(
              field: "iam.oidc.provision_roles",
              message: "must not repeat a role ('#{role_id}' appears twice)",
              code: "invalid_format",
              params: {"value" => role_id},
            )
            next
          end
          seen << role_id
          next if Facet::Util::Projections.exists?(db, "iam", "Roles", role_id)
          errors << ValidationError.new(
            field: "iam.oidc.provision_roles",
            message: "'#{role_id}' does not name an existing iam.Roles document — " \
                     "create the role first, or pick it again from the list",
            code: "invalid_format",
            params: {"value" => role_id},
          )
        end
      end

      # One indexed count over the live provider projections. A tombstone
      # never counts: its `deleted_at` excludes the row, matching every
      # registry read (`OIDC::ProviderStore`).
      private def self.enabled_provider_count(db : DB::Connection) : Int64
        db.query_one(
          "SELECT count(*) FROM projections " \
          "WHERE domain = 'iam' AND doc_type = 'OIDCProvider' AND deleted_at IS NULL " \
          "AND COALESCE((content->>'enabled')::boolean, true)",
          as: Int64,
        )
      end

      # ── Path reading ─────────────────────────────────────────────

      private def self.str_at(merged : JSON::Any, path : String) : String?
        value = content_at(merged, path)
        return nil if value.nil? || value.raw.nil?
        value.as_s?
      end

      private def self.content_at(merged : JSON::Any, path : String) : JSON::Any?
        node = merged
        path.split('.').each do |segment|
          obj = node.as_h?
          return nil if obj.nil?
          node = obj[segment]?
          return nil if node.nil?
        end
        node
      end
    end
  end
end
