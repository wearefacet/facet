# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./yaml_helper"
require "./definition_error"

module Facet
  module Doctype
    # Configuration for a replicated field — a read-only copy of a field
    # from a referenced document in another domain.
    #
    # Replication is per-field, reference-scoped, and event-driven.
    # It reuses the existing event stream, field-mask, and
    # projection-trigger machinery.
    #
    # ### JSON shape
    #
    # ```json
    # "person_name": {
    #   "type": "string",
    #   "replicate": {
    #     "via": "employee_id",
    #     "field": "full_name"
    #   }
    # }
    # ```
    struct ReplicateConfig
      # The **local reference field** on the same doctype whose target
      # provides the source value. Must name a `reference`-typed field
      # that is itself not a replica.
      getter via : String

      # The field name on the source doctype to replicate from.
      getter field : String

      # Top-level keys `from_json` reads on a replicate config. Any other
      # key is rejected at parse time (B-13).
      KNOWN_KEYS = %w[via field]

      def initialize(@via : String, @field : String)
      end

      # Parse from a raw YAML string.
      Doctype.yaml_entrypoint

      # Parse from a JSON object. `path` names the config for error
      # messages (e.g. `field 'person_name'.replicate`); callers outside a
      # definition body omit it. Both members are required non-empty
      # strings; a wrong type answers 422, never a raised cast (B-12).
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "replicate config"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        new(via: required_string(h, "via", label), field: required_string(h, "field", label))
      end

      # Reads a required non-empty string member. Absent or empty is
      # missing (the member names a field — an empty name resolves to
      # nothing downstream), a wrong type answers 422.
      private def self.required_string(h : Hash(String, JSON::Any), key : String, label : String) : String
        value = h[key]?
        if value.nil?
          raise DefinitionError.new("Missing required field '#{key}' in replicate config")
        end
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        if text.empty?
          raise DefinitionError.new("#{label}: '#{key}' must be a non-empty string")
        end
        text
      end

      # Serialise to JSON.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("via", @via)
          builder.field("field", @field)
        end
      end
    end
  end
end
