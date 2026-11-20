# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  module Doctype
    module YamlHelper
      # Converts a YAML::Any node into the equivalent JSON::Any structure.
      # This allows us to reuse all existing from_json(JSON::Any) logic
      # when parsing YAML definition files.
      def self.to_json_any(yaml : YAML::Any) : JSON::Any
        case raw = yaml.raw
        when Nil
          JSON::Any.new(nil)
        when Bool
          JSON::Any.new(raw)
        when Int64
          JSON::Any.new(raw)
        when Float64
          JSON::Any.new(raw)
        when String
          JSON::Any.new(raw)
        when Array
          JSON::Any.new(raw.map { |v| to_json_any(v) })
        when Hash
          string_hash = {} of String => JSON::Any
          raw.each do |k, v|
            key_raw = k.raw
            unless key_raw.is_a?(String)
              raise ArgumentError.new(
                "YAML hash key must be a String, got #{key_raw.class} (#{key_raw.inspect}). " \
                "Bare words like 'on', 'off', 'yes', 'no' are parsed as booleans " \
                "by YAML 1.1 — quote the key to force string interpretation, e.g. " \
                "'\"on\": value' instead of 'on: value'."
              )
            end
            string_hash[key_raw] = to_json_any(v)
          end
          JSON::Any.new(string_hash)
        else
          raise "Unsupported YAML type: #{raw.class}"
        end
      end
    end

    # Emits a `from_yaml` entrypoint for the enclosing struct or class.
    # Every YAML definition entrypoint parses the raw string, converts the
    # node with `YamlHelper.to_json_any`, and delegates to the type's
    # `from_json(JSON::Any)`. Expand it inside each definition type that
    # accepts YAML. Lives at the `Doctype` level — macro lookup walks the
    # lexical scope chain, and sibling modules are not searched.
    macro yaml_entrypoint
      # Parse from a raw YAML string.
      def self.from_yaml(string : String) : self
        yaml = YAML.parse(string)
        from_json(YamlHelper.to_json_any(yaml))
      end
    end
  end
end
