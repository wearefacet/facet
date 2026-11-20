# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "csv"
require "json"
require "../config"
require "../database"
require "../rbac"
require "../doctype/definition_store"
require "../util/script_helpers"
require "./artifacts"
require "./csv_serializer"

module Facet
  module ImportExport
    # Import staging for the HTTP import route. This module reads the
    # capped request body, parses the file structure, builds the row→id
    # manifest, and stores the file and the manifest as artifacts. A
    # failure returns a `ServiceError` with its HTTP status, and the route
    # renders it. No cell decode happens here — the import job decodes the
    # cells; this pass rejects a file no job could ever import.
    module Staging
      # `413` when the upload exceeds `artifact.max_upload_bytes` — the
      # same status and message the upload routes answer, so one
      # client-side rule covers both. The cap is checked per chunk, before
      # the whole body ever sits in memory.
      def self.read_capped_body(env) : String | BodyError
        max_bytes = Config.instance.artifact.max_upload_bytes

        io = env.request.body
        return BodyError.new(422, "Import requires a request body") if io.nil?

        String.build do |str|
          buf = Bytes.new(65_536)
          total = 0_i64
          loop do
            read = io.read(buf)
            break if read == 0
            total += read
            if total > max_bytes
              return BodyError.new(413, "Upload exceeds the maximum allowed size (#{max_bytes} bytes)")
            end
            str.write(buf[0, read])
          end
        end
      end

      record BodyError, status : Int32, message : String

      # The synchronous parse + manifest build + artifact staging.
      # Structural failures answer `422`/`404`: an unknown doctype, a
      # sidecar/member_of doctype (the flat-import guard), a malformed
      # CSV/JSON row. On success the file and the manifest store as
      # artifacts owned by the requesting account — the payload carries
      # ids only, never row content.
      def self.stage_import(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        format : String,
        file_text : String,
        auth : RBAC::AuthContext,
      ) : ServiceError | StagedResult
        defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
        if defn.nil?
          return ServiceError.new(404, "Unknown doctype: #{domain}.#{doc_type}")
        end
        if defn.member_of
          return ServiceError.new(422, "Document '#{doc_type}' belongs to '#{defn.member_of}'; import it through the parent's route")
        end
        if defn.sidecar
          return ServiceError.new(422, "Sidecar doctypes cannot be imported through the flat route")
        end

        manifest = structural_parse(format, file_text, defn)
        return ServiceError.new(manifest.status, manifest.message) if manifest.is_a?(StructuralError)

        file_artifact = ImportExport::Artifacts.put(
          db, IO::Memory.new(file_text),
          "#{domain}.#{doc_type}.#{format}",
          format == "csv" ? "text/csv" : "application/json",
          auth,
        )
        manifest_artifact = ImportExport::Artifacts.put(
          db, IO::Memory.new({"ids" => manifest.ids, "supplied" => manifest.supplied}.to_json),
          "#{domain}.#{doc_type}.manifest.json",
          "application/json",
          auth,
        )

        StagedResult.new(
          file_artifact: file_artifact,
          manifest_artifact: manifest_artifact,
          row_count: manifest.ids.size,
        )
      end

      # One staged import run. Both artifacts are ownerless rows
      # (`ImportExport::Artifacts.put`); `row_count` feeds the `202` body.
      record StagedResult,
        file_artifact : ImportExport::Artifacts::Put,
        manifest_artifact : ImportExport::Artifacts::Put,
        row_count : Int32

      # One manifest row pairing. `supplied` records whether the file row
      # carried the id itself (the caller named the document) or the id was
      # generated at enqueue time — the provenance the genonly guard reads
      # at execute time.
      private record Manifest, ids : Array(String), supplied : Array(Bool)

      # A structural parse failure with its HTTP status. Message carries
      # the row number when one is attributable.
      private record StructuralError, status : Int32, message : String

      # Parses the file structure and builds the row→id manifest: the id
      # from the row's `id` column / member, a generated ULID when absent.
      # No cell decode here — the job decodes; this pass only fails loud on
      # a file no job could ever import.
      private def self.structural_parse(
        format : String,
        file_text : String,
        defn : Doctype::DoctypeDefinition,
      ) : Manifest | StructuralError
        if format == "csv"
          structural_parse_csv(file_text, defn)
        else
          structural_parse_json(file_text, defn)
        end
      end

      private def self.structural_parse_csv(
        file_text : String,
        defn : Doctype::DoctypeDefinition,
      ) : Manifest | StructuralError
        parsed = CSV.parse(file_text)
        return StructuralError.new(422, "CSV file carries no header row") if parsed.empty?

        headers = parsed[0].uniq!
        # The header must be exactly the codec's contract: a leading id
        # column, then the full declared-field list. Import accepts every
        # declared field regardless of the caller's field visibility — the
        # write plane refuses an invisible write later, and a
        # server-managed column is dropped by decode.
        expected = Facet::ImportExport::CsvSerializer.declared_header(defn)
        unknown = (headers - expected - ["id"])
        return StructuralError.new(422, "CSV header carries unknown column(s): #{unknown.join(", ")}") unless unknown.empty?

        ids = [] of String
        supplied = [] of Bool
        parsed.each_with_index do |cells, i|
          next if i.zero?
          return StructuralError.new(422, "row #{i}: has #{cells.size} cells but the header declares #{headers.size} columns") if cells.size != headers.size

          id_index = headers.index("id")
          raw_id = id_index ? cells[id_index]? : ""
          has_id = !raw_id.to_s.empty?
          ids << (has_id ? raw_id.to_s : Facet::Util::ScriptHelpers.ulid)
          supplied << has_id
        end
        Manifest.new(ids, supplied)
      rescue ex : CSV::MalformedCSVError
        StructuralError.new(422, "Malformed CSV: #{ex.message}")
      end

      private def self.structural_parse_json(
        file_text : String,
        defn : Doctype::DoctypeDefinition,
      ) : Manifest | StructuralError
        parsed = JSON.parse(file_text)
        array = parsed.as_a?
        return StructuralError.new(422, "JSON file must be an array of rows") if array.nil?

        ids = [] of String
        supplied = [] of Bool
        array.each_with_index do |element, i|
          obj = element.as_h?
          return StructuralError.new(422, "row #{i + 1}: must be a JSON object") if obj.nil?

          raw_id = obj["id"]?.try(&.as_s?)
          has_id = !(raw_id.nil? || raw_id.empty?)
          ids << (has_id ? raw_id.as(String) : Facet::Util::ScriptHelpers.ulid)
          supplied << has_id
        end
        Manifest.new(ids, supplied)
      rescue ex : JSON::ParseException
        StructuralError.new(422, "Malformed JSON: #{ex.message}")
      end
    end
  end
end
