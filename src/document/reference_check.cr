# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../error"
require "../validation_error"
require "./list"

module Facet
  module Document
    # Validates that reference field values point to documents the caller may
    # read and that satisfy the optional `filter` declared on the reference
    # field definition.
    #
    # The `dangling` flag on the field selects the contract:
    #
    # - `dangling: true` — the field accepts any reference value. The target
    #   doctype registration, the existence check, the filter check, and the
    #   RBAC check are all skipped. Use it for forward references that a
    #   later step fills in.
    # - `dangling: false` (default) — the target doctype must be registered,
    #   and the referenced row must exist and match the declared filter. The
    #   lookup runs under the caller's `auth_context`, so a target the caller
    #   cannot read — no read grant on the target doctype, or outside the
    #   caller's scope — is refused with the same `reference_filter_mismatch`
    #   code as a missing target. An unreadable target is indistinguishable
    #   from a missing one, so the check leaks no existence information.
    #
    # Delegates filtering to `Document::List` so that all filter semantics
    # (operator-field compatibility, computed fields, nested paths, range
    # operators, type casting) are handled in one place.
    #
    # Only checks fields whose value is non-null. Collection references check
    # each element independently.
    module ReferenceCheck
      # Checks all reference fields on the given document under the caller's
      # `auth_context`.
      #
      # `auth_context` is required on purpose: a default of
      # `RBAC::AuthContext.system` would keep the full bypass on every call
      # site that forgets to thread the caller. A system caller passes
      # `RBAC::AuthContext.system` explicitly and keeps the bypass.
      #
      # `trusted_fields` names reference fields whose value the calling route
      # owns and has already authorized — today only the deploy route's
      # `app_id`, which it takes from the URL path after gating `deploy` on
      # that exact row. Such a value is existence-checked under
      # `RBAC::AuthContext.system`: the caller proved write reach on the row
      # itself, so requiring a separate read grant on the target would refuse
      # a legitimate operator whose role carries only `deploy`.
      #
      # Returns an array of `ValidationError` (empty when all references pass).
      def self.check(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        document : JSON::Any,
        auth_context : RBAC::AuthContext,
        trusted_fields : Set(String) = Set(String).new,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        doc_hash = document.as_h?
        return errors if doc_hash.nil?

        definition.fields.each do |field_name, field_def|
          field_context = trusted_fields.includes?(field_name) ? RBAC::AuthContext.system : auth_context
          check_field(db, field_name, field_def, doc_hash, errors, field_context)
        end

        errors
      end

      # Checks a single reference field against the document. Skips fields
      # that are not references, opt out via `dangling: true`, have no value,
      # or are polymorphic (no declared target).
      private def self.check_field(
        db : DB::Connection,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        doc_hash : Hash(String, JSON::Any),
        errors : Array(ValidationError),
        auth_context : RBAC::AuthContext,
      ) : Nil
        return unless field_def.reference?
        return if field_def.dangling?

        target_doctype = field_def.qualified_doctype
        return if target_doctype.nil?

        value = doc_hash[field_name]?
        return if value.nil? || value.raw.nil?

        parts = target_doctype.split('.', 2)
        return unless parts.size == 2
        target_domain, target_doctype_name = parts

        # Verify the target doctype exists — if it is not registered,
        # the reference cannot be resolved and the value is rejected.
        target_defn = Doctype::DefinitionStore.fetch(db, target_doctype)
        if target_defn.nil?
          errors << ValidationError.new(
            field: field_name,
            message: "referenced doctype '#{target_doctype}' is not a registered doctype",
            code: "reference_target_not_found",
            params: {"value" => target_doctype},
          )
          return
        end

        # Unfiltered references verify existence only; filtered references
        # additionally verify the declared filter.
        field_filter = field_def.filter || {} of String => JSON::Any

        if field_def.collection
          check_collection_reference(db, field_name, value, target_domain, target_doctype_name, field_filter, errors, auth_context)
        else
          check_scalar_reference(db, field_name, value, target_domain, target_doctype_name, field_filter, errors, auth_context)
        end
      end

      # Checks each element of a collection reference against the filter.
      private def self.check_collection_reference(
        db : DB::Connection,
        field_name : String,
        value : JSON::Any,
        target_domain : String,
        target_doctype : String,
        field_filter : Hash(String, JSON::Any),
        errors : Array(ValidationError),
        auth_context : RBAC::AuthContext,
      ) : Nil
        arr = value.as_a?
        return if arr.nil?

        arr.each_with_index do |element, idx|
          ref_id = element.raw
          next unless ref_id.is_a?(String)
          # Dot-indexed path, matching the element convention `ArrayType`,
          # `ReferenceType#validate_collection`, and the collection args use.
          check_single_reference(db, field_name, "#{field_name}.#{idx}", target_domain, target_doctype, ref_id, field_filter, errors, auth_context)
        end
      end

      # Checks a single (non-collection) reference value against the filter.
      private def self.check_scalar_reference(
        db : DB::Connection,
        field_name : String,
        value : JSON::Any,
        target_domain : String,
        target_doctype : String,
        field_filter : Hash(String, JSON::Any),
        errors : Array(ValidationError),
        auth_context : RBAC::AuthContext,
      ) : Nil
        ref_id = value.raw
        return unless ref_id.is_a?(String)
        check_single_reference(db, field_name, field_name, target_domain, target_doctype, ref_id, field_filter, errors, auth_context)
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Checks a single reference value against the declared filter.
      # Builds a composite filter `{id__eq: <value>}` merged with the field's
      # declared filter, then calls `Document::List` under the caller's
      # context to verify the referenced document exists, matches, and is
      # readable by the caller.
      #
      # A refused lookup (no read grant on the target doctype) and an empty
      # result answer the same `reference_filter_mismatch` code: an
      # unreadable target must be indistinguishable from a missing one.
      private def self.check_single_reference(
        db : DB::Connection,
        field_name : String,
        error_path : String,
        target_domain : String,
        target_doctype : String,
        ref_id : String,
        filter : Hash(String, JSON::Any),
        errors : Array(ValidationError),
        auth_context : RBAC::AuthContext,
      ) : Nil
        # Stored reference values are fully qualified
        # (`{domain}.{Doctype}.{id}`); the `projections.id` column holds the
        # opaque id only, so strip the prefix before querying.
        opaque_id = strip_qualified_id(ref_id, target_domain, target_doctype)

        # Look the row up with the stripped id first. Some doctypes have
        # dotted opaque ids (e.g. `iam.Roles.admin`, `core.DocType` rows)
        # and content written by the seeds and the account CLI references
        # them verbatim, so the stripped form misses. On a miss, retry with
        # the verbatim value — the row id is the authoritative match (the
        # same convention `Document::DisplayName` uses).
        result = lookup_reference(db, target_domain, target_doctype, opaque_id, filter, auth_context)
        if miss?(result) && opaque_id != ref_id
          result = lookup_reference(db, target_domain, target_doctype, ref_id, filter, auth_context)
        end

        case result
        in Facet::ServiceError
          # A refused lookup is a non-disclosing miss: the message never
          # mentions permissions, so the answer matches the empty-result
          # branch below.
          errors << ValidationError.new(
            field: error_path,
            message: "referenced document '#{ref_id}' in #{target_domain}.#{target_doctype} does not exist or does not match the required filter",
            code: "reference_filter_mismatch",
          )
        in Document::List::Result
          if result.items.empty?
            errors << ValidationError.new(
              field: error_path,
              message: "referenced document '#{ref_id}' in #{target_domain}.#{target_doctype} does not exist or does not match the required filter",
              code: "reference_filter_mismatch",
            )
          end
        end
      end

      # Runs one `id__eq` + declared-filter lookup against the target doctype.
      private def self.lookup_reference(
        db : DB::Connection,
        target_domain : String,
        target_doctype : String,
        id : String,
        filter : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
      ) : Document::List::Result | Facet::ServiceError
        composite = {"id__eq" => JSON::Any.new(id)}
        filter.each do |k, v|
          composite[k] = v
        end

        # The declared reference filter is an integrity constraint, not a
        # user query: it runs against one known row, so it bypasses the
        # authored `filters` capability gate (which governs index planning
        # for user-facing list filters) and validates against the type's
        # runtime ceiling only.
        result = Document::List.call(
          db,
          target_domain,
          target_doctype,
          filters: composite,
          items_per_page: 1,
          auth_context: auth_context,
          skip_filter_capability_check: true,
        )
        # No aggregate is requested on this path, so the aggregate member of
        # `Document::List.call`'s return union never occurs. The case keeps
        # the narrow return contract and records the impossibility for the
        # compiler.
        case result
        in Document::List::Result, Facet::ServiceError
          result
        in Document::List::AggregateResult
          raise "ReferenceCheck.lookup_reference never requests an aggregate"
        end
      end

      private def self.miss?(result : Document::List::Result | Facet::ServiceError) : Bool
        result.is_a?(Document::List::Result) && result.items.empty?
      end

      # Strips the `{domain}.{Doctype}.` prefix from a stored reference
      # value to extract the opaque `projections.id`. Returns the value
      # unchanged when it is already a bare id (defensive fallback for
      # rows written before the qualified-storage contract).
      private def self.strip_qualified_id(ref_id : String, target_domain : String, target_doctype : String) : String
        prefix = "#{target_domain}.#{target_doctype}."
        return ref_id[prefix.size..] if ref_id.starts_with?(prefix)
        ref_id
      end
    end
  end
end
