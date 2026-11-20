# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"
require "json"

# Generic YAML to JSON value conversion.
#
# This module converts a parsed YAML value to a `JSON::Any` value of the
# same shape. It knows nothing about any caller. A caller that needs
# domain rules wraps it.
module Facet::Util::YamlJson
  # Converts a `YAML::Any` value to a `JSON::Any` value with the same
  # shape. Scalars are coerced via .raw; mappings and sequences are
  # rebuilt recursively. Used so the rest of the portable-domain code
  # can work uniformly in `JSON::Any` regardless of the bundle's
  # on-disk format.
  def self.to_json_any(value : YAML::Any) : JSON::Any
    case raw = value.raw
    when Hash(YAML::Any, YAML::Any)
      h = {} of String => JSON::Any
      raw.each do |k, v|
        # YAML hash keys may be non-string; .to_s gives the scalar
        # string representation. The portable-domain bundle is
        # author-controlled YAML so keys are always strings in
        # practice.
        h[k.to_s] = to_json_any(v) if k.raw.is_a?(String)
      end
      JSON::Any.new(h)
    when Array(YAML::Any)
      a = [] of JSON::Any
      raw.each { |v| a << to_json_any(v) }
      JSON::Any.new(a)
    when Set(YAML::Any)
      # A YAML !!set is emitted as a hash with null values; Crystal
      # exposes it as a Set. Treat it as a JSON array of its members
      # (the order is not preserved, which matches the
      # non-deterministic JSON::Any set semantics).
      a = [] of JSON::Any
      raw.each { |v| a << to_json_any(v) }
      JSON::Any.new(a)
    else
      scalar_to_json_any(raw)
    end
  end

  # Coerces a YAML scalar / leaf value to a `JSON::Any`. Container
  # types are handled by `to_json_any`; this helper deals with
  # the leaves only. Extracted so the combined dispatch stays under
  # the cyclomatic-complexity budget.
  private def self.scalar_to_json_any(raw) : JSON::Any
    case raw
    when Bool, Int64, Float64, String
      JSON::Any.new(raw)
    when Nil
      JSON::Any.new(nil)
    when Time
      # A YAML timestamp round-trips to an ISO-8601 string in JSON.
      JSON::Any.new(raw.to_rfc3339)
    when Slice(UInt8)
      # A YAML binary scalar — represent as hex string.
      JSON::Any.new(raw.hexstring)
    else
      # Fallback: stringify. This branch is unreachable for
      # well-formed bundle entries (every YAML core-schema type is
      # handled above).
      JSON::Any.new(raw.to_s)
    end
  end
end
