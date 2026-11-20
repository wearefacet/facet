# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./../util/color"
require "./../util/string_util"
require "./definition_error"

module Facet
  module Doctype
    # A single value in an enum field definition.
    #
    # Each enum value has a `key` (the stored string), an optional `label`
    # (human-readable, defaults to humanized key), and an optional `color`
    # (CSS hex, defaults to a deterministic hash of the key).
    struct EnumValue
      include JSON::Serializable

      # The stored string value. Required, max 64 characters.
      getter key : String

      # Human-readable label. When nil, derived via `StringUtil.humanize(key)`.
      getter label : String?

      # CSS hex color (`#RRGGBB`). When nil, derived via `Util::Color.hash_color(key)`.
      getter color : String?

      # Top-level keys the hand-written `from_json` reads on an enum value
      # entry. Any other key is rejected at parse time (B-13).
      KNOWN_KEYS = %w[key label color]

      def initialize(
        @key : String,
        @label : String? = nil,
        @color : String? = nil,
      )
      end

      # Parse from a parsed JSON::Any value. `path` names the entry for
      # error messages (e.g. `field 'status'.values[0]`); callers outside a
      # definition body omit it. The key is required and non-empty — it is
      # the stored value and the identity of the entry. `label` and `color`
      # are optional: absent or empty falls back to the derived
      # humanized label / hash color, a wrong type answers 422.
      def self.from_json(raw : JSON::Any, path : String? = nil) : self
        label = path || "enum value entry"
        h = raw.as_h?
        unless h
          raise DefinitionError.new(
            "#{label} must be a JSON object (got #{StrictKeys.json_kind(raw)})"
          )
        end
        StrictKeys.reject_unknown!(h, KNOWN_KEYS, label)

        key_raw = h["key"]?
        if key_raw.nil?
          raise DefinitionError.new("#{label}: Missing required field 'key'")
        end
        unless key = key_raw.as_s?
          raise DefinitionError.new("#{label}: 'key' must be a string (got #{StrictKeys.json_kind(key_raw)})")
        end
        if key.empty?
          raise DefinitionError.new("#{label}: 'key' must be a non-empty string")
        end

        new(
          key: key,
          label: optional_string(h, "label", label),
          color: optional_string(h, "color", label)
        )
      end

      # Same optional-text doctrine as the field parser: absent or empty →
      # nil (the derived fallback applies), wrong type → 422.
      private def self.optional_string(h : Hash(String, JSON::Any), key : String, label : String) : String?
        value = h[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("#{label}: '#{key}' must be a string (got #{StrictKeys.json_kind(value)})")
        end
        text.empty? ? nil : text
      end

      # Parse from a raw JSON string.
      def self.from_json(string : String) : self
        from_json(JSON.parse(string))
      end

      # Returns the effective label: `@label` or `StringUtil.humanize(@key)`.
      def effective_label : String
        @label || Util::StringUtil.humanize(@key)
      end

      # Returns the effective color: `@color` or `Util::Color.hash_color(@key)`.
      def effective_color : String
        @color || Util::Color.hash_color(@key)
      end

      # Custom JSON serialisation: always emit `key`, emit `label` and
      # `color` only when they differ from the derived defaults
      # (`StringUtil.humanize(key)` / `Util::Color.hash_color(key)`).
      # Compare against the derived value, never the effective one — the
      # effective value already equals a set `@label` / `@color`, so that
      # comparison would always be false and the custom value would be
      # dropped on write.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("key", @key)
          if (l = @label) && l != Util::StringUtil.humanize(@key)
            builder.field("label", l)
          end
          if (c = @color) && c != Util::Color.hash_color(@key)
            builder.field("color", c)
          end
        end
      end
    end
  end
end
