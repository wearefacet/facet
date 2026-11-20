# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../util/time_helper"
require "../error"

module Facet
  module Doctype
    # Base class for all field types in the doctype system.
    #
    # Each concrete subclass knows:
    # - its own type‑specific data (e.g. `EnumType` holds `values`)
    # - how to validate a document value (document‑level)
    # - how to validate its own definition (schema‑level)
    # - how to serialise to / deserialise from JSON
    abstract class FieldType
      # ── Registry ──────────────────────────────────────────────────────

      # Maps a lowercase type name (e.g. `"string"`, `"longtext"`) to its
      # concrete class factory. Populated automatically when subclasses
      # call the `register_type` macro in their body.
      @@registry = {} of String => Proc(FieldType)

      # Each subclass must implement this to return its type name.
      abstract def type_name : String

      # ── Macros ────────────────────────────────────────────────────────

      # Register a concrete subclass under the given type name and define
      # its `type_name` method from the same string. This macro expands in
      # the subclass body, so `@type` refers to the concrete class, avoiding
      # abstract instantiation errors.
      macro register_type(name)
        ::Facet::Doctype::FieldType.__register({{name.id.stringify}}, ->{ {{ @type }}.new.as(::Facet::Doctype::FieldType) })
        def type_name : String
          {{name.id.stringify}}
        end
      end

      # ── Class methods ─────────────────────────────────────────────────

      # Parse a type from its lowercase string name.
      # Raises `ArgumentError` for unknown type names.
      def self.parse(value : String) : FieldType
        factory = @@registry[value.downcase]?
        if factory.nil?
          known = @@registry.keys.sort!.join(", ")
          raise ArgumentError.new("Unknown field type: #{value.inspect} (known types: #{known})")
        end
        factory.call
      end

      # Register a concrete subclass under a given type name. The factory
      # proc (built by `register_type`) resolves `new` against the concrete
      # class, so subclasses may declare any `initialize` signature.
      # Called via `register_type` macro from subclass bodies.
      def self.__register(name : String, factory : Proc(FieldType)) : Nil
        @@registry[name] = factory
      end

      # Filter capabilities permitted on fields of this type. The default
      # is empty: only types that support filters override it, and only
      # those types get the `validate_definition` capability check.
      def self.allowed_capabilities : Array(FilterCapability)
        [] of FilterCapability
      end

      # ── Instance methods — override in subclasses ─────────────────────

      # Validate a document value against this type.
      # Appends structured errors to the given array (empty array means valid).
      abstract def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil

      # Validate schema‑level constraints for this field type.
      # Called during Doctype::Validation. A type opts in to the filter
      # capability check by declaring a non‑empty `allowed_capabilities`
      # list; the base then validates the authored `filters:` against it.
      # The types that keep the empty default skip this check —
      # `Doctype::Validation` covers them through
      # `FilterCapability#valid_for?`. Types with more schema constraints
      # override this method; call `super` to keep the capability check.
      def validate_definition(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        return if self.class.allowed_capabilities.empty?
        validate_filter_capabilities(field_definition, path, errors)
      end

      # Normalizes a document value before validation and persistence.
      # Default implementation is identity; types that need canonical
      # formatting (e.g. `LongTextType` rewriting `\r\n` → `\n`)
      # override it.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        value
      end

      # Shared helper: normalizes an ISO‑8601 datetime string (with a
      # timezone offset or `Z`) to its UTC RFC‑3339 form.
      #
      # Crystal's `Time.parse_iso8601` rejects tz‑naive datetime strings
      # ("2025-01-15T10:30:00" raises `Time::Format::Error`), so every
      # accepted input carries an explicit offset and `.to_utc` is a lossless
      # conversion. Returns `nil` if `value` is not a parseable string; the
      # caller decides whether to fall through to `validate` for the error
      # message or skip silently.
      protected def normalize_iso8601_to_utc(value : JSON::Any) : JSON::Any?
        str_val = value.as_s?
        return nil unless str_val

        normalized = Util::TimeHelper.to_utc_rfc3339(str_val)
        normalized ? JSON::Any.new(normalized) : nil
      end

      # Equality — two FieldType instances are equal if they share the same
      # type name (i.e. same subclass).
      def ==(other : self) : Bool
        type_name == other.type_name
      end

      # Serialise the type to a JSON string (the lowercase type name).
      def to_json(builder : JSON::Builder) : Nil
        builder.string(type_name)
      end

      # ── Shared helpers ───────────────────────────────────────────────

      # Appends a "must be a string" type error for *value* when it is not a
      # JSON string, and returns `nil`. Returns the string when it is one.
      # *suffix* extends the message in parentheses; *code* overrides the
      # error code (the secret markers use "invalid_format"). Keeps the
      # per-type "not a string" guards in one place.
      protected def require_string(
        value : JSON::Any,
        path : String,
        errors : Array(ValidationError),
        *,
        suffix : String? = nil,
        code : String = "invalid_type",
      ) : String?
        str = value.as_s?
        if str.nil?
          message = suffix ? "must be a string (#{suffix})" : "must be a string"
          errors << ValidationError.new(
            field: path,
            message: message,
            code: code,
            params: {"expected" => suffix ? "a string (#{suffix})" : "a string"},
          )
        end
        str
      end

      # Shared schema-level check of the field's declared `filters:` against
      # the type's `allowed_capabilities`. Types that support filters keep a
      # one-line `validate_definition` that calls this; every other type
      # keeps its own `validate_definition` or the base no-op. The message
      # names the type and the valid capability list, so a new capability
      # only needs the `allowed_capabilities` override.
      protected def validate_filter_capabilities(
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        caps = field_definition.filters
        return if caps.nil? || caps.empty?

        allowed = self.class.allowed_capabilities
        valid = allowed.map(&.to_s_lowercase).join(", ")
        caps.each do |cap|
          next if allowed.includes?(cap)
          errors << ValidationError.new(
            field: path,
            message: "(#{type_name}): filter capability '#{cap.to_s_lowercase}' is not allowed — valid capabilities are #{valid}",
            code: "schema",
          )
        end
      end

      # Validates a string value against a field's pattern constraint.
      protected def validate_pattern(
        field_definition : FieldDefinition,
        path : String,
        value : String,
        errors : Array(ValidationError),
        pattern_str : String,
      ) : Nil
        flags = field_definition.pattern_flags || ""
        options = pattern_flags_to_options(flags)
        begin
          regex = Regex.new(pattern_str, options)
          unless value.matches?(regex)
            errors << ValidationError.new(
              field: path,
              message: "does not match pattern '#{pattern_str}'",
              code: "invalid_format",
              params: {"value" => value, "format" => "a match for pattern '#{pattern_str}'"},
            )
          end
        rescue ex
          errors << ValidationError.new(
            field: path,
            message: "has an invalid pattern '#{pattern_str}': #{ex.message}",
            code: "invalid_format",
          )
        end
      end

      # Converts pattern flag characters to Regex::Options.
      protected def pattern_flags_to_options(flags : String) : Regex::Options
        options = Regex::Options::None
        flags.each_char do |c|
          case c
          when 'i' then options |= Regex::Options::IGNORE_CASE
          when 'm' then options |= Regex::Options::MULTILINE
          when 'x' then options |= Regex::Options::EXTENDED
          else
          end
        end
        options
      end
    end

    # Shared scaffold for the two range field types (`period`,
    # `dateperiod`). Both store a `{start, end}` JSON object with both
    # bounds required, and both declare the same `equality` + `interval`
    # capability set. This class walks the shared check sequence — object
    # shape, both bounds present, both bounds strings, parse, ordering —
    # while a subclass supplies its bound parser and its ordering rule.
    # Both bounds use the `[)`, `[]` or other bounds convention only in
    # the wording of the messages, so those stay in the subclass too.
    abstract class RangeType < FieldType
      @range_object_message : String
      @bound_suffix : String
      @order_violation_message : String

      def initialize(@range_object_message, @bound_suffix, @order_violation_message)
      end

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        obj = value.as_h?
        unless obj
          errors << ValidationError.new(
            field: path,
            message: @range_object_message,
            code: "invalid_type",
            params: {"expected" => "an object with 'start' and 'end'"},
          )
          return
        end

        start_raw = obj["start"]?
        end_raw = obj["end"]?

        if start_raw.nil? || end_raw.nil?
          errors << ValidationError.new(
            field: path,
            message: "must specify both 'start' and 'end'",
            code: "required",
          )
          return
        end

        start_str = require_string(start_raw, "#{path}.start", errors, suffix: @bound_suffix)
        end_str = require_string(end_raw, "#{path}.end", errors, suffix: @bound_suffix)
        return if start_str.nil? || end_str.nil?

        start_bound = parse_bound(start_str, path, "start", errors)
        end_bound = parse_bound(end_str, path, "end", errors)
        return if start_bound.nil? || end_bound.nil?

        unless in_order?(start_bound, end_bound)
          errors << ValidationError.new(
            field: path,
            message: @order_violation_message,
            code: "out_of_range",
            params: {"reason" => @order_violation_message},
          )
        end
      end

      # Filter capabilities permitted on both range types. `equality` is
      # range equality; `interval` adds the GiST range operators
      # (`contains`, `overlaps`, `within`).
      def self.allowed_capabilities : Array(FilterCapability)
        [FilterCapability::Equality, FilterCapability::Interval]
      end

      # Parses one bound string. Appends a structured error and returns
      # `nil` when the string does not match the type's grammar.
      protected abstract def parse_bound(
        str : String,
        path : String,
        bound : String,
        errors : Array(ValidationError),
      ) : Time?

      # Returns `true` when the two parsed bounds form a valid range.
      protected abstract def in_order?(start : Time, end_bound : Time) : Bool
    end
  end
end
