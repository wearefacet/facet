# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Doctype
    # Semantic doctype-definition error: the payload parsed as JSON but
    # violates the definition grammar — a container key that is not an
    # object, a scalar of the wrong type, an unknown key, a reserved name.
    #
    # Subclasses `JSON::ParseException` so every existing rescue into a
    # 422 (`Doctype::Create`, `Doctype::Update`, the portable import)
    # keeps working unchanged. The parent bakes an `at line 0, column 0`
    # suffix into its message; semantic errors have no source location,
    # so `message` is overridden to render the text verbatim.
    class DefinitionError < JSON::ParseException
      @definition_message : String

      def initialize(message : String)
        @definition_message = message
        super(message, 0, 0)
      end

      def message : String?
        @definition_message
      end
    end

    # Shared strict-key guard for the definition parsers. Each parser lists
    # the keys it reads; a key outside that list raises `DefinitionError`
    # naming the offender, its location (the path, e.g. `field 'name'`),
    # and — when the mistake reads like a typo — the closest known key.
    # A silently dropped key would store a definition that no longer
    # matches what the author wrote while the call still answered success
    # (B-13); the top-level guard already worked this way, the nested
    # entry parsers did not.
    module StrictKeys
      extend self

      # Raises `DefinitionError` when `h` carries keys outside `known`.
      # `path` names the location of the entry, e.g. `field 'name'` or
      # `action 'approve'.args.note`.
      def reject_unknown!(h : Hash(String, JSON::Any), known : Indexable(String), path : String) : Nil
        unknown = h.keys.sort!.reject { |k| known.includes?(k) }
        return if unknown.empty?

        listed = unknown.map { |k| "'#{k}'" }.join(", ")
        message = "Unknown key(s) in #{path}: #{listed}"
        if unknown.size == 1 && (hint = closest_match(unknown.first, known))
          message += " (did you mean '#{hint}'?)"
        end
        raise DefinitionError.new(message)
      end

      # Names the JSON kind of a raw value for shape-error messages —
      # same wording as the named-scope where-value rejections.
      def json_kind(value : JSON::Any) : String
        case value.raw
        when Nil            then "null"
        when Bool           then "boolean"
        when Int64, Float64 then "number"
        when String         then "string"
        when Array          then "array"
        else                     "object"
        end
      end

      # The known key nearest to `typo`, or nil when none is within edit
      # distance 2. Distance 2 covers the usual key-typo shapes —
      # insertion, deletion, substitution, and transposition (counted as
      # two edits) — without suggesting unrelated keys.
      private def closest_match(typo : String, known : Indexable(String)) : String?
        best : String? = nil
        best_distance = 3
        known.each do |candidate|
          distance = edit_distance(typo, candidate)
          if distance < best_distance
            best_distance = distance
            best = candidate
          end
        end
        best
      end

      # Classic two-row Levenshtein distance. Keys are short, so no
      # early-exit cutoff is needed.
      private def edit_distance(a : String, b : String) : Int32
        return b.size if a.empty?
        return a.size if b.empty?

        previous = (0..b.size).to_a
        current = Array(Int32).new(b.size + 1, 0)
        a.chars.each_with_index do |ca, i|
          current[0] = i + 1
          b.chars.each_with_index do |cb, j|
            cost = ca == cb ? 0 : 1
            current[j + 1] = Math.min(
              Math.min(current[j] + 1, previous[j + 1] + 1),
              previous[j] + cost
            )
          end
          previous, current = current, previous
        end
        previous[b.size]
      end
    end
  end
end
