# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Document
    # Applies default values from a doctype definition's fields to a document.
    #
    # For every field in the definition that has a `default` value, if the
    # document does not already have that field set, the default is applied.
    #
    # This runs before the Lua script and before persistence so that defaults
    # are visible to both the script and the stored content.
    module ApplyDefaults
      # Applies defaults to the given document.
      #
      # Returns a new `JSON::Any` with defaults filled in for missing fields.
      def self.call(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        doc_hash = document.as_h?
        return document if doc_hash.nil?

        result = doc_hash.dup

        definition.fields.each do |field_name, field|
          default = field.default
          next if default.nil?
          next if result.has_key?(field_name)

          result[field_name] = default
        end

        JSON::Any.new(result)
      end
    end
  end
end
