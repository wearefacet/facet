# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../doctype/doctype_definition"
require "./uri"

module Facet
  module Document
    # Computes the `links` array for `projections` and passes it to the
    # PL/pgSQL mutation trigger via the `harness.mutation_links` GUC.
    #
    # `links` is a JSON array of canonical URN strings (`urn:facet:…`)
    # referencing documents that this projection points to. Two sources:
    #
    # 1. **Reference fields** — a single string value (or array, when
    #    `collection: true`) holding the storage id of the referenced
    #    document. The URN is built from the field's declared `doctype`
    #    (`{domain}.{Doctype}`) plus the stored id via the same rules as
    #    `DocURI.from_projection_id`.
    # 2. **Longtext fields** — inline markdown links `[label](urn:facet:…)`
    #    whose URL parses as a canonical Facet URN, plus bare `urn:facet:`
    #    mentions anywhere in the text (autolinks, reference definitions,
    #    labels containing `]`, links with a title). Non-URN URLs
    #    (`https://…`) are ignored.
    #
    # All extraction happens in Crystal (the trigger only stores the
    # precomputed array). This keeps markdown link parsing out of PL/pgSQL.
    #
    # The GUC carries a JSON array of URN strings (e.g.
    # `["urn:facet:hr:Employee:01J5X…","urn:facet:catalog:Product:01J…"]`).
    # The trigger reads it via `current_setting('harness.mutation_links', true)`
    # and stores it directly into the `links` column. When no links are
    # present, the GUC is set to `"[]"`.
    module Links
      GUC_NAME = "harness.mutation_links"

      # Bare-mention prefix scanned by the longtext extractor (pass 2).
      private URN_PREFIX = "urn:facet:"

      # Extracts the deduplicated URN array for `content` according to the
      # field schema declared on `definition`. Walks nested object/array/
      # dictionary schemas recursively. `child` fields never contribute.
      def self.extract_from_content(content : JSON::Any, definition : Doctype::DoctypeDefinition) : Array(String)
        urns = [] of String
        definition.fields.each do |name, field|
          extract_field(content[name]?, field, urns)
        end
        urns.uniq!
        urns
      end

      # Serializes the URN array as a JSON string suitable for the GUC.
      # Always returns a valid JSON array string (empty when no links).
      def self.to_guc_value(urns : Array(String)) : String
        urns.to_json
      end

      # Sets the links GUC within the current transaction. Call immediately
      # before inserting a mutation row, alongside `Document::Search.set_guc`.
      #
      # `content` is the *post-mutation* document content that the trigger
      # will persist (i.e. the merged content for updates, the original
      # content for creates, the snapshot content for snapshots).
      def self.set_guc(db : DB::Connection, content : JSON::Any, definition : Doctype::DoctypeDefinition) : Nil
        urns = extract_from_content(content, definition)
        db.exec("SELECT set_config($1, $2, true)", GUC_NAME, to_guc_value(urns))
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Walks `value` according to `field`'s schema, appending extracted
      # URN strings to `urns`. Container types (object/array/dictionary)
      # recurse into their nested schemas; reference and longtext fields
      # contribute URNs directly. `child` and computed (`data`) fields never
      # contribute.
      private def self.extract_field(value : JSON::Any?, field : Doctype::FieldDefinition, urns : Array(String)) : Nil
        return if value.nil?
        type = field.type
        return if type.nil?

        case type.type_name
        when "reference"
          extract_reference_field(value, field, urns)
        when "longtext"
          extract_longtext_value(value, urns)
        when "array"
          extract_array_field(value, field, urns)
        when "object"
          extract_object_field(value, field, urns)
        when "dictionary"
          extract_dictionary_field(value, field, urns)
        end
      end

      # Extracts URNs from a single reference field.
      private def self.extract_reference_field(value : JSON::Any, field : Doctype::FieldDefinition, urns : Array(String)) : Nil
        target = field.qualified_doctype
        return if target.nil?
        parts = target.split('.', 2)
        return unless parts.size == 2
        extract_reference_value(value, parts[0], parts[1], urns)
      end

      # Recurses into an array field's items.
      private def self.extract_array_field(value : JSON::Any, field : Doctype::FieldDefinition, urns : Array(String)) : Nil
        items = field.items
        return if items.nil?
        arr = value.as_a?
        arr.try(&.each { |el| extract_field(el, items, urns) })
      end

      # Recurses into an object field's declared properties.
      private def self.extract_object_field(value : JSON::Any, field : Doctype::FieldDefinition, urns : Array(String)) : Nil
        props = field.properties
        return if props.nil?
        hash = value.as_h?
        hash.try(&.each do |k, v|
          if sub_field = props[k]?
            extract_field(v, sub_field, urns)
          end
        end)
      end

      # Recurses into a dictionary field's typed values.
      private def self.extract_dictionary_field(value : JSON::Any, field : Doctype::FieldDefinition, urns : Array(String)) : Nil
        value_field = field.dictionary_value
        return if value_field.nil?
        hash = value.as_h?
        hash.try(&.each_value { |v| extract_field(v, value_field, urns) })
      end

      # Extracts URNs from a reference field value. Accepts either a single
      # string or an array of strings (for `collection: true`).
      private def self.extract_reference_value(value : JSON::Any, domain : String, doctype : String, urns : Array(String)) : Nil
        raw = value.raw
        case raw
        when String
          append_urn_from_reference(raw, domain, doctype, urns)
        when Array(JSON::Any)
          raw.each do |el|
            append_urn_from_reference(el.to_s, domain, doctype, urns) if el.raw.is_a?(String)
          end
        end
      end

      # Appends a URN for a single reference value if the value parses to
      # a valid `DocURI`.
      private def self.append_urn_from_reference(value : String, domain : String, doctype : String, urns : Array(String)) : Nil
        uri = DocURI.from_projection_id(domain, doctype, value)
        urns << uri.to_s if uri.valid?
      end

      # Extracts URNs from a longtext (markdown) value. Two passes:
      #
      # 1. Inline links `[label](url)` — keeps the dotted-URL form
      #    (`[Alice](hr.Employee.01BBB)`) working. Non-URN URLs
      #    (`https://…`) are ignored.
      # 2. Bare `urn:facet:` tokens anywhere in the text — catches bare
      #    mentions, autolinks (`<urn:facet:…>`), reference definitions
      #    (`[label]: urn:facet:…`), link labels containing `]`, and links
      #    with a title, none of which the bracket scanner can see. The
      #    token ends at the first character outside the URN charset, so a
      #    sentence period after a URN is trimmed before parsing.
      #
      # Both passes append canonical URNs; `extract_from_content` dedupes.
      private def self.extract_longtext_value(value : JSON::Any, urns : Array(String)) : Nil
        text = value.as_s?
        return if text.nil?

        extract_inline_links(text, urns)
        extract_urn_tokens(text, urns)
      end

      # Pass 1 — inline markdown links: `[label](url)`. We find `[`, then
      # the first `]`, then `(`, then the URL up to `)`. Labels containing
      # `]` are handled by pass 2 instead (the URL itself is a URN token).
      private def self.extract_inline_links(text : String, urns : Array(String)) : Nil
        cursor = 0
        size = text.size
        while cursor < size
          lbracket = text.index('[', cursor)
          break if lbracket.nil?
          rbracket = find_matching_rbracket(text, lbracket)
          break if rbracket.nil?
          after = rbracket + 1
          if after >= size || text[after] != '('
            cursor = after
            next
          end
          rparen = text.index(')', after + 1)
          break if rparen.nil?
          url = text[(after + 1)...rparen]
          unless url.empty?
            uri = DocURI.parse(url)
            urns << uri.to_s if uri && uri.valid?
          end
          cursor = rparen + 1
        end
      end

      # Pass 2 — bare `urn:facet:` tokens. Reads the maximal run of URN
      # charset characters (NSS segments joined by `:`, opaque ids holding
      # `.`/`_`/`-`), then an optional `?state=` q-component. Trailing
      # sentence punctuation the charset admits (`.` and `:`) is trimmed —
      # no real opaque id ends with either.
      private def self.extract_urn_tokens(text : String, urns : Array(String)) : Nil
        cursor = 0
        loop do
          found = text.index(URN_PREFIX, cursor)
          break if found.nil?

          end_idx = scan_urn_token(text, found + URN_PREFIX.size)
          while end_idx > found && (text[end_idx - 1] == '.' || text[end_idx - 1] == ':')
            end_idx -= 1
          end
          token = text[found...end_idx]
          if (uri = DocURI.parse(token)) && uri.valid?
            urns << uri.to_s
            cursor = found + token.size
          else
            cursor = found + URN_PREFIX.size
          end
        end
      end

      # Advances past the URN body starting at `start`: the NSS segments and
      # separators, then `?state=` plus an alphanumeric run when present.
      # Returns the end index (exclusive).
      private def self.scan_urn_token(text : String, start : Int32) : Int32
        i = start
        size = text.size
        while i < size && urn_char?(text[i])
          i += 1
        end
        if i < size && i + 7 <= size && text[i, 7] == "?state="
          j = i + 7
          while j < size && text[j].alphanumeric?
            j += 1
          end
          i = j if j > i + 7
        end
        i
      end

      # True when `ch` may appear in a URN token: NSS segments joined by `:`
      # (domain lowercase-dash, doctype CamelCase, opaque `[A-Za-z0-9._-]`).
      private def self.urn_char?(ch : Char) : Bool
        ch.alphanumeric? || ch == '.' || ch == '_' || ch == '-' || ch == ':'
      end

      # Finds the `]` that closes the `[` at `start`. Returns nil if none.
      # Does not support nested brackets inside the label text — the first
      # `]` after `start` is treated as the closer.
      private def self.find_matching_rbracket(text : String, start : Int32) : Int32?
        text.index(']', start + 1)
      end
    end
  end
end
