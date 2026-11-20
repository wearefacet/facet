# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../util/mime_matcher"

module Facet
  module Doctype
    # Field type for binary attachments.
    #
    # Stores a bare artifact id (a 26-character ULID) that references a row
    # in the `artifacts` table. The bytes themselves live in object storage
    # keyed by the artifact's `path` (see `doc/backend/artifact.md`).
    #
    # The field inherits its sensitivity tag from `FieldDefinition#tags`;
    # `FileType` itself carries no tags or extra metadata. Provenance and
    # reference tracking live in `Document::ArtifactRefs` and the artifact
    # subsystem, not here — `FileType` is a pure-type check.
    #
    # The optional `accept` allow-list (declared on `FieldDefinition`) is
    # only schema-validated here; the runtime MIME check against the
    # artifact's `mime_type` column lives in `Document::FileMimeCheck`.
    class FileType < FieldType
      register_type "file"

      # Crockford Base32 alphabet used by both the Crystal `Util::ScriptHelpers.ulid`
      # generator and the PostgreSQL `ulid()` function. A valid artifact id
      # is a 26-character string drawn from this alphabet.
      private ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
      private ULID_RE       = /^[0-9A-HJKMNP-TV-Z]{26}$/

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str = require_string(value, path, errors, suffix: "artifact id")
        return if str.nil?

        # Artifact ids are ULIDs; the artifact subsystem mints them at upload
        # time. We validate only the shape here — a referential check against
        # `artifacts` would be circular with the upload route that creates ids.
        unless str.matches?(ULID_RE)
          errors << ValidationError.new(
            field: path,
            message: "must be a 26-character ULID (Crockford Base32: #{ULID_ALPHABET})",
            code: "invalid_format",
            params: {"value" => str, "format" => "a 26-character artifact id (ULID)"},
          )
        end
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        # Validate the optional `accept` MIME allow-list. Each entry must
        # match `type/subtype` where only the subtype may be `*`. A bare
        # `*` (accept anything) is intentionally absent — omit `accept`
        # to allow any MIME, which is the same semantic and avoids a
        # confusing synonym.
        accept = field_definition.accept
        return if accept.nil?

        accept.each do |pattern|
          unless Util::MimeMatcher.valid_pattern?(pattern)
            errors << ValidationError.new(
              field: "#{path}.accept",
              message: "invalid MIME pattern '#{pattern}' (expected 'type/subtype', subtype may be '*')",
              code: "invalid_format",
            )
          end
        end
      end
    end
  end
end
