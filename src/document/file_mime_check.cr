# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../artifact/store"
require "../doctype/doctype_definition"
require "../util/mime_matcher"
require "../validation_error"

module Facet
  module Document
    # Validates that `file`-typed field values reference artifacts whose
    # `mime_type` column matches the field's declared `accept` allow-list.
    #
    # This is the runtime counterpart to `FileType#validate_definition`
    # (which only checks the schema shape). The MIME lives on the
    # `artifacts` row, set by `Artifact::Uploader` from byte-sniffing, so
    # the gate can only run at document mutation time where `db` is
    # available. `FileType#validate` (pure shape check on the ULID) runs
    # earlier in `Document::Validation`; this module runs after schema
    # validation, next to `ReferenceCheck`.
    #
    # Only fields with a non-nil `accept` are checked. A nil `accept` is
    # the default and accepts any MIME (the file's bytes are unrestricted).
    module FileMimeCheck
      # Checks every `file`-typed field that declares an `accept` list
      # against the artifact rows referenced by `document`. Returns an
      # empty array when every artifact satisfies its field's allow-list.
      def self.check(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        document : JSON::Any,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        doc_hash = document.as_h?
        return errors if doc_hash.nil?

        definition.fields.each do |field_name, field_def|
          check_field(db, field_name, field_def, doc_hash, errors)
        end

        errors
      end

      # Checks a single field's artifact MIME against its `accept` list.
      # Skips fields that are not `file`-typed, declare no `accept`, or
      # carry no value in the document.
      private def self.check_field(
        db : DB::Connection,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        doc_hash : Hash(String, JSON::Any),
        errors : Array(ValidationError),
      ) : Nil
        return unless field_def.type.try(&.type_name) == "file"

        accept = field_def.accept
        return if accept.nil? || accept.empty?

        value = doc_hash[field_name]?
        return if value.nil? || value.raw.nil?

        # A `string`-as-scalar is the only shape `FileType#validate`
        # accepts; arrays or objects fail schema validation earlier.
        artifact_id = value.as_s?
        return if artifact_id.nil? || artifact_id.empty?

        artifact = Facet::Artifact::Store.find_artifact(db, artifact_id)
        if artifact.nil?
          # The pure ULID shape check in FileType#validate has already
          # passed; a missing row here is a referential issue that the
          # artifact subsystem handles separately. We do not block the
          # mutation on this — the owner-row reconcile pass is the
          # authoritative gate for artifact provenance.
          return
        end

        return if Util::MimeMatcher.matches?(artifact.mime_type, accept)

        errors << ValidationError.new(
          field: field_name,
          message: "artifact '#{artifact_id}' has MIME '#{artifact.mime_type}' but field accepts: #{accept.join(", ")}",
          code: "invalid_mime",
        )
      end
    end
  end
end
