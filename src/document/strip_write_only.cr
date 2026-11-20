# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Document
    # Helper for removing write_only fields from a document before persistence.
    #
    # Write‑only fields are accepted in input (so the Lua script can read them)
    # but must be stripped from the final document that gets persisted.
    module StripWriteOnly
      # Strips all write_only fields defined in the given doctype definition
      # from the document hash. Returns a new `JSON::Any`.
      def self.call(
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : JSON::Any
        doc_hash = document.as_h?
        return document if doc_hash.nil?

        write_only_names = definition.fields.select do |_name, field|
          field.write_only?
        end.keys.to_set

        return document if write_only_names.empty?

        filtered = doc_hash.reject { |key, _| write_only_names.includes?(key) }
        JSON::Any.new(filtered)
      end
    end
  end
end
