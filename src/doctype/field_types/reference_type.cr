# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../field_type"
require "../field_definition"
require "../operator"
require "../../util/filter_set"
require "../../document/uri"

module Facet
  module Doctype
    # Field type for a foreign key reference to another document.
    #
    # Stored values are always fully qualified: `"{domain}.{Doctype}.{id}"`.
    # The `domain.Doctype` prefix must match the field's declared `doctype`
    # target; the id portion is opaque and may itself contain `.` (the value
    # is split on the first two dots only).
    #
    # Callers may also submit the facet URN form
    # `urn:facet:{domain}:{Doctype}:{opaque}`: `#normalize` converts it to
    # the dotted storage form, so the value resolves like the equivalent
    # qualified id everywhere downstream (validation, `ReferenceCheck`,
    # links extraction, CSV). A malformed or `?state=`-pinned URN is a
    # field-level 422.
    class ReferenceType < FieldType
      register_type "reference"

      # Normalizes a reference value to its canonical qualified storage form
      # before validation and persistence.
      #
      # - `null` and non-string values pass through unchanged; `#validate`
      #   surfaces the appropriate error.
      # - A well-formed stateless facet URN (`urn:facet:hr:Employee:01ABC`)
      #   is converted to the dotted `{domain}.{Doctype}.{id}` form, so it
      #   resolves like the equivalent qualified value. A malformed or
      #   `?state=`-pinned URN passes through unchanged; `#validate`
      #   reports it.
      # - An already-qualified value (`{domain}.{Doctype}.{id}`) whose prefix
      #   matches the field's declared `doctype` is returned unchanged.
      # - A bare id (no `.` separators, or a value whose prefix does not match
      #   the field's `doctype`) is qualified by prefixing it with the field's
      #   declared `doctype` and a `.` separator. This lets API callers still
      #   send bare ULIDs while the storage layer always sees the qualified
      #   form.
      # - A two-segment value (`domain.Doctype`) is treated as a bare id when
      #   its prefix does not match the field's `doctype` — the whole string
      #   becomes the id. This matches `DocURI.parse_dotted`'s special case
      #   for `core.DocType` opaque ids.
      # - A `collection: true` field carries a JSON array: each non-null
      #   element is qualified in turn; a non-array value passes through
      #   unchanged so `#validate` reports the type error.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        return normalize_collection(value, field_definition) if field_definition.collection
        normalize_scalar(value, field_definition)
      end

      # Normalizes one collection reference field value: each array element
      # is qualified in turn, mirroring the collection handling in
      # `Normalize.action_args` (B-52) and `ArrayType#normalize`. A
      # non-array value passes through unchanged so `#validate` reports the
      # type error.
      private def normalize_collection(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        arr = value.as_a?
        return value if arr.nil?

        mutated = false
        new_arr = [] of JSON::Any
        arr.each do |element|
          next new_arr << element if element.raw.nil?
          normalized = normalize_scalar(element, field_definition)
          mutated = true if normalized != element
          new_arr << normalized
        end
        mutated ? JSON::Any.new(new_arr) : value
      end

      private def normalize_scalar(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        raw = value.raw
        return value unless raw.is_a?(String)

        # URN form → dotted storage form. A malformed or state-pinned URN
        # passes through unchanged so `#validate` reports it.
        if raw.starts_with?("urn:")
          dotted = ReferenceType.urn_to_storage(raw)
          return dotted ? JSON::Any.new(dotted) : value
        end

        target = field_definition.qualified_doctype
        # No declared target — cannot qualify; leave the value untouched so
        # `#validate` reports a schema error rather than guessing.
        return value if target.nil?

        prefix = "#{target}."
        return value if raw.starts_with?(prefix)

        # Bare id (or a prefix that does not match) — qualify with the field's
        # declared target doctype.
        JSON::Any.new("#{prefix}#{raw}")
      end

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        # A `collection: true` reference field carries a JSON array; each
        # element is validated in turn with an indexed error path, mirroring
        # `ArrayType` and the collection handling in `ReferenceCheck`,
        # `Links`, and the CSV serializer.
        if field_definition.collection
          validate_collection(value, field_definition, path, errors)
        else
          validate_scalar(value, field_definition, path, errors)
        end
      end

      # Validates one collection reference field value: the value must be a
      # JSON array, and each non-null element must be a valid scalar
      # reference. Element errors carry the `path.<idx>` convention used by
      # `ArrayType`; null elements are skipped, mirroring `ArrayType`.
      # A repeated target is rejected: the render boundary keys one capsule
      # per token, so a duplicate renders a broken list. Values are compared
      # post-normalization, when every spelling of a target has collapsed to
      # the same qualified string.
      private def validate_collection(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        arr = value.as_a?
        if arr.nil?
          errors << ValidationError.new(
            field: path,
            message: "must be an array",
            code: "invalid_type",
            params: {"expected" => "an array"},
          )
          return
        end

        seen = Set(String).new
        reported = Set(String).new
        arr.each_with_index do |element, idx|
          raw = element.raw
          next if raw.nil?
          unless raw.is_a?(String)
            validate_scalar(element, field_definition, "#{path}.#{idx}", errors)
            next
          end

          if seen.includes?(raw)
            unless reported.includes?(raw)
              errors << ValidationError.new(
                field: path,
                message: "repeats the reference target '#{raw}' — a collection reference must list each target once",
                code: "duplicate_reference_target",
              )
              reported << raw
            end
            next
          end
          seen << raw

          validate_scalar(element, field_definition, "#{path}.#{idx}", errors)
        end
      end

      private def validate_scalar(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        raw = value.raw
        if raw.nil?
          # null is a valid unset reference
          return
        end

        unless raw.is_a?(String)
          errors << ValidationError.new(
            field: path,
            message: "must be a string (qualified reference id) or null",
            code: "invalid_type",
            params: {"expected" => "a string (qualified reference id) or null"},
          )
          return
        end

        target = field_definition.qualified_doctype

        # A facet URN is accepted and checked as its dotted equivalent. A
        # value that survives normalization is malformed or state-pinned —
        # report it instead of the generic qualified-format error.
        if raw.starts_with?("urn:")
          dotted = ReferenceType.urn_to_storage(raw)
          if dotted
            raw = dotted
          else
            parsed = Document::DocURI.parse(raw)
            if parsed && parsed.state
              errors << ValidationError.new(
                field: path,
                message: "is a state-pinned URN ('#{raw}') — a reference field points at the current document; drop the '?state=' component",
                code: "invalid_reference_format",
              )
            else
              errors << ValidationError.new(
                field: path,
                message: "is not a well-formed facet document URN: '#{raw}' (expected the form urn:facet:{domain}:{Doctype}:{id})",
                code: "invalid_reference_format",
              )
            end
            return
          end
        end

        # Require the `{domain}.{Doctype}.{id}` form: split on the first two
        # dots only, so opaque ids may themselves contain `.` (c.f. the
        # `core.DocType` opaque id `hr.Employee`).
        parts = split_qualified(raw)
        if parts.nil?
          errors << ValidationError.new(
            field: path,
            message: "must be a fully qualified reference id of the form '{domain}.{Doctype}.{id}'",
            code: "invalid_reference_format",
          )
          return
        end

        # Validate the domain and doctype segments against the same character
        # classes used by `DocURI` so malformed prefixes are rejected early.
        unless Document::DocURI::DOMAIN_RE.matches?(parts[0]) &&
               Document::DocURI::DOCTYPE_RE.matches?(parts[1])
          errors << ValidationError.new(
            field: path,
            message: "reference value has an invalid domain or doctype segment",
            code: "invalid_reference_format",
          )
          return
        end

        # A field with no declared target doctype is a polymorphic reference
        # (e.g. the `target` field of a sidecar doctype). Only the qualified
        # format is checked here; whether the `{domain}.{Doctype}` prefix
        # resolves to a registered doctype is a separate concern (the storage
        # layer does not check id existence).
        if target.nil?
          return
        end

        prefix = "#{parts[0]}.#{parts[1]}"
        if prefix != target
          errors << ValidationError.new(
            field: path,
            message: "reference value prefix '#{prefix}' does not match the field's target doctype '#{target}'",
            code: "reference_doctype_mismatch",
          )
        end
      end

      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        validate_target_definition(field_definition, path, errors)
        validate_filter_definition(field_definition, path, errors)
      end

      # A reference target must be the qualified `domain.Doctype` form
      # (F02-01). A bare name is stored verbatim — `qualified_doctype`
      # never expands it — so at write time normalize prefixes every
      # submitted value with the bare name and no value can pass the
      # qualified-reference check. The field is dead until the definition
      # is repaired. Refusing the definition here keeps that state out of
      # storage. A polymorphic reference (no `doctype:` declared) stays
      # legal, and the nested sub-schema slots (array `items`, object
      # `properties`, dictionary `values`) reach this check through their
      # own recursion.
      private def validate_target_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        target = field_definition.doctype
        return if target.nil? || target.empty? || target.includes?('.')

        errors << ValidationError.new(
          field: path,
          message: "declares a bare reference target '#{target}' — use the qualified '{domain}.{Doctype}' form (for example 'identity.Person')",
          code: "schema",
        )
      end

      # Validates the optional `filter` property on a reference field.
      # Each key must follow the `field__op` convention, the field part must be
      # a non-empty identifier, the operator suffix must be a known operator,
      # and the value must be a JSON primitive (not an object or array).
      private def validate_filter_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        filter = field_definition.filter
        return if filter.nil?

        filter.each do |key, value|
          field_part, op_suffix = Util::FilterSet.parse_filter_key(key)

          if field_part.empty?
            errors << ValidationError.new(
              field: "#{path}.#{key}",
              message: "filter key '#{key}' has an empty field name",
              code: "schema",
            )
            next
          end

          # Validate the operator suffix is a known operator
          begin
            Operator.parse_suffix("__#{op_suffix}")
          rescue ArgumentError
            errors << ValidationError.new(
              field: "#{path}.#{key}",
              message: "filter key '#{key}' has unknown operator '#{op_suffix}'",
              code: "schema",
            )
            next
          end

          # Value must be a JSON primitive
          case value.raw
          when nil, String, Int64, Float64, Bool
            # OK
          else
            errors << ValidationError.new(
              field: "#{path}.#{key}",
              message: "filter value for '#{key}' must be a primitive value (string, number, boolean, or null)",
              code: "schema",
            )
          end
        end
      end

      # Splits a qualified reference value into `[domain, doctype, id]` on the
      # first two dots. Returns `nil` when the value has fewer than three
      # segments or the id segment is empty.
      private def split_qualified(value : String) : {String, String, String}?
        first = value.index('.')
        return nil unless first && first > 0
        second = value.index('.', first + 1)
        return nil unless second && second > first + 1
        id = value[(second + 1)..]
        return nil if id.empty?
        {
          value[0...first],
          value[(first + 1)...second],
          id,
        }
      end

      # Resolves a `urn:facet:` reference value to its dotted storage form
      # (`{domain}.{Doctype}.{opaque}`). Returns `nil` when the string is
      # not a facet URN, is malformed, or carries a `?state=` q-component —
      # a state-pinned URN has no qualified-form equivalent. Public because
      # `Document::Normalize.action_args` shares the same conversion rule
      # for action-arg reference values (that path has no
      # `FieldDefinition` to call the instance hook with).
      def self.urn_to_storage(raw : String) : String?
        return nil unless raw.starts_with?("urn:")
        uri = Document::DocURI.parse(raw)
        return nil if uri.nil? || uri.state
        "#{uri.domain}.#{uri.doctype}.#{uri.opaque}"
      end
    end
  end
end
