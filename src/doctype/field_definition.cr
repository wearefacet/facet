# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./yaml_helper"
require "./enum_value"
require "./filter_capability"
require "./definition_error"

module Facet
  module Doctype
    # Describes a single field in a doctype definition.
    #
    # A field may be:
    # - a **primitive value**  (`String`, `Integer`, `Boolean`, …)
    # - a **computed value**   (`Data` – driven by a Lua script)
    # - a **reference**        (`Reference` – FK to another document)
    #
    # When `type` is omitted but `doctype` is present, the field is
    # implicitly a `Reference`.
    class FieldDefinition
      # ── Identity / type ────────────────────────────────────────────────

      # The field type. If `nil` and `doctype` is set, treated as Reference.
      # An instance of a FieldType subclass, not an enum value.
      getter type : FieldType?

      # When type is `Enum`, the closed set of allowed values.
      getter values : Array(EnumValue)?

      # When type is `Array`, the element type descriptor.
      getter items : FieldDefinition?

      # When type is `Object` and `properties` is set, the inline sub‑schema.
      getter properties : Hash(String, FieldDefinition)?

      # When type is `Dictionary`, the value type descriptor (keys are always strings).
      getter dictionary_value : FieldDefinition?

      # When type is `Child` or `Reference`, the target doctype identifier.
      # A reference target must be the qualified `domain.Doctype` form
      # (e.g. `"catalog.Product"`, `"hr.Employee"`) — the authoring gate
      # rejects a bare name (F02-01); a child target stays a bare
      # same-domain name.
      getter doctype : String?

      # When type is `File`, an optional allow-list of MIME type patterns
      # (e.g. `["image/*", "application/pdf"]`). Each entry is `"type/subtype"`
      # where the subtype may be `*`. Enforced by `FileMimeCheck` on create
      # and update against the artifact's `mime_type` column. Default
      # (when absent) accepts any MIME.
      getter accept : Array(String)?

      # ── Constraints ────────────────────────────────────────────────────

      # Whether the field is required (default: false).
      getter required : Bool = false

      # Whether the field must be unique across all documents of this doctype.
      getter unique : Bool = false

      # Default value for the field (applied on create if not provided).
      getter default : JSON::Any?

      # Minimum value (Integer / Datetime / Money) or minimum length in
      # characters (`string` / `longtext`). Enforced by the field type's
      # `validate`.
      getter min : Int64?

      # Maximum value (Integer / Datetime / Money) or maximum length in
      # characters (`string` / `longtext`). Enforced by the field type's
      # `validate`.
      getter max : Int64?

      # Currency ticker (for Money fields).
      getter currency : String?

      # Display precision for a numeric field — the number of decimal
      # places the frontend renders (e.g. `0` for whole-unit money).
      # Presentation only: it never gates a schema version (see
      # `Doctype::Structure`) and never constrains the stored value.
      getter precision : Int64?

      # ── Collection flag ─────────────────────────────────────────────────

      # Whether the field value is a collection (array). Used by `Reference`
      # and `ActionArgDefinition` fields.
      getter collection : Bool = false

      # ── Data (computed) ────────────────────────────────────────────────

      # For `Data` fields – the name of the Lua compute function.
      getter compute : String?

      # For `Data` fields – list of field names whose changes should
      # trigger re‑computation.
      getter compute_when : Array(String)?

      # ── Replication ────────────────────────────────────────────────

      # For replicated fields – configuration for cross-domain field
      # replication. When set, the field is read-only and populated
      # by the replication system from a source document.
      getter replicate : ReplicateConfig?

      # Behaviour when the source record is deleted.
      # - `"keep"`:  keep the last replicated value (tombstone-style, default)
      # - `"unset"`: unset the field
      getter on_source_delete : String = "keep"

      # ── Reference‑specific ─────────────────────────────────────────────

      # Whether the reference is owned (default: true for inline doctype,
      # false for entries in the `references` section).
      getter owned : Bool?

      # When type is `Reference`, an optional filter that the referenced
      # document must satisfy. Keys use the same `field__op` convention as
      # list filters (e.g. `{"status_eq" => "active"}`). At create/update
      # time, the system calls `Document::List` on the target doctype with
      # `{id_eq: <value>}` merged with this filter to confirm the reference
      # points to a matching document.
      getter filter : Hash(String, JSON::Any)?

      # When `true`, the field accepts any reference value. The
      # authoring-time checks in `Document::ReferenceCheck` are all skipped:
      # the target doctype registration check, the existence check, the
      # declared `filter` check, and the RBAC check. The value may point at a
      # document that does not exist yet, or at a document the caller cannot
      # read — e.g. a forward reference filled in by a later step.
      #
      # When `false` (default, fail closed), `Document::ReferenceCheck`
      # verifies the target doctype is registered, and that the row exists and
      # matches the declared `filter`, using the caller's read token. A target
      # the caller cannot read answers the same error as a missing one.
      getter dangling : Bool = false

      # ── Presentation metadata ──────────────────────────────────────────

      # Human‑readable label for the field (e.g. "Email Address").
      getter title : String?

      # Human‑readable description for the field (e.g. "The user's primary email").
      getter description : String?

      # ── Input / output access control ──────────────────────────────────

      # When true, the field is accepted in input but stripped before
      # persistence. The Lua script can read it during create/update/action
      # (e.g. for password hashing).
      getter write_only : Bool = false
      # When true, the field is stored in the document but **rejected** if
      # provided in user input. Only the Lua script can set it.
      getter read_only : Bool = false

      # ── Sensitivity / sharing tags ──────────────────────────────────────

      # Free-form sensitivity tags on the field. Two consumers share the
      # label set:
      # - RBAC field visibility: a field is emitted only when the caller's
      #   role `visible_tags` cover every tag (untagged fields require only
      #   the `default` tag, which every role has unless narrowed).
      # - Cross-domain grants (`core.DomainGrant`): a grant's resource entry
      #   names tags; a field flows when any of its tags matches. Untagged
      #   fields resolve to `["default"]` there — a grant naming `default`
      #   reaches every untagged field.
      # When empty / nil the field carries no explicit label (resolved to
      # `["default"]` by both consumers).
      getter tags : Array(String)?

      # ── Pattern (regex) validation ──────────────────────────────────────

      # A regular expression pattern that string / longtext values must match.
      getter pattern : String?

      # Flags for the regex pattern (e.g. "i" for case-insensitive).
      getter pattern_flags : String?

      # ── Secret fields ─────────────────────────────────────────────────

      # The semantic mode of a `secret` field — `hash`, `sealed`, or `token`.
      # Parsed for every field but only meaningful on `secret` leaves, where
      # `SecretType#validate_definition` enforces it (required, closed enum).
      # Selects the consumer operation of the stored slot (verify / reveal /
      # consume) — never an algorithm choice.
      getter mode : String?

      # Validity window in seconds for a `token`-mode secret. Applied when
      # the staged handle is adopted: the slot row expires at
      # `now + ttl_seconds`, and `consume` checks the TTL in the same
      # statement. Required for `token`, forbidden on `hash` / `sealed`.
      getter ttl_seconds : Int64?

      # ── Filter capabilities (authoring) ────────────────────────────────

      # The filter capabilities declared by the doctype author. Each
      # capability expands to a family of runtime `Operator`s and to a
      # physical index family; the user never authors raw operators.
      # Drives both index creation (`Index::Manager`) and the derived
      # `#operators` getter below.
      getter filters : Array(FilterCapability)?

      # The derived runtime operator set — the URL / query-suffix
      # vocabulary consumed by `Document::List` clause builders and
      # `FilterSet`. Computed as the union of each `FilterCapability#operators`
      # family, de-duplicated and sorted by `Operator` declaration order.
      # Returns the empty array when no `filters` are declared — a field
      # without a capability has no index and is not filterable.
      #
      # Two type-specific supplements ride the same btree as `eq`:
      # - `in` on enum fields (set membership over the stored key);
      # - `ne` on boolean and reference fields (the "is not" half of a
      #   two-state / pointer field).
      # Both are added only when `eq` is present, so a field that declares
      # only `text_search` does not advertise an unindexed equality form.
      #
      # The union is then intersected with the type's runtime ceiling
      # (`Doctype.supported_operators`) — the same routing
      # `Document::FilterCompiler` validates against — so the metadata never
      # advertises an operator the backend would answer 422 (`comparison`
      # fans out to `ne` on money fields, but the money builder does not
      # serve it).
      #
      # Exposed (read-only) so AI / introspection surfaces and frontend
      # runtime filter consumers can read the resolved operator set
      # without re-deriving it from the capability map.
      def operators : Array(Operator)
        caps = @filters
        return [] of Operator if caps.nil? || caps.empty?

        seen = Set(Operator).new
        ops = [] of Operator
        caps.each do |cap|
          cap.operators.each do |op|
            next if seen.includes?(op)
            seen << op
            ops << op
          end
        end
        if seen.includes?(Operator::Eq)
          ops << Operator::In if enum_type? && !seen.includes?(Operator::In)
          if (boolean_type? || reference?) && !seen.includes?(Operator::Ne)
            ops << Operator::Ne
          end
        end
        ceiling = Doctype.supported_operators(@type.try(&.type_name))
        ops.select! { |op| ceiling.includes?(op.to_s.underscore) }
        sort_operators_by_declaration(ops)
      end

      # True when the field's declared type is `enum`.
      private def enum_type? : Bool
        @type.try(&.type_name) == "enum"
      end

      # True when the field's declared type is `boolean`.
      private def boolean_type? : Bool
        @type.try(&.type_name) == "boolean"
      end

      # Sorts an operator array by `Operator` enum declaration order
      # (i.e. by the underlying integer value). Crystal enums compare by
      # value, so `sort` yields declaration order. Used by `#operators` so
      # the derived set is stable regardless of which capabilities the
      # author declared or in what order.
      private def sort_operators_by_declaration(ops : Array(Operator)) : Array(Operator)
        ops.sort { |a, b| a.value <=> b.value }
      end

      # ── JSON helpers ──────────────────────────────────────────────────

      # Top-level keys `from_json` reads on a field entry. Any other key is
      # rejected at parse time (surfaces as a 422 on create and update) —
      # a typo'd constraint key (`reqired` instead of `required`) must not
      # silently store a definition that lacks the constraint (B-13).
      # `values` serves both `enum` (a list of entries) and `dictionary`
      # (the value definition). `operators` is the derived member the
      # struct writer emits (see `DerivedOperators`) — accepted on read so
      # round-tripped and stamped content re-parses, never stored: the
      # `operators` getter re-derives it from `filters`.
      KNOWN_KEYS = %w[
        type values items properties doctype required unique default min max
        collection compute compute_when replicate on_source_delete accept
        title description write_only read_only owned filter dangling tags
        pattern pattern_flags mode ttl_seconds filters currency precision
        operators
      ]

      # Parse from a raw JSON string.
      def self.from_json(string : String) : self
        from_json(JSON.parse(string))
      end

      # Parse from a raw YAML string.
      Doctype.yaml_entrypoint

      # Parse from a parsed JSON::Any value. `path` is the bare dotted
      # field path for error messages (e.g. `address.properties.city`);
      # callers outside a definition body omit it.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = field_label(path)
        raw_h = raw.as_h?
        unless raw_h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(raw_h, KNOWN_KEYS, label)

        type_str = parse_type_name(raw, label)
        doctype_str = optional_string(raw, "doctype", label)

        raw["operators"]?.try { |v| validate_operators(v, label) }

        field_type, enum_values, dict_value_def = parse_type_and_values(raw, type_str, doctype_str, path, label)

        if field_type.nil? && doctype_str.nil?
          raise DefinitionError.new(
            "#{label}: a field must declare a 'type' (or a 'doctype' reference target)"
          )
        end

        new(
          type: field_type,
          values: enum_values,
          doctype: doctype_str,
          required: optional_bool(raw, "required", label) || false,
          unique: optional_bool(raw, "unique", label) || false,
          default: raw["default"]?,
          min: optional_int(raw, "min", label),
          max: optional_int(raw, "max", label),
          collection: optional_bool(raw, "collection", label) || false,
          compute: optional_string(raw, "compute", label),
          compute_when: optional_string_array(raw, "compute_when", label),
          replicate: raw["replicate"]?.try { |v| ReplicateConfig.from_json(v, "#{label}.replicate") },
          on_source_delete: optional_string(raw, "on_source_delete", label) || "keep",
          accept: optional_string_array(raw, "accept", label),
          title: optional_string(raw, "title", label),
          description: optional_string(raw, "description", label),
          write_only: optional_bool(raw, "write_only", label) || false,
          read_only: optional_bool(raw, "read_only", label) || false,
          owned: optional_bool(raw, "owned", label),
          filter: optional_object(raw, "filter", label),
          dangling: optional_bool(raw, "dangling", label) || false,
          tags: optional_string_array(raw, "tags", label),
          pattern: optional_string(raw, "pattern", label),
          pattern_flags: optional_string(raw, "pattern_flags", label),
          mode: optional_string(raw, "mode", label),
          ttl_seconds: optional_int(raw, "ttl_seconds", label),
          filters: raw["filters"]?.try { |v| parse_filter_capabilities(v, type_str, label) },
          currency: optional_string(raw, "currency", label),
          precision: parse_precision(raw),
          items: raw["items"]?.try { |v| FieldDefinition.from_json(v, join_field(path, "items")) },
          properties: raw["properties"]?.try { |v| parse_properties(v, path, label) },
          dictionary_value: dict_value_def
        )
      end

      # Reads an optional string attribute on a field. The same doctrine as
      # the definition-level parser: absent key → nil, empty string → nil
      # (an empty value is an absent value), wrong type → 422 naming the
      # field path — never a silent drop (B-37).
      private def self.optional_string(raw : JSON::Any, key : String, label : String) : String?
        value = raw[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      # Same doctrine for booleans: absent → nil, wrong type → 422. The
      # nil check must be explicit — truthiness (`unless flag = ...`)
      # would also fire on a legitimate `false`, which is falsey in
      # Crystal. The raising `as_bool` used here previously escaped as a
      # 500.
      private def self.optional_bool(raw : JSON::Any, key : String, label : String) : Bool?
        value = raw[key]?
        return nil if value.nil?
        flag = value.as_bool?
        if flag.nil?
          raise DefinitionError.new("#{label}: '#{key}' must be a boolean (got #{StrictKeys.json_kind(value)})")
        end
        flag
      end

      # Same doctrine for integers: absent → nil, wrong type → 422. The
      # raising `as_i64` used here previously escaped as a 500.
      private def self.optional_int(raw : JSON::Any, key : String, label : String) : Int64?
        value = raw[key]?
        return nil if value.nil?
        unless number = value.as_i64?
          raise DefinitionError.new("#{label}: '#{key}' must be an integer (got #{StrictKeys.json_kind(value)})")
        end
        number
      end

      # Same doctrine for string arrays: absent → nil, non-array or a
      # non-string entry → 422. The raising `as_a` / `as_s` used here
      # previously escaped as a 500.
      private def self.optional_string_array(raw : JSON::Any, key : String, label : String) : Array(String)?
        value = raw[key]?
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

      # Same doctrine for object attributes (`filter`): absent → nil,
      # non-object → 422. The raising `as_h` used here previously escaped
      # as a 500.
      private def self.optional_object(raw : JSON::Any, key : String, label : String) : Hash(String, JSON::Any)?
        value = raw[key]?
        return nil if value.nil?
        unless obj = value.as_h?
          raise DefinitionError.new("#{label}: '#{key}' must be an object (got #{StrictKeys.json_kind(value)})")
        end
        obj
      end

      # Renders the bare field path as the location a field-level error
      # names (e.g. `field 'address.properties.city'`). Direct callers
      # outside a definition body get the generic `field definition`.
      private def self.field_label(path : String?) : String
        path ? "field '#{path}'" : "field definition"
      end

      # Parses the `filters:` array of capability names. An unknown name is
      # an authoring mistake of the same class as an unknown key — it
      # answers the 422 channel (`DefinitionError`) instead of a 500. The
      # message names the capabilities the declared type allows; a type the
      # vocabulary does not know yields an empty allowed set, and the type
      # validation reports the type separately.
      private def self.parse_filter_capabilities(
        raw : JSON::Any,
        type_str : String?,
        label : String,
      ) : Array(FilterCapability)
        allowed_names = FilterCapability.valid_names_for_type(type_str)
        allowed_display = allowed_names.empty? ? "none" : allowed_names.join(", ")
        raw.as_a.map do |s|
          begin
            FilterCapability.parse(s.as_s)
          rescue ArgumentError
            raise DefinitionError.new(
              "#{label}: unknown filter capability #{s.raw.inspect}" +
              " (allowed for type '#{type_str}': #{allowed_display})"
            )
          end
        end
      end

      # Reads the field's `type` name. A present-but-non-string value fails
      # loud (B-37): a silently dropped `type` stores a field with no type
      # definition, so every document create answers 422 and the doctype
      # is unusable while the registration itself answered success.
      private def self.parse_type_name(raw : JSON::Any, label : String) : String?
        type_raw = raw["type"]?
        return nil if type_raw.nil?

        type_str = type_raw.as_s?
        unless type_str
          raise DefinitionError.new(
            "#{label}: 'type' must be a string type name (got #{StrictKeys.json_kind(type_raw)})"
          )
        end
        type_str
      end

      # Resolves the declared type name through the type registry. An
      # unknown name is an authoring mistake of the same class as an
      # unknown filter capability — it answers the 422 channel
      # (`DefinitionError`) instead of escaping the create / update
      # services as a 500 `ArgumentError` (B-37). The registry message
      # already names the offender and the known types. Recursion paths
      # (`items`, dictionary `values`, object `properties`) inherit this
      # through the nested `from_json` calls.
      private def self.parse_field_type(type_str : String, label : String) : FieldType
        FieldType.parse(type_str)
      rescue ex : ArgumentError
        raise DefinitionError.new("#{label}: #{ex.message}")
      end

      # Validates the authored `operators` member (B-37). `operators` is
      # the derived read-only surface the struct writer emits (see
      # `DerivedOperators`) — accepted on read so round-tripped and
      # stamped content re-parses, never stored. A junk list was
      # previously dropped with a 201 while the author believed they had
      # declared it; every entry must now name a known `Operator`.
      private def self.validate_operators(raw : JSON::Any, label : String) : Nil
        ops_a = raw.as_a?
        unless ops_a
          raise DefinitionError.new(
            "#{label}.operators must be an array of operator names (got #{StrictKeys.json_kind(raw)})"
          )
        end

        ops_a.each do |entry|
          name = entry.as_s?
          next if name && valid_operator?(name)
          raise DefinitionError.new(
            "#{label}.operators: unknown operator #{entry.raw.inspect}" +
            " (known operators: #{OPERATOR_BY_NAME.keys.join(", ")})"
          )
        end
      end

      private def self.valid_operator?(name : String) : Bool
        Operator.parse(name)
        true
      rescue ArgumentError
        false
      end

      # Extends a bare field path with one nesting hop (items element,
      # object property, dictionary value definition).
      private def self.join_field(path : String?, leaf : String) : String
        path ? "#{path}.#{leaf}" : leaf
      end

      # Reads the optional `precision` (decimal places). A wrong-typed or
      # negative value fails loud — a silently dropped precision would
      # change how every rendered value rounds.
      private def self.parse_precision(raw : JSON::Any) : Int64?
        value = raw["precision"]?
        return nil if value.nil?
        unless precision_val = value.as_i64?
          raise DefinitionError.new(
            "'precision' must be an integer (decimal places) (got #{StrictKeys.json_kind(value)})"
          )
        end
        unless precision_val >= 0
          raise DefinitionError.new("'precision' must be >= 0 (got #{precision_val})")
        end
        precision_val
      end

      # Parses the `properties` map of an object field, naming each
      # sub-field's path in error messages.
      private def self.parse_properties(raw : JSON::Any, path : String?, label : String) : Hash(String, FieldDefinition)
        props_h = raw.as_h?
        unless props_h
          raise DefinitionError.new(
            "#{label}.properties must be an object keyed by name (got #{StrictKeys.json_kind(raw)})"
          )
        end

        parsed = {} of String => FieldDefinition
        props_h.each do |name, value|
          parsed[name] = FieldDefinition.from_json(value, join_field(path, "properties.#{name}"))
        end
        parsed
      end

      # Extracts the field type, enum values, and dictionary value type from raw JSON.
      private def self.parse_type_and_values(
        raw : JSON::Any,
        type_str : String?,
        doctype_str : String?,
        path : String?,
        label : String,
      ) : {FieldType?, Array(EnumValue)?, FieldDefinition?}
        field_type = if type_str
                       parse_field_type(type_str, label)
                     elsif doctype_str
                       FieldType.parse("reference")
                     else
                       nil
                     end

        enum_values = if field_type.try(&.type_name) == "enum"
                        parse_enum_values(raw["values"]?, label)
                      else
                        nil
                      end

        dict_value_def = if field_type.try(&.type_name) == "dictionary"
                           raw["values"]?.try { |v| FieldDefinition.from_json(v, join_field(path, "values")) }
                         else
                           nil
                         end

        {field_type, enum_values, dict_value_def}
      end

      # Parses enum `values` from raw JSON, accepting both the new object form
      # `[{key: "foo", label: "Foo", color: "#..."}]` and the legacy string form
      # `["foo", "bar"]`.
      private def self.parse_enum_values(raw : JSON::Any?, label : String) : Array(EnumValue)?
        raw.try do |v|
          values_a = v.as_a?
          unless values_a
            raise DefinitionError.new(
              "#{label}.values must be an array of enum entries (got #{StrictKeys.json_kind(v)})"
            )
          end
          values_a.map_with_index do |item, index|
            if item.as_h?
              EnumValue.from_json(item, "#{label}.values[#{index}]")
            else
              # Legacy string form
              key = item.as_s?
              if key.nil?
                raise DefinitionError.new(
                  "#{label}.values[#{index}] must be a string key or an object entry (got #{StrictKeys.json_kind(item)})"
                )
              end
              if key.empty?
                raise DefinitionError.new(
                  "#{label}.values[#{index}] must be a non-empty string key"
                )
              end
              EnumValue.new(key: key)
            end
          end
        end
      end

      def initialize(
        @type : FieldType? = nil,
        @values : Array(EnumValue)? = nil,
        @doctype : String? = nil,
        @required : Bool = false,
        @unique : Bool = false,
        @default : JSON::Any? = nil,
        @min : Int64? = nil,
        @max : Int64? = nil,
        @collection : Bool = false,
        @compute : String? = nil,
        @compute_when : Array(String)? = nil,
        @replicate : ReplicateConfig? = nil,
        @on_source_delete : String = "keep",
        @accept : Array(String)? = nil,
        @title : String? = nil,
        @description : String? = nil,
        @write_only : Bool = false,
        @read_only : Bool = false,
        @owned : Bool? = nil,
        @filter : Hash(String, JSON::Any)? = nil,
        @dangling : Bool = false,
        @tags : Array(String)? = nil,
        @pattern : String? = nil,
        @pattern_flags : String? = nil,
        @mode : String? = nil,
        @ttl_seconds : Int64? = nil,
        @filters : Array(FilterCapability)? = nil,
        @currency : String? = nil,
        @precision : Int64? = nil,
        @items : FieldDefinition? = nil,
        @properties : Hash(String, FieldDefinition)? = nil,
        @dictionary_value : FieldDefinition? = nil,
      )
      end

      # ── Query helpers ──────────────────────────────────────────────────

      # Returns `true` if this field is a reference (owned or unowned).
      def reference? : Bool
        @type.try(&.type_name) == "reference" || false
      end

      # Returns `true` if this field is computed.
      def computed? : Bool
        @type.try(&.type_name) == "data" || false
      end

      # Returns `true` if this field is a cross-domain replicate.
      def replicated? : Bool
        !@replicate.nil?
      end

      # Returns `true` if this field is write-only.
      def write_only? : Bool
        @write_only
      end

      # Returns `true` if this field is read-only.
      def read_only? : Bool
        @read_only
      end

      # Returns the target doctype identifier for references.
      def qualified_doctype : String?
        @doctype
      end

      # Returns `true` if this field has a reference filter.
      def filtered_reference? : Bool
        if (f = @filter) && reference?
          !f.empty?
        else
          false
        end
      end

      # Returns `true` if this reference opts out of the authoring-time
      # existence check (`Document::ReferenceCheck`). See the `dangling`
      # getter doc.
      def dangling? : Bool
        @dangling && reference?
      end

      # ── JSON serialisation ──────────────────────────────────────────────

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          write_type_and_values(builder)
          write_basic_fields(builder)
          write_optional_structs(builder)
        end
      end

      private def write_type_and_values(builder : JSON::Builder) : Nil
        if t = @type
          builder.field("type", t)
        end

        if v = @values
          builder.field("values") do
            builder.array do
              v.each(&.to_json(builder))
            end
          end
        end

        if d = @doctype
          builder.field("doctype", d)
        end
      end

      private def write_basic_fields(builder : JSON::Builder) : Nil
        write_required_bools(builder)
        write_numeric_fields(builder)
        write_string_fields(builder)
        write_nested_definitions(builder)
        write_visibility_fields(builder)
      end

      private def write_required_bools(builder : JSON::Builder) : Nil
        builder.field("required", @required)
        builder.field("unique", @unique)
        builder.field("collection", @collection)
        builder.field("write_only", @write_only) if @write_only
        builder.field("read_only", @read_only) if @read_only
        builder.field("dangling", true) if @dangling
      end

      private def write_numeric_fields(builder : JSON::Builder) : Nil
        if d = @default
          builder.field("default", d)
        end

        if m = @min
          builder.field("min", m)
        end

        if m = @max
          builder.field("max", m)
        end

        if p = @precision
          builder.field("precision", p)
        end
      end

      private def write_string_fields(builder : JSON::Builder) : Nil
        if c = @compute
          builder.field("compute", c)
        end

        if t = @title
          builder.field("title", t)
        end

        if d = @description
          builder.field("description", d)
        end

        if p = @pattern
          builder.field("pattern", p)
        end

        if pf = @pattern_flags
          builder.field("pattern_flags", pf)
        end

        if m = @mode
          builder.field("mode", m)
        end

        if t = @ttl_seconds
          builder.field("ttl_seconds", t)
        end

        if cur = @currency
          builder.field("currency", cur)
        end
      end

      private def write_nested_definitions(builder : JSON::Builder) : Nil
        if items = @items
          builder.field("items", items)
        end

        if cw = @compute_when
          builder.field("compute_when") do
            builder.array do
              cw.each { |s| builder.string(s) }
            end
          end
        end

        if rep = @replicate
          builder.field("replicate", rep)
        end

        if @on_source_delete != "keep"
          builder.field("on_source_delete", @on_source_delete)
        end

        if o = @owned
          builder.field("owned", o)
        end
      end

      private def write_visibility_fields(builder : JSON::Builder) : Nil
        if v = @tags
          builder.field("tags") do
            builder.array do
              v.each { |s| builder.string(s) }
            end
          end
        end
      end

      private def write_optional_structs(builder : JSON::Builder) : Nil
        if props = @properties
          builder.field("properties") do
            builder.object do
              props.each do |name, field|
                builder.field(name, field)
              end
            end
          end
        end

        if dict_val = @dictionary_value
          builder.field("values", dict_val)
        end

        if caps = @filters
          builder.field("filters") do
            builder.array do
              caps.each { |c| builder.string(c.to_s_lowercase) }
            end
          end

          # Derived read-only `operators:` surface — the union of each
          # capability's operator family (de-duplicated, sorted by
          # `Operator` declaration order). This is the runtime URL-suffix
          # vocabulary consumed by `Document::List` clause builders and
          # by the frontend filter bar (`FieldDef.operators`). Authored
          # via `filters`; never written back to the wire as an input —
          # `from_json` ignores it.
          builder.field("operators") do
            builder.array do
              operators.each(&.to_json(builder))
            end
          end
        end

        if f = @filter
          builder.field("filter") do
            builder.object do
              f.each { |fk, fv| builder.field(fk, fv) }
            end
          end
        end

        if a = @accept
          builder.field("accept") do
            builder.array do
              a.each { |s| builder.string(s) }
            end
          end
        end
      end
    end
  end
end
