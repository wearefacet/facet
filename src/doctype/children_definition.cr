# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./yaml_helper"
require "./definition_error"

module Facet
  module Doctype
    # Describes a single child relationship in a doctype's composition tree.
    #
    # A child relationship means documents of the `doctype` are owned by the
    # parent document. They are stored as **separate projection rows** (not
    # inline JSON), linked via `parent_id` in the `links` column.
    #
    # **Important convention:** the link goes from parent to child only.
    # Child doctypes must **not** define a reference field pointing back to
    # their parent — that would duplicate the system-managed `parent_id`
    # link and create ambiguity about the source of truth.
    #
    # If a child needs to reference its parent semantically
    # (e.g. `Activity.company_id`), use a reference field only when the
    # relationship is a cross-reference, not the ownership link itself.
    #
    # The relationship name (the key in the `children` map) is used for
    # HTTP routing — e.g. `/Api/hr/Employee/:id/career_events/:child_id`.
    struct ChildrenDefinition
      # The target doctype for this child relationship (e.g. `"CareerEvent"`).
      getter doctype : String

      # Whether the child relationship is a collection (array of children)
      # or a single child document. Defaults to `true`.
      getter? collection : Bool = true

      # Human‑readable description of this child relationship.
      getter description : String?

      # Top-level keys `from_json` reads on a children entry. Any other key
      # is rejected at parse time (B-13).
      KNOWN_KEYS = %w[doctype collection description]

      def initialize(
        @doctype : String,
        @collection : Bool = true,
        @description : String? = nil,
      )
      end

      # Parse from a raw YAML string.
      Doctype.yaml_entrypoint

      # Parse from a parsed JSON::Any value. `path` names the relationship
      # for error messages (e.g. `child 'career_events'`); callers outside
      # a definition body omit it.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "children entry"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        doctype_raw = h["doctype"]?
        if doctype_raw.nil?
          raise DefinitionError.new("Missing required field 'doctype' in children entry")
        end
        unless doctype_val = doctype_raw.as_s?
          raise DefinitionError.new(
            "#{label}: 'doctype' must be a string (got #{StrictKeys.json_kind(doctype_raw)})"
          )
        end
        unless doctype_val.matches?(/^[A-Z][a-zA-Z0-9]*$/)
          raise DefinitionError.new(
            "children doctype must be a bare same-domain doctype name (CamelCase, no dot); got: #{doctype_val}"
          )
        end

        new(
          doctype: doctype_val,
          collection: optional_bool(h, "collection", label) != false,
          description: optional_string(h, "description", label)
        )
      end

      # Same doctrine as the field parser: absent or empty string → nil,
      # wrong type → 422. The raising `as_bool` / `as_s` casts used here
      # previously escaped as a 500.
      private def self.optional_bool(h : Hash(String, JSON::Any), key : String, label : String) : Bool?
        value = h[key]?
        return nil if value.nil?
        flag = value.as_bool?
        if flag.nil?
          raise DefinitionError.new("#{label}: '#{key}' must be a boolean (got #{StrictKeys.json_kind(value)})")
        end
        flag
      end

      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      # Serialise to JSON.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("doctype", @doctype)
          builder.field("collection", collection?)
          if d = @description
            builder.field("description", d)
          end
        end
      end
    end
  end
end
