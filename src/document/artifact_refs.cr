# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../doctype/doctype_definition"

module Facet
  module Document
    # Reconciles the `artifact_references` projection for a document inside
    # the mutation transaction that created / updated / deleted it.
    #
    # `artifact_references` is prune bookkeeping only — it never participates
    # in an access decision. It is rebuilt from the mutation log: a
    # truncate-and-rebuild replay repopulates it via `Audit::Rollback`.
    #
    # Sources walked against `Doctype::DoctypeDefinition`:
    #
    # 1. **`file` fields** — a single string value (or array, when
    #    `collection: true`) holding the bare artifact id (a ULID).
    # 2. **`longtext` fields** — inline `urn:facet:artifact:<id>` links
    #    referencing an artifact. Two links to the same artifact in one
    #    field collapse to one `artifact_references` row.
    #
    # Field paths are fully qualified with array indices — `avatars[0].file`,
    # not `avatars`. The same normalizer produces `artifact_owners.field_path`
    # in the upload flow; the path-builder is a single private
    # method (`FieldPath`) so the two callers cannot diverge.
    #
    # See `doc/backend/artifact.md` for the design invariants.
    module ArtifactRefs
      # URN prefix for inline artifact links in longtext. The id segment is
      # a 26-character ULID. This is distinct from `DocURI`
      # (`urn:facet:{domain}:{Doctype}:{opaque}`) — an artifact is not a
      # document and is intentionally not parseable as one.
      URN_PREFIX = "urn:facet:artifact:"

      private ULID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/

      # Reference row used internally by the walker. The caller materializes
      # these into `artifact_references` via `set_guc` / `clear_guc`.
      private record Reference,
        artifact_id : String,
        resource_field : String

      # ── Public API ─────────────────────────────────────────────────────

      # Reconciles `artifact_references` for the document identified by
      # `(domain, resource_id)` against the post-mutation `content`.
      #
      # Runs inside the caller's transaction (`db` is the transaction-scoped
      # connection from `Database.with_transaction`). The previous references
      # for the document are deleted and the new set is inserted, so the table
      # always reflects the current content. `ON CONFLICT DO UPDATE` touches
      # `last_reference_at` so unchanged references get a fresh timestamp
      # (used by the prune window).
      #
      # `domain` is the document's domain (drives `artifact_references.domain`
      # and the resource lookup); `definition` is the doctype definition
      # (drives the recursive field walk).
      def self.set_guc(
        db : DB::Connection,
        content : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        domain : String,
        resource_id : String,
      ) : Nil
        refs = extract_from_content(content, definition)
        reconcile(db, refs, domain, resource_id)
      end

      # Clears every `artifact_references` row for the document identified by
      # `(domain, resource_id)`. Called from `Document::Delete` so a
      # tombstoned document stops holding artifact bytes alive through this
      # projection. A rollback replay repopulates on the snapshot content.
      def self.clear_guc(
        db : DB::Connection,
        domain : String,
        resource_id : String,
      ) : Nil
        db.exec(
          "DELETE FROM artifact_references WHERE domain = $1 AND resource_id = $2",
          domain, resource_id,
        )
      end

      # ── Walker ──────────────────────────────────────────────────────────

      # Walks `content` according to `definition`'s field schema and
      # returns the deduplicated list of artifact references. Container types
      # (object/array/dictionary) recurse into their nested schemas; `file`
      # and `longtext` fields contribute references directly; `child` and
      # computed (`data`) fields never contribute.
      def self.extract_from_content(
        content : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : Array(Reference)
        refs = [] of Reference
        definition.fields.each do |name, field|
          walk_field(content[name]?, field, name, refs)
        end
        refs
      end

      # Resolves a normalized `field_path` (as produced by this walker —
      # `avatars[0].file`, `props[header].image`) against a doctype
      # definition and returns the leaf `FieldDefinition`, or `nil` when
      # the path does not resolve.
      #
      # This is the read-side companion to the walker's path-builder.
      # `Artifact::Access` uses it to look up the live `view` tag on a
      # `artifact_owners.field_path` at read time, so a tightened `view`
      # takes effect immediately and an unresolvable path fails closed
      # (see `doc/backend/artifact.md`).
      #
      # Path grammar — the same shapes `walk_field` produces:
      #   `field`             → root field name
      #   `field.key`         → object property `key`
      #   `field[i]`          → array index `i` (item schema)
      #   `field[key]`        → dictionary value schema for `key`
      #
      # Mixed forms are allowed (e.g. `avatars[0].props[header].image`).
      def self.resolve_field_path(
        definition : Doctype::DoctypeDefinition,
        field_path : String,
      ) : Doctype::FieldDefinition?
        return nil if field_path.empty?
        tokens = parse_path(field_path)
        return nil if tokens.empty?

        first = tokens.first
        return nil unless first.kind.root?
        current = definition.fields[first.name]?
        return nil if current.nil?

        tokens[1..].each do |tok|
          current = resolve_token(current, tok)
          return nil if current.nil?
        end

        current
      end

      # Resolves a single path token against the current field definition.
      # Returns `nil` when the token cannot be applied (container missing,
      # key absent, or a Root token mid-path).
      private def self.resolve_token(
        current : Doctype::FieldDefinition,
        tok : PathToken,
      ) : Doctype::FieldDefinition?
        case tok.kind
        when PathTokenType::Index
          current.items
        when PathTokenType::Key
          current.properties.try(&.[tok.name]?)
        when PathTokenType::DictKey
          current.dictionary_value
        when PathTokenType::Root
          # A Root token only valid as the first element; mid-path is malformed.
          nil
        end
      end

      # Internal token representation for `resolve_field_path`. Outside this
      # module, paths are plain `String` values (see `FieldPath` note below).
      private enum PathTokenType
        Root
        Index
        Key
        DictKey
      end

      private record PathToken,
        kind : PathTokenType,
        name : String = "",
        value : Int32 = 0

      # Parses a normalized `field_path` into tokens. Returns an empty list
      # on malformed input (so `resolve_field_path` returns `nil`).
      private def self.parse_path(path : String) : Array(PathToken)
        tokens = [] of PathToken
        cursor = 0
        size = path.size
        first = true

        while cursor < size
          # Skip leading dot separators between segments, but only between
          # segments (a leading dot is malformed).
          if path[cursor] == '.'
            cursor += 1
            next
          end

          # Read until next '.', '[', or end of string → the bareword.
          start_pos = cursor
          while cursor < size && path[cursor] != '.' && path[cursor] != '['
            cursor += 1
          end
          word = path[start_pos, cursor - start_pos]
          return [] of PathToken if word.empty?

          if first
            tokens << PathToken.new(kind: PathTokenType::Root, name: word)
            first = false
          else
            tokens << PathToken.new(kind: PathTokenType::Key, name: word)
          end

          # Trailing brackets: `[i]` (array index) or `[key]` (dict key). A
          # path may carry several consecutive brackets (`a[0][1]`).
          while cursor < size && path[cursor] == '['
            bracket = parse_bracket(path, cursor, size)
            return [] of PathToken unless bracket
            cursor, inner = bracket
            tokens << bracket_token(inner)
          end
        end

        tokens
      end

      # Parses a single `[…]` bracket starting at `cursor` (which must point
      # at `[`). Returns `{new_cursor, inner}` or `nil` when the bracket is
      # malformed (unterminated or empty).
      private def self.parse_bracket(path : String, cursor : Int32, size : Int32) : {Int32, String}?
        cursor += 1 # consume '['
        start_pos = cursor
        while cursor < size && path[cursor] != ']'
          cursor += 1
        end
        return nil if cursor >= size # missing ']'
        inner = path[start_pos, cursor - start_pos]
        cursor += 1 # consume ']'
        return nil if inner.empty?
        {cursor, inner}
      end

      # Builds a token from a bracket's inner text: all-digits → array index,
      # otherwise a dictionary key.
      private def self.bracket_token(inner : String) : PathToken
        if inner.matches?(/^\d+$/)
          PathToken.new(kind: PathTokenType::Index, value: inner.to_i)
        else
          PathToken.new(kind: PathTokenType::DictKey, name: inner)
        end
      end

      # ── Private walker ──────────────────────────────────────────────────

      private def self.walk_field(
        value : JSON::Any?,
        field : Doctype::FieldDefinition,
        path : String,
        refs : Array(Reference),
      ) : Nil
        return if value.nil?
        type = field.type
        return if type.nil?

        case type.type_name
        when "file"
          extract_file_value(value, path, refs)
        when "longtext"
          extract_longtext_value(value, path, refs)
        when "array"
          walk_array_field(value, field, path, refs)
        when "object"
          walk_object_field(value, field, path, refs)
        when "dictionary"
          walk_dictionary_field(value, field, path, refs)
        end
      end

      private def self.walk_array_field(
        value : JSON::Any,
        field : Doctype::FieldDefinition,
        path : String,
        refs : Array(Reference),
      ) : Nil
        items = field.items
        return if items.nil?
        arr = value.as_a?
        return if arr.nil?

        arr.each_with_index do |el, i|
          walk_field(el, items, "#{path}[#{i}]", refs)
        end
      end

      private def self.walk_object_field(
        value : JSON::Any,
        field : Doctype::FieldDefinition,
        path : String,
        refs : Array(Reference),
      ) : Nil
        props = field.properties
        return if props.nil?
        hash = value.as_h?
        return if hash.nil?

        hash.each do |k, v|
          if sub_field = props[k]?
            walk_field(v, sub_field, "#{path}.#{k}", refs)
          end
        end
      end

      private def self.walk_dictionary_field(
        value : JSON::Any,
        field : Doctype::FieldDefinition,
        path : String,
        refs : Array(Reference),
      ) : Nil
        value_field = field.dictionary_value
        return if value_field.nil?
        hash = value.as_h?
        return if hash.nil?

        hash.each do |k, v|
          walk_field(v, value_field, "#{path}[#{k}]", refs)
        end
      end

      # Extracts references from a `file` field value. Accepts a single
      # string or an array of strings (for `collection: true`).
      private def self.extract_file_value(
        value : JSON::Any,
        path : String,
        refs : Array(Reference),
      ) : Nil
        raw = value.raw
        case raw
        when String
          append_file_reference(raw, path, refs)
        when Array(JSON::Any)
          raw.each_with_index do |el, i|
            next unless el.raw.is_a?(String)
            append_file_reference(el.as_s, "#{path}[#{i}]", refs)
          end
        end
      end

      private def self.append_file_reference(
        artifact_id : String,
        path : String,
        refs : Array(Reference),
      ) : Nil
        return unless artifact_id.matches?(ULID_RE)
        refs << Reference.new(artifact_id: artifact_id, resource_field: path)
      end

      # Extracts artifact ids from a longtext (markdown) value by scanning
      # for inline `urn:facet:artifact:<id>` links anywhere in the text —
      # both bracketed (`[label](urn:facet:artifact:…)`) and bare mentions —
      # to make the walker robust against plain-text references that don't
      # go through the markdown renderer. Collapses duplicates within the
      # field via `ON CONFLICT` at insert time; the in-memory walker keeps
      # all occurrences so the resource_field path is always the owning
      # longtext field, not the link position.
      private def self.extract_longtext_value(
        value : JSON::Any,
        path : String,
        refs : Array(Reference),
      ) : Nil
        text = value.as_s?
        return if text.nil?

        cursor = 0
        size = text.size
        while cursor < size
          found = text.index(URN_PREFIX, cursor)
          break if found.nil?

          id_start = found + URN_PREFIX.size
          id = read_ulid(text, id_start)
          if id
            refs << Reference.new(artifact_id: id, resource_field: path)
            cursor = id_start + id.size
          else
            cursor = id_start
          end
        end
      end

      # Reads a 26-char Crockford-Base32 ULID starting at `start`. Returns
      # the id string, or `nil` when the text at `start` is not a valid ULID
      # (so a stray `urn:facet:artifact:` followed by garbage is skipped
      # rather than crashing the walk).
      private def self.read_ulid(text : String, start : Int32) : String?
        return nil if start + 26 > text.size
        candidate = text[start, 26]
        candidate.matches?(ULID_RE) ? candidate : nil
      end

      # ── Reconcile ────────────────────────────────────────────────────────

      # Deletes the document's previous references and inserts the new set
      # against the caller's open transaction. `ON CONFLICT DO UPDATE`
      # touches `last_reference_at` so unchanged references get a fresh
      # timestamp. In-collection duplicates (two links to the same artifact
      # in one longtext field) collapse to a single row here.
      #
      # References to artifacts that no longer exist (a stale or fabricated
      # id pasted into a `file` field or a longtext URN) are skipped: the
      # `artifact_references.artifact_id` FK would otherwise raise and turn
      # the whole mutation into a 500. A nonexistent artifact has no bytes
      # to prune, so dropping the reference is lossless.
      private def self.reconcile(
        db : DB::Connection,
        refs : Array(Reference),
        domain : String,
        resource_id : String,
      ) : Nil
        db.exec(
          "DELETE FROM artifact_references WHERE domain = $1 AND resource_id = $2",
          domain, resource_id,
        )

        return if refs.empty?

        # Load the set of artifact ids that actually exist, in one query.
        # `WHERE id IN ($1, …)` avoids array-parameter binding; the ids are
        # caller-supplied ULIDs so interpolation is safe (validated by the
        # walker's `ULID_RE`).
        placeholders = (1..refs.size).map { |i| "$#{i}" }.join(", ")
        existing = Set(String).new(
          db.query_all(
            "SELECT id FROM artifacts WHERE id IN (#{placeholders})",
            args: refs.map(&.artifact_id),
            as: String,
          ),
        )

        refs.each do |ref|
          next unless existing.includes?(ref.artifact_id)
          db.exec(
            <<-SQL,
              INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field, last_reference_at)
              VALUES ($1, $2, $3, $4, now())
              ON CONFLICT (artifact_id, domain, resource_id, resource_field)
              DO UPDATE SET last_reference_at = now()
            SQL
            ref.artifact_id, domain, resource_id, ref.resource_field,
          )
        end
      end

      # ── Field path ──────────────────────────────────────────────────────

      # Field paths are built incrementally as plain `String` values —
      # `avatars[0].file`, `notes[1].body`, `props[header].image`. The
      # same shapes are produced by the upload flow so `artifact_owners.field_path`
      # resolves unambiguously against the doctype definition at read time.
      # Array entries get distinct paths and distinct owner rows.
      #
      # There is no `FieldPath` type: the path is the input to, and output
      # of, the walker alone, and the build rules above (root field name;
      # `.key` for object properties; `[i]` for array indices; `[key]` for
      # dictionary keys) are the canonical normalizer. The uploader
      # reuses this function rather than re-deriving paths.
    end
  end
end
