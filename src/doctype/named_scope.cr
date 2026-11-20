# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./yaml_helper"
require "./definition_error"

module Facet
  module Doctype
    # A named, server-defined predicate over a doctype's own fields.
    #
    # Stored under `{domain}.{Doctype}.definition.content.scopes`. At
    # enforcement time, a permission's `scope` field references one by name
    # (e.g. `"$active_only"`) and the enforcer expands it to this predicate.
    #
    # The `where` map uses the same value grammar as context sets:
    # - a literal value (compared verbatim against the field)
    # - `$self` — the actioner's account id
    # - `$<context_set>` — a domain-declared context set, resolved at request time
    # - `$null` — matches rows where the field is absent or JSON null
    # - `$organizational_unit` — the actioner's own
    #   `iam.Account.organizational_unit` value (see `RBAC::ScopeContext`)
    #
    # Field names may use the reserved token `$parent_id`, which reads the
    # system-managed parent linkage stored at `meta->>'parent_id'`. This is
    # the same convention context sets use (see `RBAC::ContextResolver`).
    struct NamedScope
      getter name : String
      getter where : Hash(String, String)
      getter description : String?

      # Top-level keys `from_json` reads on a scope entry. Any other key is
      # rejected at parse time (B-13).
      KNOWN_KEYS = %w[where description]

      def initialize(
        @name : String,
        @where : Hash(String, String),
        @description : String? = nil,
      )
      end

      # Parses a single named scope entry from its raw JSON value.
      #
      # `name` is the map key under `scopes`; `raw` is the entry's body,
      # expected to be an object with optional `description` and a `where`
      # map of field → value.
      #
      # All rejections raise `DefinitionError` — the standard error the
      # create/update services rescue into a 422. It subclasses
      # `JSON::ParseException`, but a bare `JSON::CastException` (the sibling
      # raised by unguarded casts) escapes those rescues and surfaces as an
      # HTTP 500.
      def self.from_json(name : String, raw : JSON::Any) : self
        h = raw.as_h?
        if h.nil?
          raise DefinitionError.new(
            "Named scope '#{name}' must be an object with optional 'description' and a 'where' map"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, "scope '#{name}'")

        where_raw = h["where"]?
        if where_raw && where_raw.as_h?.nil?
          raise DefinitionError.new(
            "Named scope '#{name}': 'where' must be an object mapping field names to values"
          )
        end

        where_map = (where_raw.try(&.as_h) || {} of String => JSON::Any).each_with_object({} of String => String) do |(k, v), acc|
          acc[k] = coerce_where_value(name, k, v)
        end

        description = optional_string(h, "description", "Named scope '#{name}'")
        new(name: name, where: where_map, description: description)
      end

      # Same doctrine as the field parser: absent or empty → nil, wrong
      # type → 422 naming the scope. The silent drop on a wrong type
      # previously lost the description without a word.
      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      # A `where` value accepts JSON scalars — string, number, boolean —
      # and stores the string form (integers and floats render through
      # `to_s`; booleans as "true" / "false"). Composite values (array,
      # object) and null are rejected: the scope grammar compares a field
      # against a literal or one of the `$`-tokens, so anything else is a
      # definition error, not a value to drop silently.
      private def self.coerce_where_value(scope : String, key : String, v : JSON::Any) : String
        case raw = v.raw
        when String
          raw
        when Int64
          raw.to_s
        when Float64
          raw.to_s
        when Bool
          raw.to_s
        else
          kind = case raw
                 when Nil   then "null"
                 when Array then "array"
                 else            "object"
                 end
          raise DefinitionError.new(
            "Named scope '#{scope}': 'where' value for '#{key}' must be a string, number, or boolean (got #{kind})"
          )
        end
      end

      # Serialises back to JSON (round-trips with `from_json`).
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          if d = @description
            builder.field("description", d)
          end
          builder.field("where") do
            builder.object do
              @where.each { |k, v| builder.field(k, v) }
            end
          end
        end
      end
    end
  end
end
