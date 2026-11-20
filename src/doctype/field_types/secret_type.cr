# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Doctype
    # Field type for out-of-band secrets.
    #
    # A `secret` field never carries a secret material in document content.
    # The value is staged out-of-band (`POST /Api/secrets/stage`) and the
    # write pipelines substitute a marker — `{mode, version, set_at}` — while
    # the material lands in the `secrets` table (see `doc/backend/secrets.md`).
    #
    # At document-validation time the field accepts exactly these shapes:
    #
    # - a stage-handle string (`sh_` + a 26-character Crockford ULID);
    # - a marker object `{mode, version, set_at}` — legal only where the
    #   content was merged from the projection; adoption verifies every
    #   marker against the stored slot row, so a forged marker fails closed;
    # - `null` — clear intent (adoption deletes the slot). The shared
    #   optional-field skip already accepts null, so `validate` never sees it.
    #
    # Anything else — including a plaintext string — is a `422 invalid_format`.
    #
    # Definition-time rules (`validate_definition`) enforce the closed mode
    # enum and reject every attribute combination that cannot work for an
    # out-of-band value. Placement rules that need whole-definition context
    # (not inside arrays or dictionaries, excluded from `search` and
    # `display_name`, banned as action arguments) live in `Doctype::Validation`.
    class SecretType < FieldType
      register_type "secret"

      # The closed mode enum. Selects the consumer operation — `verify`,
      # `reveal`, or `consume` (see `Secrets`). Algorithms live inside the
      # self-describing payload; they are never a schema concern.
      MODES = %w[hash sealed token]

      # Stage handles are minted by the `secret_staging` table: `sh_` + a
      # Crockford ULID (`Util::ScriptHelpers.ulid` alphabet).
      HANDLE_RE = /^sh_[0-9A-HJKMNP-TV-Z]{26}$/

      # The exact key set of an adoption marker. No other keys — the marker
      # is metadata about the slot, never a carrier of material.
      MARKER_KEYS = Set{"mode", "version", "set_at"}

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if str = value.as_s?
          unless str.matches?(HANDLE_RE)
            errors << ValidationError.new(
              field: path,
              message: "must be a stage handle (sh_ + 26-character ULID)",
              code: "invalid_format",
              params: {"value" => str, "format" => "a stage handle (sh_ + 26-character ULID)"},
            )
          end
          return
        end

        if obj = value.as_h?
          validate_marker(obj, path, errors)
          return
        end

        errors << ValidationError.new(
          field: path,
          message: "must be a stage handle, a secret marker, or null",
          code: "invalid_format",
          params: {"format" => "a stage handle, a secret marker, or null"},
        )
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        mode = field_definition.mode
        validate_mode(mode, path, errors)
        reject_forbidden_attributes(field_definition, path, errors)
        validate_ttl(mode, field_definition.ttl_seconds, path, errors)
      end

      # Applies the plaintext constraints declared on the definition —
      # `min`/`max` as length bounds and `pattern` as a regex — to the raw
      # plaintext at staging time. Never sees handles or markers.
      #
      # Public because the stage route is the caller; document validation
      # never holds a plaintext.
      def validate_plaintext(
        plaintext : String,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if min = field_definition.min
          if plaintext.size < min
            errors << ValidationError.new(
              field: path,
              message: "is shorter than the minimum length (#{min})",
              code: "invalid_format",
            )
          end
        end

        if max = field_definition.max
          if plaintext.size > max
            errors << ValidationError.new(
              field: path,
              message: "is longer than the maximum length (#{max})",
              code: "invalid_format",
            )
          end
        end

        if pattern = field_definition.pattern
          validate_pattern(field_definition, path, plaintext, errors, pattern)
        end
      end

      # ── Private ───────────────────────────────────────────────────────

      private def validate_marker(
        obj : Hash(String, JSON::Any),
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        unless obj.keys.to_set == MARKER_KEYS
          errors << ValidationError.new(
            field: path,
            message: "secret marker must carry exactly {mode, version, set_at}",
            code: "invalid_format",
            params: {"format" => "a marker object with the keys mode, version, set_at"},
          )
          return
        end

        require_string(obj["mode"], "#{path}.mode", errors, code: "invalid_format")

        unless obj["version"].as_i?
          errors << ValidationError.new(
            field: "#{path}.version",
            message: "must be an integer",
            code: "invalid_format",
            params: {"format" => "an integer"},
          )
        end

        require_string(obj["set_at"], "#{path}.set_at", errors, suffix: "UTC RFC-3339", code: "invalid_format")
      end

      # `token` secrets must declare a positive `ttl_seconds` — the store's
      # `consume` checks the TTL in the same statement, so a token without a
      # TTL would be unusable. `hash` and `sealed` forbid the knob.
      private def validate_ttl(
        mode : String?,
        ttl_seconds : Int64?,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        return if mode.nil?

        if mode == "token"
          if ttl_seconds.nil? || ttl_seconds <= 0
            errors << ValidationError.new(
              field: path,
              message: "token secret must declare a positive ttl_seconds (the token expires when the slot is adopted)",
              code: "schema",
            )
          end
        elsif ttl_seconds
          errors << ValidationError.new(
            field: path,
            message: "only token secrets may declare ttl_seconds",
            code: "schema",
          )
        end
      end

      private def reject_attribute(path : String, attribute : String, errors : Array(ValidationError)) : Nil
        errors << ValidationError.new(
          field: path,
          message: "secret field cannot declare #{attribute}",
          code: "schema",
        )
      end

      private def validate_mode(
        mode : String?,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if mode.nil?
          errors << ValidationError.new(
            field: path,
            message: "secret field must declare a mode (hash, sealed, or token)",
            code: "schema",
          )
        elsif !MODES.includes?(mode)
          errors << ValidationError.new(
            field: path,
            message: "unknown secret mode '#{mode}' (allowed: #{MODES.join(", ")})",
            code: "schema",
          )
        end
      end

      # Attributes that cannot work for an out-of-band value. `min`, `max`,
      # and `pattern` are deliberately allowed — they constrain the
      # plaintext at staging time, never the handle or the marker.
      private def reject_forbidden_attributes(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        reject_shape_attributes(field_definition, path, errors)
        reject_value_attributes(field_definition, path, errors)
      end

      # Attributes that describe how the value flows — none apply to an
      # out-of-band slot.
      private def reject_shape_attributes(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if field_definition.unique
          reject_attribute(path, "unique", errors)
        end
        if (filters = field_definition.filters) && !filters.empty?
          reject_attribute(path, "filters", errors)
        end
        if field_definition.compute || field_definition.compute_when
          reject_attribute(path, "compute/compute_when", errors)
        end
        if field_definition.replicate
          reject_attribute(path, "replicate", errors)
        end
      end

      # Attributes that carry a literal value or block writes — a secret
      # has no literal to default to, and the slot lifecycle owns it.
      private def reject_value_attributes(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        if field_definition.read_only?
          reject_attribute(path, "read_only", errors)
        end
        if field_definition.write_only?
          reject_attribute(path, "write_only", errors)
        end
        if field_definition.default
          reject_attribute(path, "default", errors)
        end
        if field_definition.collection
          reject_attribute(path, "collection", errors)
        end
        if field_definition.items
          reject_attribute(path, "items", errors)
        end
        if field_definition.properties
          reject_attribute(path, "properties", errors)
        end
      end
    end
  end
end
