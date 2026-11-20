# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # SQL-safe JSONB field identifier validation.
    #
    # Field names interpolated into `content->>'field'` SQL expressions must
    # be validated to prevent SQL injection through free-form JSONB configs
    # (e.g. `core.Domain.definition.content.context_sets`, which is field
    # type `any` and not structurally validated by `Doctype::Validation`).
    #
    # The accepted set mirrors `Doctype::Validation#validate_field_names`:
    # lower_case_with_underscores OR camelCase. Both reject digits at the
    # start and any SQL metacharacters (quotes, semicolons, spaces, hyphens).
    module Identifier
      # `^[a-z_][a-z0-9_]*$` — snake_case (allows leading underscore).
      SNAKE_CASE = /\A[a-z_][a-z0-9_]*\z/

      # `^[a-z][a-zA-Z0-9]*$` — camelCase (lowercase first letter).
      CAMEL_CASE = /\A[a-z][a-zA-Z0-9]*\z/

      # Returns true if `name` is a SQL-safe JSONB field identifier
      # (snake_case or camelCase). The reserved `$parent_id` token is
      # accepted when `allow_parent_token` is true — it reads the
      # system-managed `meta->>'parent_id'` and is never user-authored.
      def self.valid_field?(name : String, *, allow_parent_token : Bool = false) : Bool
        return true if allow_parent_token && name == "$parent_id"
        name.matches?(SNAKE_CASE) || name.matches?(CAMEL_CASE)
      end

      # Raises `ArgumentError` unless `name` is a SQL-safe JSONB field
      # identifier. `context` is included in the error message for diagnostics.
      def self.validate!(name : String, context : String, *, allow_parent_token : Bool = false) : Nil
        return if valid_field?(name, allow_parent_token: allow_parent_token)
        raise ArgumentError.new("#{context}: field name '#{name}' is not a valid SQL-safe identifier (expected lower_case_with_underscores or camelCase#{" or the reserved '$parent_id' token" if allow_parent_token})")
      end
    end
  end
end
