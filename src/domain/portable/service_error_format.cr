# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../error"

module Facet
  module Domain
    module Portable
      # Formats a `ServiceError` for an operator: the top-level summary on
      # the first line, then each structured `ValidationError` detail on its
      # own indented line (`field: message [code]`). The `details` array is
      # what actually names the failing field and the reason — without it
      # the operator sees only a generic "schema validation failed" with no
      # clue which field broke.
      #
      # Shared by the `domain:export` / `domain:import` CLI (the `abort`
      # printout) and the dev domain watcher (the import-failure log).
      module ServiceErrorFormat
        # The single string `abort` expects: `"<prefix>: <summary>"` plus
        # the details block when the error carries one.
        def self.format(prefix : String, error : Facet::ServiceError) : String
          "#{prefix}: #{error.message}#{details_block(error)}"
        end

        # The details block alone: `""` when the error carries no structured
        # details. Callers that already print the summary (the dev watcher's
        # log line) append this after their own text.
        def self.details_block(error : Facet::ServiceError) : String
          return "" unless details = error.details
          return "" if details.empty?

          lines = ["\n  details:"]
          details.each do |d|
            field = d.field ? "#{d.field}: " : ""
            code = d.code ? " [#{d.code}]" : ""
            lines << "    - #{field}#{d.message}#{code}"
          end
          lines.join('\n')
        end
      end
    end
  end
end
