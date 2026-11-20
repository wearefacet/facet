# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../error"
require "../validation_error"

module Facet
  module Document
    # Validates a document (as a `JSON::Any`) against a `DoctypeDefinition`.
    #
    # This service performs **schema‑level** validation:
    # - required fields are present
    # - field types match (string → string, integer → integer, etc.)
    # - enum fields have values from the defined set
    # - no unknown fields are present
    # - no caller write touches a `read_only` or `replicated` field
    #   (skipped with `check_readonly: false` — the create pipeline runs
    #   that gate on the raw caller body, before defaults are applied;
    #   see `readonly_write_errors` and B-349)
    #
    # References are *not* resolved here (they require a registry).
    # Children are not validated here — they are separate documents.
    #
    # Type‑specific validation is delegated to each `FieldType` subclass.
    class Validation
      # Validate a document against a doctype definition.
      # Returns an array of structured errors (empty if valid).
      #
      # `check_readonly: false` skips the read-only caller-write gate. The
      # create pipeline uses it on the post-defaults pass: the gate already
      # ran on the raw caller body, and `ApplyDefaults` fills every missing
      # key that has a default, a read-only field included. A second pass
      # would reject the platform's own write (B-349).
      def self.validate(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        allow_system_writes : Bool = false,
        check_readonly : Bool = true,
      ) : Array(ValidationError)
        new.validate(document, definition, allow_system_writes: allow_system_writes, check_readonly: check_readonly)
      end

      # The read-only caller-write gate. A caller-submitted key on a
      # `read_only` or `replicated` field is a write the API refuses. A
      # system write (`allow_system_writes`) is exempt: the replication
      # handler and the reentrant mutation target these fields directly.
      #
      # The create pipeline runs this gate on the raw caller body, BEFORE
      # defaults are applied (B-349). `ApplyDefaults` materializes every
      # declared default, read-only fields included. A check after that
      # step would reject the platform's own write — a create of
      # `core.DomainGrant` without `active` answered 422 for a field the
      # caller never sent. The update pipeline has no defaults step; its
      # `validate_update` pass runs the gate through `check`.
      def self.readonly_write_errors(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        allow_system_writes : Bool = false,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        doc_hash = document.as_h?
        return errors if doc_hash.nil?

        doc_keys = doc_hash.keys.to_set
        definition.fields.each do |field_name, field|
          if field.read_only? && !allow_system_writes && doc_keys.includes?(field_name)
            errors << ValidationError.new(
              field: field_name,
              message: "is read-only and should not be set",
              code: "read_only",
            )
          end

          # Replicated fields are also read-only (like computed fields),
          # UNLESS the caller is a system-driven write (reentrant
          # mutation) — in that case the replica field is the target of
          # the write itself.
          if field.replicated? && !allow_system_writes && doc_keys.includes?(field_name)
            errors << ValidationError.new(
              field: field_name,
              message: "is replicated and should not be set",
              code: "read_only",
            )
          end
        end

        errors
      end

      # Validates a partial update patch against a doctype definition.
      # Skips required-field checks (since the patch may only contain
      # a subset of fields), but still validates types, unknown fields,
      # and read-only constraints.
      #
      # When `allow_system_writes` is `true` (a system-driven caller such
      # as the replication handler), the `replicated?` and `read_only?`
      # write gates are bypassed so the system caller can write replica
      # and read-only fields directly. Other type / unknown-field checks
      # still apply.
      def self.validate_update(
        patch : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        allow_system_writes : Bool = false,
      ) : Array(ValidationError)
        new.validate_patch(patch, definition, allow_system_writes: allow_system_writes)
      end

      # Instance method for validate.
      def validate(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        allow_system_writes : Bool = false,
        check_readonly : Bool = true,
      ) : Array(ValidationError)
        check(document, definition, check_required: true, kind: "Document", allow_system_writes: allow_system_writes, check_readonly: check_readonly)
      end

      # Validates a partial patch (no required-field checks).
      def validate_patch(
        patch : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        allow_system_writes : Bool = false,
      ) : Array(ValidationError)
        check(patch, definition, check_required: false, kind: "Patch", allow_system_writes: allow_system_writes)
      end

      # Shared validation pipeline. `check_required` gates the required-field
      # check; `kind` names the payload in the not-an-object error
      # ("Document" for full documents, "Patch" for partial patches).
      private def check(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        check_required : Bool,
        kind : String,
        allow_system_writes : Bool,
        check_readonly : Bool = true,
      ) : Array(ValidationError)
        errors = [] of ValidationError

        doc_hash = document.as_h?
        if doc_hash.nil?
          errors << ValidationError.new(
            field: nil,
            message: "#{kind} must be a JSON object",
            code: "invalid_type",
            params: {"expected" => "a JSON object"},
          )
          return errors
        end

        doc_keys = doc_hash.keys.to_set
        defn_keys = definition.fields.keys.to_set

        check_required_fields(definition, doc_keys, errors) if check_required
        if check_readonly
          errors.concat(Validation.readonly_write_errors(document, definition, allow_system_writes))
        end
        check_reserved_fields(doc_keys, errors)
        check_server_owned_fields(doc_keys, defn_keys, errors)
        check_unknown_fields(doc_hash, doc_keys, defn_keys, errors)
        check_field_types(doc_hash, doc_keys, definition, errors)

        errors
      end

      private def check_required_fields(definition : Doctype::DoctypeDefinition, doc_keys : Set(String), errors : Array(ValidationError)) : Nil
        definition.fields.each do |field_name, field|
          if field.required && !doc_keys.includes?(field_name)
            errors << ValidationError.new(
              field: field_name,
              message: "is missing",
              code: "required",
            )
          end
        end
      end

      # System-reserved fields that cannot appear in user input.
      RESERVED_FIELDS = Set{"parent_id"}

      # Server-owned keys: identity and system-managed metadata. A body
      # carrying one as a top-level key never names user content — the
      # server assigns it — so it is rejected unless the doctype declares
      # the name as a field. This mirrors the create-path body-id guard
      # (`Create.flat_create_guards`, which refuses body `id` before this
      # validator runs) and closes the same hole on update, where the
      # patch deep-merges into `content` and the key would land there as
      # a stray field with two meanings (`content.id` junk next to
      # `meta.id` identity). Only top-level keys are checked: nested keys
      # inside declared `any`/`object` fields are user data (a hook
      # definition carries its own `id`).
      SERVER_OWNED_KEYS = %w[id doctype domain created_at updated_at]

      private def check_reserved_fields(doc_keys : Set(String), errors : Array(ValidationError)) : Nil
        doc_keys.each do |key|
          if RESERVED_FIELDS.includes?(key)
            errors << ValidationError.new(
              field: key,
              message: "is a system-reserved field and cannot be set",
              code: "reserved",
            )
          end
        end
      end

      private def check_server_owned_fields(doc_keys : Set(String), defn_keys : Set(String), errors : Array(ValidationError)) : Nil
        doc_keys.each do |key|
          next unless SERVER_OWNED_KEYS.includes?(key)
          next if defn_keys.includes?(key)

          errors << ValidationError.new(
            field: key,
            message: "is assigned by the server and cannot be set in a document body",
            code: "reserved",
          )
        end
      end

      # A lone `content` / `data` unknown key whose value is an object is
      # the classic wrapped-body mistake (F03-5). Name the fix, not just
      # the field. Every other unknown key keeps the plain message.
      WRAPPED_BODY_KEYS = %w[content data]

      private def check_unknown_fields(
        doc_hash : Hash(String, JSON::Any),
        doc_keys : Set(String),
        defn_keys : Set(String),
        errors : Array(ValidationError),
      ) : Nil
        unknown = (doc_keys - defn_keys).reject do |key|
          key.starts_with?('_') || SERVER_OWNED_KEYS.includes?(key)
        end
        # One reported unknown key only, and it must name a wrapper and
        # carry an object value — otherwise the plain message stays.
        wrapped = unknown.size == 1 && WRAPPED_BODY_KEYS.includes?(unknown.first) &&
                  !doc_hash[unknown.first]?.try(&.as_h?).nil?
        unknown.each do |key|
          errors << ValidationError.new(
            field: key,
            message: wrapped ? "is not a defined field — this looks like a wrapped body: send the fields at the top level; there is no content wrapper" : "is not a defined field",
            code: "unknown_field",
          )
        end
      end

      private def check_field_types(doc_hash : Hash(String, JSON::Any), doc_keys : Set(String), definition : Doctype::DoctypeDefinition, errors : Array(ValidationError)) : Nil
        doc_keys.each do |field_name|
          field = definition.fields[field_name]?
          next if field.nil?

          value = doc_hash[field_name]
          if value.raw.nil?
            # `null` is only valid for optional fields (= unset). A required
            # field is non-nullable, so an explicit `null` is a validation
            # error — otherwise it slips through type validation (which skips
            # nil) and reaches downstream code that may cast it unsafely
            # (e.g. `JSON::Any#as_s`), turning a bad input into a 500.
            if field.required
              errors << ValidationError.new(
                field: field_name,
                message: "cannot be null",
                code: "required",
              )
            end
            next
          end

          if field_type = field.type
            field_type.validate(value, field, field_name, errors)
          else
            errors << ValidationError.new(
              field: field_name,
              message: "has no type definition",
              code: "schema",
            )
          end
        end
      end
    end
  end
end
