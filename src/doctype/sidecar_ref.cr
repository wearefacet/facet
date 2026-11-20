# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./definition_error"

module Facet
  module Doctype
    # Describes a single sidecar relationship in a doctype's `sidecars` map.
    #
    # A sidecar relationship means documents of the `doctype` (always a
    # qualified id, e.g. `"core.Comment"`) attach to documents of the host
    # doctype through a reference field on the sidecar — not through
    # `parent_id` composition. The sidecar doctype lives in the `core`
    # domain and is flagged `sidecar: true`.
    #
    # The relationship name (the key in the `sidecars` map) is used for
    # HTTP routing — e.g. `/Api/crm/Contact/:id/comments/:sidecar_id`.
    struct SidecarRef
      # The target sidecar doctype, always qualified (e.g. `"core.Comment"`).
      getter doctype : String

      # The reference field on the sidecar doctype that points back at the
      # host document. Defaults to `"target"`.
      getter column : String

      # Optional author-controlled tab order. PostgreSQL `jsonb` does not
      # preserve object key order, so declaration order cannot decide tab
      # order — hosts that care sort by `{order, segment name}`; the default
      # `0` collapses to the stable alphabetical default.
      getter order : Int32 = 0

      # Optional host-owned tab label override (e.g. `"Notes"`). When absent
      # the frontend falls back to the humanized segment name. It lives on
      # the host ref, not on the sidecar doctype: sidecar doctypes are
      # forced into `core`, so a domain author could not reword a shared
      # system-owned definition.
      getter label : String?

      # Top-level keys `from_json` reads on a sidecar entry. Any other key
      # is rejected at parse time (B-13).
      KNOWN_KEYS = %w[doctype column order label]

      def initialize(@doctype : String, @column : String = "target", @order : Int32 = 0, @label : String? = nil)
      end

      # Sort key for tab ordering: `{order, segment name}` (see `order`).
      def sort_key(segment : String) : {Int32, String}
        {@order, segment}
      end

      # Parse from a parsed JSON::Any value. `path` names the relationship
      # for error messages (e.g. `sidecar 'comments'`); callers outside a
      # definition body omit it.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "sidecar entry"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        doctype_raw = h["doctype"]?
        if doctype_raw.nil?
          raise DefinitionError.new("Missing 'doctype' in sidecar entry")
        end
        unless doctype_val = doctype_raw.as_s?
          raise DefinitionError.new(
            "#{label}: 'doctype' must be a string (got #{StrictKeys.json_kind(doctype_raw)})"
          )
        end
        # Require the qualified form (must contain a dot).
        unless doctype_val.includes?('.')
          raise DefinitionError.new("sidecar doctype must be qualified (e.g. 'core.Comment'); got '#{doctype_val}'")
        end
        column_val = optional_string(h, "column", label) || "target"
        order_val = optional_int(h, "order", label) || 0
        label_val = optional_string(h, "label", label)
        new(doctype: doctype_val, column: column_val, order: order_val.to_i32, label: label_val)
      end

      # Same doctrine as the field parser: absent or empty string → nil,
      # wrong type → 422. The raising `as_s` / `as_i` casts used here
      # previously escaped as a 500, and an empty `column` bypassed the
      # `target` default instead of meaning "no override".
      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      private def self.optional_int(h : Hash(String, JSON::Any), key : String, label : String) : Int64?
        value = h[key]?
        return nil if value.nil?
        unless number = value.as_i64?
          raise DefinitionError.new("#{label}: '#{key}' must be an integer (got #{StrictKeys.json_kind(value)})")
        end
        number
      end

      # Serialise to JSON. `order` and `label` are emitted only when set —
      # same wire contract as the definition's optional fields.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("doctype", @doctype)
          builder.field("column", @column)
          builder.field("order", @order) unless @order == 0
          builder.field("label", @label) if @label
        end
      end
    end
  end
end
