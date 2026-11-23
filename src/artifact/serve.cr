# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./store"
require "./uploader"

module Facet
  module Artifact
    # Byte serving for artifact downloads.
    #
    # `Serve` writes an artifact's bytes to an HTTP response. It has no
    # route knowledge: the caller resolves the grant and the artifact row,
    # then hands over the request env. `Routes` (the `GET /A/:gid` serve
    # route) is the only caller today.
    #
    # Responsibilities:
    #
    # - the mandatory response-hardening headers (`doc/backend/artifact.md`
    #   → Response hardening)
    # - `Content-Disposition` attachment/inline gating by MIME type
    # - HTTP range requests (`206 Partial Content`) when the storage IO is
    #   seekable, a full-body `200` response otherwise
    module Serve
      # Streams an artifact's bytes to the response with the mandatory
      # response-hardening header set and `Content-Disposition` gating by
      # MIME type. Supports HTTP range requests on the FileSystem backend
      # (other storages fall back to a full-body response).
      def self.stream_artifact(env, artifact : Facet::Artifact::Store::Artifact) : Nil
        # Open the storage IO once. Both backends return a seekable,
        # fully-buffered IO: FileSystem returns a `File`, S3 returns an
        # `IO::Memory` read through the awscr client (`Uploader.open_s3`).
        # The `Range` header is honoured when the IO responds to `seek`
        # AND `size`; otherwise the full body streams with `200 OK` and
        # no `Content-Range`.
        begin
          io = Facet::Artifact::Uploader.open(artifact.path)
        rescue Facet::Artifact::Uploader::ObjectNotFound
          # Nothing has been written yet — a clean 404 instead of a 500.
          env.response.status_code = 404
          env.response.content_type = "application/json"
          env.response.print({error: "Not Found"}.to_json)
          return
        end

        # Mandatory response headers — see `doc/backend/artifact.md` →
        # Response hardening.
        env.response.headers["X-Content-Type-Options"] = "nosniff"
        env.response.headers["Content-Security-Policy"] = "default-src 'none'; img-src 'self'; media-src 'self'"
        env.response.headers["Cache-Control"] = "private, no-store"
        env.response.headers["Accept-Ranges"] = "bytes"
        env.response.headers["Content-Type"] = artifact.mime_type

        # Filename for Content-Disposition — quote and escape per RFC 6266.
        filename_header = %(attachment; filename="#{escape_filename(artifact.filename)}")
        if Facet::Artifact::Uploader.inline_mime?(artifact.mime_type)
          env.response.headers["Content-Disposition"] = filename_header.sub("attachment", "inline")
        else
          env.response.headers["Content-Disposition"] = filename_header
        end

        # Range support. Parse `Range: bytes=START-END` and stream the
        # slice when the IO is seekable.
        range_header = env.request.headers["Range"]?
        if range_header && (range = parse_range(range_header, io))
          start_pos, end_pos, total = range
          env.response.status_code = 206
          env.response.headers["Content-Range"] = "bytes #{start_pos}-#{end_pos}/#{total}"
          env.response.headers["Content-Length"] = (end_pos - start_pos + 1).to_s
          stream_range(io, env.response, start_pos, end_pos)
        else
          env.response.status_code = 200
          if io.responds_to?(:size)
            env.response.headers["Content-Length"] = io.size.to_s
          end
          IO.copy(io, env.response)
        end
      ensure
        io.try(&.close) rescue nil
      end

      # Parses a `Range: bytes=…` header against the IO's size. Returns
      # `{start, end, total}` (inclusive end), or `nil` when the range is
      # malformed or unsatisfiable. Honours `bytes=START-` (until EOF)
      # and `bytes=-N` (last N bytes, per the spec).
      private def self.parse_range(header : String, io : IO) : {Int64, Int64, Int64}?
        return nil unless io.responds_to?(:size)
        total = io.size.to_i64
        return nil if total == 0

        match = header.match(/^bytes=(\d*)-(\d*)$/)
        return nil unless match

        start_str = match[1]
        end_str = match[2]

        start_pos : Int64
        end_pos : Int64

        if start_str.empty?
          # `bytes=-N` → last N bytes
          return nil if end_str.empty?
          n = end_str.to_i64
          return nil if n == 0
          start_pos = {total - n, 0_i64}.max
          end_pos = total - 1
        elsif end_str.empty?
          # `bytes=START-` → from START to EOF
          start_pos = start_str.to_i64
          end_pos = total - 1
        else
          start_pos = start_str.to_i64
          end_pos = {
            end_str.to_i64, total - 1,
          }.min
        end

        return nil if start_pos > end_pos || start_pos >= total
        {start_pos, end_pos, total}
      rescue ArgumentError
        nil
      end

      # Streams `end - start + 1` bytes from `io` (opened at `start_pos`)
      # to the response.
      private def self.stream_range(io : IO, response, start_pos : Int64, end_pos : Int64) : Nil
        io.seek(start_pos) if io.responds_to?(:seek)
        remaining = end_pos - start_pos + 1
        chunk = Bytes.new(4096)
        while remaining > 0
          read = io.read(chunk[0, Math.min(chunk.size.to_i64, remaining).to_i32])
          break if read == 0
          response.write(chunk[0, read])
          remaining -= read
        end
      end

      # Quotes a filename for safe inclusion in a `Content-Disposition`
      # header. Replaces `"` and `\` with `_` — RFC 6266 has a richer
      # escaping protocol, but the mime header surface is small and this
      # is enough to prevent header injection from a crafted filename.
      private def self.escape_filename(name : String) : String
        name.gsub(/["\\]/, "_")
      end
    end
  end
end
