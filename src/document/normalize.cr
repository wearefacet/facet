# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Document
    # Helper for normalizing document values based on their field type.
    #
    # Performs canonical-format coercions that should run *before* validation
    # and persistence (e.g. `LongTextType` rewrites `\r\n` and bare `\r`
    # to `\n` because markdown rendering does not support `\r`).
    #
    # Walks the document alongside the doctype's top-level fields, delegating
    # to each `FieldType#normalize`. Container types (`object`, `array`,
    # `dictionary`) recurse into their nested schemas themselves, so this
    # module only needs to handle the top level.
    module Normalize
      # Normalizes the given document in place according to the doctype
      # definition. Returns the same `JSON::Any` if nothing changed, or
      # a new `JSON::Any` with normalized values.
      def self.call(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        doc_hash = document.as_h?
        return document if doc_hash.nil?

        mutated = false
        new_h = {} of String => JSON::Any
        doc_hash.each do |key, value|
          if (field = definition.fields[key]?) && (field_type = field.type)
            normalized = field_type.normalize(value, field)
            mutated = true if normalized != value
            new_h[key] = normalized
          else
            new_h[key] = value
          end
        end
        mutated ? JSON::Any.new(new_h) : document
      end

      # Normalizes the arguments of a doctype action call. Walks the action
      # definition's declared args and qualifies reference-type values to
      # their fully qualified storage form (`{domain}.{Doctype}.{id}`), the
      # same contract `Normalize.call` enforces on document content. A
      # `collection: true` reference arg qualifies each array element in turn.
      #
      # A declared arg that carries a `default` and whose key the caller
      # omitted is filled with that default before validation (B-57) — the
      # Lua function sees the same `args` table whether the value was sent
      # or defaulted, and the default value is type-validated like a
      # submitted one. An explicit `null` stays null (absent-key-only,
      # mirroring `ApplyDefaults`).
      #
      # Returns the same `JSON::Any` if nothing changed, or a new `JSON::Any`
      # with normalized values.
      def self.action_args(
        args : JSON::Any,
        action_def : Doctype::ActionDefinition,
      ) : JSON::Any
        args_h = args.as_h?
        return args if args_h.nil?

        mutated = false
        new_h = {} of String => JSON::Any
        args_h.each do |key, value|
          if (arg_def = action_def.args[key]?) &&
             (field_type = arg_def.type) &&
             field_type.type_name == "reference"
            normalized = normalize_reference_arg(value, arg_def)
            mutated = true if normalized != value
            new_h[key] = normalized
          else
            new_h[key] = value
          end
        end

        action_def.args.each do |arg_name, arg_def|
          next if new_h.has_key?(arg_name)
          next unless default = arg_def.default
          new_h[arg_name] = materialize_default(default, arg_def)
          mutated = true
        end

        mutated ? JSON::Any.new(new_h) : args
      end

      # Applies the same reference qualification a submitted value gets to
      # a materialized default, so a bare-id reference default lands in
      # `args` in the qualified storage form.
      private def self.materialize_default(
        default : JSON::Any,
        arg_def : Doctype::ActionArgDefinition,
      ) : JSON::Any
        return default unless arg_def.type.type_name == "reference"
        normalize_reference_arg(default, arg_def)
      end

      # Normalizes a reference arg value. A `collection: true` arg carries a
      # JSON array; each element is qualified in turn, mirroring
      # `ArrayType#normalize`. Scalar args qualify as a single value.
      private def self.normalize_reference_arg(
        value : JSON::Any,
        arg_def : Doctype::ActionArgDefinition,
      ) : JSON::Any
        return qualify_reference_arg(value, arg_def.qualified_doctype) unless arg_def.collection

        arr = value.as_a?
        return value if arr.nil?

        mutated = false
        new_arr = [] of JSON::Any
        arr.each do |item|
          normalized = qualify_reference_arg(item, arg_def.qualified_doctype)
          mutated = true if normalized != item
          new_arr << normalized
        end
        mutated ? JSON::Any.new(new_arr) : value
      end

      # Qualifies a reference arg value using its declared target doctype.
      # Mirrors `ReferenceType#normalize`: a well-formed stateless facet URN
      # becomes its dotted storage form, already-qualified values stay
      # unchanged, bare ids get the `{declared_doctype}.` prefix, and null /
      # non-string values pass through unchanged. A malformed URN passes
      # through too — arg validation reports it.
      private def self.qualify_reference_arg(value : JSON::Any, qualified_doctype : String?) : JSON::Any
        raw = value.raw
        return value unless raw.is_a?(String)

        if raw.starts_with?("urn:")
          dotted = Doctype::ReferenceType.urn_to_storage(raw)
          return dotted ? JSON::Any.new(dotted) : value
        end

        return value if qualified_doctype.nil?
        prefix = "#{qualified_doctype}."
        return value if raw.starts_with?(prefix)
        JSON::Any.new("#{prefix}#{raw}")
      end
    end
  end
end
