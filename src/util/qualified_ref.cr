# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Splits the qualified identifiers of the reference storage contract.
    #
    # - `split_doctype` — `"{domain}.{Doctype}"`. Splits on the FIRST dot
    #   only; the doctype segment never contains a dot (doctype names are
    #   validated to `[A-Z][a-zA-Z0-9]*`).
    # - `split_reference` — `"{domain}.{Doctype}.{id}"`. Splits on the
    #   FIRST TWO dots only; the id segment may itself contain a dot (see
    #   the qualified reference storage contract).
    module QualifiedRef
      # Returns `{domain, doctype}`. Raises `ArgumentError` when
      # *qualified* carries no dot.
      def self.split_doctype(qualified : String) : {String, String}
        dot = qualified.index('.')
        raise ArgumentError.new("qualified doctype must contain a dot (got '#{qualified}')") if dot.nil?
        {qualified[0...dot], qualified[(dot + 1)..]}
      end

      # Returns `{domain, doctype, id}`, or `nil` when the value has fewer
      # than three segments. A malformed reference degrades to `nil`, never
      # to a partial split.
      def self.split_reference(value : String) : {String, String, String}?
        first = value.index('.')
        return nil unless first && first > 0
        rest = value[(first + 1)..]
        second = rest.index('.')
        return nil unless second && second > 0
        {value[0...first], rest[0...second], rest[(second + 1)..]}
      end
    end
  end
end
