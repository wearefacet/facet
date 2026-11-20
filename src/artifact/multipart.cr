# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http/formdata"
require "../database"
require "../rbac"
require "../doctype/doctype_definition"
require "../document/artifact_refs"
require "./uploader"

module Facet
  module Artifact
    # Multipart intake for `file`-typed doctype fields.
    #
    # A multipart `POST /Api/{domain}/{doctype}` (create) or
    # `PATCH /Api/{domain}/{doctype}/{id}` (update) carries the document JSON
    # in a part named `$content` and one part per `file`-field, named by its
    # **normalized field path** (`file`, `avatars[0].file`, `items[0].file`).
    #
    # Each file part is spooled to a tempfile during parse, then uploaded
    # inside the mutation transaction via `Artifact::Uploader.upload`. The
    # returned artifact id is substituted into the document JSON at that
    # path, so the create/update service layer sees a plain document whose
    # `file` fields hold bare artifact ids — the same shape a JSON-only
    # request would carry.
    #
    # The upload and the document mutation share one transaction, so a
    # failed create rolls back both the owner row and the document (the
    # shrine object is cleaned up best-effort by the uploader). The
    # tempfiles are the caller's responsibility to delete (`cleanup`).
    module Multipart
      # A file part spooled to a tempfile. `tempfile` is rewound and ready
      # to read; the caller must delete it via `cleanup`.
      record FilePart,
        field_path : String,
        filename : String,
        tempfile : File

      # The parsed multipart body: the `$content` JSON string plus the file
      # parts.
      record ParsedMultipart,
        content : String,
        files : Array(FilePart)

      # Parses a multipart request body. Returns the `$content` JSON string
      # and the file parts (each spooled to a tempfile). Returns a
      # `ServiceError` (422) when the body is malformed or lacks a
      # `$content` part.
      #
      # The caller must call `cleanup` on the returned `ParsedMultipart` to
      # delete the spooled tempfiles.
      def self.parse(env) : ParsedMultipart | Facet::ServiceError
        content : String? = nil
        files = [] of FilePart

        begin
          ::HTTP::FormData.parse(env.request) do |part|
            if part.name == "$content"
              content = part.body.gets_to_end
            else
              filename = part.filename || part.name
              tempfile = File.tempfile("facet-multipart")
              IO.copy(part.body, tempfile)
              tempfile.flush
              tempfile.rewind
              files << FilePart.new(part.name, filename, tempfile)
            end
          end
        rescue ex : ::HTTP::FormData::Error
          return Facet::ServiceError.new(422, "Invalid multipart body: #{ex.message}")
        end

        return Facet::ServiceError.new(422, "Multipart body must include a '$content' part") if content.nil?

        ParsedMultipart.new(content, files)
      end

      # Deletes the tempfiles spooled by `parse`. Safe to call on a
      # `ParsedMultipart` whose files were already cleaned up.
      def self.cleanup(parsed : ParsedMultipart) : Nil
        parsed.files.each do |part|
          part.tempfile.close rescue nil
          File.delete?(part.tempfile.path)
        end
      end

      # Uploads every file part and substitutes the returned artifact ids
      # into the `$content` JSON at their normalized field paths. Returns
      # the substituted document JSON.
      #
      # Runs inside the caller's transaction (`db` is the transaction-scoped
      # connection); the uploader joins it via `ignore_if_set: true`.
      #
      # On any failure (a field path that does not resolve to a `file`
      # field, an oversized upload, malformed `$content` JSON) raises
      # `UploadFailed` carrying the `ServiceError`. The caller rescues it
      # *outside* the transaction so the already-written owner rows roll
      # back with it — a multipart create/update is atomic.
      #
      # `doc_id` is the document the owner rows are recorded against — the
      # route mints it for create (and passes it to `Document::Create` via
      # the `doc_id` override) or reads it from the URL for update.
      #
      # `mime_from_extension` hands the type decision to the file name —
      # the app deploy route uses it, because static build assets (html,
      # css, js) are all text and the sniffer cannot tell them apart. The
      # default stays magic-byte sniffing.
      def self.upload_files(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        parsed : ParsedMultipart,
        definition : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        mime_from_extension : Bool = false,
      ) : JSON::Any
        content = begin
          JSON.parse(parsed.content)
        rescue ex : JSON::ParseException
          raise UploadFailed.new(Facet::ServiceError.new(422, "Invalid JSON in '$content' part: #{ex.message}"))
        end

        parsed.files.each do |part|
          leaf = ::Facet::Document::ArtifactRefs.resolve_field_path(definition, part.field_path)
          leaf_type = leaf.try(&.type)
          if leaf.nil? || leaf_type.nil? || leaf_type.type_name != "file"
            raise UploadFailed.new(Facet::ServiceError.new(422, "Field '#{part.field_path}' is not a file field on #{domain}.#{doc_type}"))
          end
          view_tag = leaf.tags

          result = begin
            ::Facet::Artifact::Uploader.upload(
              db, part.tempfile, part.filename,
              auth_context, domain, doc_type, doc_id, part.field_path, view_tag,
              mime_from_extension: mime_from_extension,
            )
          rescue ex : ::Facet::Artifact::Uploader::UploadError
            raise UploadFailed.new(Facet::ServiceError.new(ex.status, ex.message.to_s))
          end
          case result
          in ::Facet::Artifact::Uploader::Result
            unless set_at_path(content, part.field_path, JSON::Any.new(result.artifact_id))
              raise UploadFailed.new(Facet::ServiceError.new(422, "Cannot place file at field '#{part.field_path}' — the document structure does not match the doctype"))
            end
          end
        end

        content
      end

      # Raised by `upload_files` on any failure so the caller's transaction
      # rolls back the already-written owner rows. Carries the `ServiceError`
      # the route surfaces as the response.
      class UploadFailed < ::Exception
        getter error : Facet::ServiceError

        def initialize(@error : Facet::ServiceError)
          super(@error.message)
        end
      end

      # ── Path setter ────────────────────────────────────────────────────

      private enum SegmentKind
        Root
        Key
        Index
        DictKey
      end

      private record Segment,
        kind : SegmentKind,
        name : String = "",
        index : Int32 = 0

      # Sets `value` at the normalized `field_path` within `root`. Returns
      # `false` when the path is malformed or a container along the path
      # does not exist (the caller surfaces a 422).
      #
      # Path grammar mirrors `Document::ArtifactRefs`:
      #   `field` → root key; `field.key` → object property;
      #   `field[i]` → array index; `field[key]` → dictionary key.
      private def self.set_at_path(root : JSON::Any, field_path : String, value : JSON::Any) : Bool
        segments = parse_path(field_path)
        return false if segments.empty?

        current = root
        segments[0...-1].each do |seg|
          nxt = descend(current, seg)
          return false if nxt.nil?
          current = nxt
        end

        set_segment(current, segments.last, value)
      end

      # Descends one non-final segment into the child container, or returns
      # `nil` when the container is absent or the segment cannot be applied.
      private def self.descend(current : JSON::Any, seg : Segment) : JSON::Any?
        case seg.kind
        when SegmentKind::Root, SegmentKind::Key, SegmentKind::DictKey
          current.as_h?.try(&.[seg.name]?)
        when SegmentKind::Index
          current.as_a?.try(&.[seg.index]?)
        end
      end

      # Sets `value` at the final segment within `current`. Returns `false`
      # when the container is absent or an array index is out of range.
      private def self.set_segment(current : JSON::Any, seg : Segment, value : JSON::Any) : Bool
        case seg.kind
        when SegmentKind::Root, SegmentKind::Key, SegmentKind::DictKey
          hash = current.as_h?
          return false if hash.nil?
          hash[seg.name] = value
          true
        when SegmentKind::Index
          arr = current.as_a?
          return false if arr.nil? || seg.index >= arr.size
          arr[seg.index] = value
          true
        else
          false
        end
      end

      # Tokenizes a normalized `field_path` into segments. Returns an empty
      # array on malformed input.
      private def self.parse_path(path : String) : Array(Segment)
        segments = [] of Segment
        cursor = 0
        size = path.size
        first = true

        while cursor < size
          if path[cursor] == '.'
            cursor += 1
            next
          end

          start_pos = cursor
          while cursor < size && path[cursor] != '.' && path[cursor] != '['
            cursor += 1
          end
          word = path[start_pos, cursor - start_pos]
          return [] of Segment if word.empty?

          if first
            segments << Segment.new(kind: SegmentKind::Root, name: word)
            first = false
          else
            segments << Segment.new(kind: SegmentKind::Key, name: word)
          end

          new_cursor = append_brackets(path, cursor, size, segments)
          return [] of Segment if new_cursor.nil?
          cursor = new_cursor
        end

        segments
      end

      # Appends any consecutive `[…]` brackets after a bareword to `segments`.
      # Returns the cursor past the brackets, or `nil` when a bracket is
      # malformed.
      private def self.append_brackets(path : String, cursor : Int32, size : Int32, segments : Array(Segment)) : Int32?
        c = cursor
        while c < size && path[c] == '['
          bracket = parse_bracket(path, c, size)
          return nil unless bracket
          c, inner = bracket
          if inner.matches?(/^\d+$/)
            segments << Segment.new(kind: SegmentKind::Index, index: inner.to_i)
          else
            segments << Segment.new(kind: SegmentKind::DictKey, name: inner)
          end
        end
        c
      end

      # Parses a single `[…]` bracket starting at `cursor` (which must point
      # at `[`). Returns `{new_cursor, inner}` or `nil` when malformed.
      private def self.parse_bracket(path : String, cursor : Int32, size : Int32) : {Int32, String}?
        cursor += 1
        start_pos = cursor
        while cursor < size && path[cursor] != ']'
          cursor += 1
        end
        return nil if cursor >= size
        inner = path[start_pos, cursor - start_pos]
        cursor += 1
        return nil if inner.empty?
        {cursor, inner}
      end
    end
  end
end
