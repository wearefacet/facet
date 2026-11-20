# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../util/past_tense_inflector"
require "./yaml_helper"
require "./definition_error"

module Facet
  module Doctype
    # Describes a single action in a doctype definition.
    #
    # An action maps to a Lua export function with the same name as the action
    # key. The function receives `(ctx, args)` and may mutate `ctx.root`.
    #
    # ## Args
    #
    # **args** — parameter definitions used for preflight validation before
    # the Lua function is invoked.
    #
    # ## Event name
    #
    # **event_name** — optional override for the event name that describes this
    # action. When omitted, the event name is derived by inflecting the action
    # key to past tense via `PastTenseInflector`.
    #
    # ## State gate
    #
    # **states** — optional gate that limits the action to some document states:
    # an object keyed by content field name, each mapping to the list of values
    # the field must carry for the action to be available. An action without
    # `states` is available in every state. The gate is a plain whitelist — the
    # Lua script stays the owner of the domain logic; this only stops a call
    # that cannot legitimately run (B-323).
    struct ActionDefinition
      # Argument definitions for preflight validation.
      getter args : Hash(String, ActionArgDefinition) = {} of String => ActionArgDefinition

      # Optional explicit event name. When `nil`, the event name is derived
      # by inflecting the action key to past tense.
      getter event_name : String?

      # Optional human-readable description. Presentation metadata the
      # builder's action editor edits and displays; carried through the
      # round-trip so a REST save never silently loses it.
      getter description : String?

      # Optional state gate: field name → values the field must carry for
      # the action to be available. `nil` means no gate.
      getter states : Hash(String, Array(String))?

      # Regex for valid event names — must be lowercase `snake_case`.
      EVENT_NAME_RE = /^[a-z][a-z0-9_]*$/

      # Top-level keys `from_json` reads on an action entry. Any other key
      # is rejected at parse time — a silently dropped key would store a
      # definition that no longer matches what the author wrote while the
      # call still answered success (B-13).
      KNOWN_KEYS = %w[args event_name description states]

      def initialize(
        @args : Hash(String, ActionArgDefinition) = {} of String => ActionArgDefinition,
        @event_name : String? = nil,
        @description : String? = nil,
        @states : Hash(String, Array(String))? = nil,
      )
      end

      # Returns whether the document content satisfies the state gate. An
      # action without `states` is available in every state. Every gated
      # field must carry a listed value in the current content; a missing
      # field or a non-string value counts as "not in state".
      def state_allowed?(content : JSON::Any) : Bool
        states = @states
        return true unless states
        states.all? do |field, values|
          value = content[field]?.try(&.as_s?)
          !value.nil? && values.includes?(value)
        end
      end

      # Returns the event name for this action.
      #
      # If `event_name` is set explicitly, returns it as-is. Otherwise,
      # derives the past-tense inflection of the action key via
      # `PastTenseInflector`.
      #
      # ```
      # action = ActionDefinition.new
      # action.resolved_event_name("approve_document") # => "document_approved"
      #
      # action = ActionDefinition.new(event_name: "document_approved_by_supervisor")
      # action.resolved_event_name("approve_document") # => "document_approved_by_supervisor"
      # ```
      def resolved_event_name(action_key : String) : String
        @event_name || begin
          inflector = ::Facet::Util::PastTenseInflector.new
          inflector.inflect_past(action_key)
        end
      end

      # Parse from a parsed JSON::Any value. `path` names the action for
      # error messages (e.g. `action 'approve'`); callers outside a
      # definition body omit it.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "action definition"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        args_val = {} of String => ActionArgDefinition
        if args_raw = h["args"]?
          args_h = args_raw.as_h?
          unless args_h
            raise DefinitionError.new(
              "#{label}.args must be an object keyed by argument name (got #{StrictKeys.json_kind(args_raw)})"
            )
          end
          args_h.each do |arg_name, arg_raw|
            args_val[arg_name] = ActionArgDefinition.from_json(arg_raw, "#{label}.args.#{arg_name}")
          end
        end

        event_name_val = optional_string(h, "event_name", label)
        if event_name_val && !event_name_val.matches?(EVENT_NAME_RE)
          raise DefinitionError.new(
            "event_name must be lowercase snake_case (got: '#{event_name_val}')"
          )
        end

        description_val = optional_string(h, "description", label)

        states_val = parse_states(h["states"]?, label)

        new(args: args_val, event_name: event_name_val, description: description_val, states: states_val)
      end

      # Same optional-text doctrine as the field parser: absent or empty →
      # nil, wrong type → 422. The raising `as_s` used for `event_name`
      # previously escaped as a 500.
      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      # Parses the optional `states` gate. The value must be an object keyed
      # by content field name, each mapping to a non-empty array of non-empty
      # strings. `nil` input means no gate.
      private def self.parse_states(raw : JSON::Any?, label : String) : Hash(String, Array(String))?
        return nil unless raw
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label}.states must be an object keyed by field name (got #{StrictKeys.json_kind(raw)})"
          )
        end
        if h.empty?
          raise DefinitionError.new(
            "#{label}.states must name at least one field"
          )
        end
        parsed = {} of String => Array(String)
        h.each do |field, values_raw|
          if field.empty?
            raise DefinitionError.new("#{label}.states: field name must not be empty")
          end
          values_arr = values_raw.as_a?
          unless values_arr
            raise DefinitionError.new(
              "#{label}.states.#{field} must be an array of strings (got #{StrictKeys.json_kind(values_raw)})"
            )
          end
          values = [] of String
          values_arr.each do |v|
            s = v.as_s?
            if s.nil? || s.empty?
              raise DefinitionError.new(
                "#{label}.states.#{field} must contain only non-empty strings"
              )
            end
            values << s
          end
          if values.empty?
            raise DefinitionError.new(
              "#{label}.states.#{field} must list at least one value"
            )
          end
          parsed[field] = values
        end
        parsed
      end

      # Parse from a raw JSON string.
      def self.from_json(string : String) : self
        from_json(JSON.parse(string))
      end

      # Parse from a raw YAML string.
      Doctype.yaml_entrypoint

      # ── JSON serialisation ──────────────────────────────────────────

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("args") do
            builder.object do
              @args.each do |name, arg|
                builder.field(name, arg)
              end
            end
          end

          if e = @event_name
            builder.field("event_name", e)
          end

          if d = @description
            builder.field("description", d)
          end

          if s = @states
            builder.field("states") do
              builder.object do
                s.each do |field, values|
                  builder.field(field) do
                    builder.array do
                      values.each { |v| builder.string(v) }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # Describes a single argument in an action definition.
    #
    # This is a leaner version of `FieldDefinition` — it only carries the
    # properties needed for preflight validation of action parameters:
    # type, required, default, enum values, min/max constraints, and
    # reference target information.
    struct ActionArgDefinition
      # The expected type of the argument — an instance of a FieldType subclass.
      getter type : FieldType

      # Whether the argument is required.
      getter required : Bool = false

      # Default value if the argument is not provided.
      getter default : JSON::Any?

      # For `Enum` type — the closed set of allowed string values.
      getter values : Array(String)?

      # Minimum value (Integer / Datetime / Money) or minimum length in
      # characters (`string` args).
      getter min : Int64?

      # Maximum value (Integer / Datetime / Money) or maximum length in
      # characters (`string` args).
      getter max : Int64?

      # For `Reference` type — the target doctype identifier.
      getter doctype : String?

      # Returns the target doctype identifier for reference args, mirroring
      # `FieldDefinition#qualified_doctype` so the same normalization path
      # can run against action arguments and field definitions.
      def qualified_doctype : String?
        @doctype
      end

      # Whether the argument is a collection (array of the specified type).
      getter collection : Bool = false

      # Top-level keys `from_json` reads on an action argument entry (B-13).
      KNOWN_KEYS = %w[type required default values min max doctype collection]

      def initialize(
        @type : FieldType,
        @required : Bool = false,
        @default : JSON::Any? = nil,
        @values : Array(String)? = nil,
        @min : Int64? = nil,
        @max : Int64? = nil,
        @doctype : String? = nil,
        @collection : Bool = false,
      )
      end

      # Parse from a parsed JSON::Any value. `path` names the argument for
      # error messages (e.g. `action 'approve'.args.note`); callers outside
      # a definition body omit it.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "action argument definition"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        type_raw = h["type"]?
        if type_raw.nil?
          raise DefinitionError.new("#{label}: Missing required field 'type'")
        end
        unless type_str = type_raw.as_s?
          raise DefinitionError.new(
            "#{label}: 'type' must be a string type name (got #{StrictKeys.json_kind(type_raw)})"
          )
        end
        field_type = parse_field_type(type_str, label)

        new(
          type: field_type,
          required: optional_bool(h, "required", label) || false,
          default: h["default"]?,
          values: optional_string_array(h, "values", label),
          min: optional_int(h, "min", label),
          max: optional_int(h, "max", label),
          doctype: optional_string(h, "doctype", label),
          collection: optional_bool(h, "collection", label) || false
        )
      end

      # Same doctrine as the field parser: absent or empty string → nil,
      # wrong type → 422 — for strings, booleans, integers, and string
      # arrays alike. The raising `as_bool` / `as_i64` / `as_a` / `as_s`
      # casts used here previously escaped as a 500.
      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      private def self.optional_bool(h : Hash(String, JSON::Any), key : String, label : String) : Bool?
        value = h[key]?
        return nil if value.nil?
        flag = value.as_bool?
        if flag.nil?
          raise DefinitionError.new("#{label}: '#{key}' must be a boolean (got #{StrictKeys.json_kind(value)})")
        end
        flag
      end

      private def self.optional_int(h : Hash(String, JSON::Any), key : String, label : String) : Int64?
        value = h[key]?
        return nil if value.nil?
        unless number = value.as_i64?
          raise DefinitionError.new("#{label}: '#{key}' must be an integer (got #{StrictKeys.json_kind(value)})")
        end
        number
      end

      private def self.optional_string_array(h : Hash(String, JSON::Any), key : String, label : String) : Array(String)?
        value = h[key]?
        return nil if value.nil?
        unless arr = value.as_a?
          raise DefinitionError.new("#{label}: '#{key}' must be an array of strings (got #{StrictKeys.json_kind(value)})")
        end
        arr.map do |entry|
          unless text = entry.as_s?
            raise DefinitionError.new("#{label}: '#{key}' must contain only strings (got #{StrictKeys.json_kind(entry)})")
          end
          text
        end
      end

      # Parse from a raw JSON string.
      def self.from_json(string : String) : self
        from_json(JSON.parse(string))
      end

      # Parse from a raw YAML string.
      Doctype.yaml_entrypoint

      # Resolves the declared type name through the type registry. An
      # unknown name is an authoring mistake of the same class as on the
      # field surface — it answers the 422 channel (`DefinitionError`)
      # instead of escaping the create / update services as a 500
      # `ArgumentError` (B-58, the B-37 wrapper on the args surface). The
      # registry message already names the offender and the known types.
      private def self.parse_field_type(type_str : String, label : String) : FieldType
        FieldType.parse(type_str)
      rescue ex : ArgumentError
        raise DefinitionError.new("#{label}: #{ex.message}")
      end

      # ── JSON serialisation ──────────────────────────────────────────

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("type", @type)
          builder.field("required", @required)

          if d = @default
            builder.field("default", d)
          end

          if v = @values
            builder.field("values") do
              builder.array do
                v.each { |s| builder.string(s) }
              end
            end
          end

          if m = @min
            builder.field("min", m)
          end

          if m = @max
            builder.field("max", m)
          end

          if d = @doctype
            builder.field("doctype", d)
          end

          builder.field("collection", @collection)
        end
      end
    end
  end
end
