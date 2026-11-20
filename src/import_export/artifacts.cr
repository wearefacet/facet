# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"
require "json"
require "../database"
require "../rbac"
require "../util/script_helpers"
require "../artifact/uploader"
require "../artifact/store"

module Facet
  module ImportExport
    # Bytes-only artifact writer for the import/export concern.
    #
    # An export result file (and, from the import stages, the staged input
    # file and the row manifest) has no owner document: the bytes are
    # consumed by their job, not held by a projection row. The provenance
    # is the requesting account — the same `_account` owner-row convention
    # the standalone upload route uses — so the requester can read their
    # own bytes back through the artifact gateway (identity match in
    # `Artifact::Access.can_read?`), and an operator holding the
    # `download *.*` action can too (the grant binds to that owner row).
    # A system requester carries no account identity, so its artifacts
    # stay ownerless: no grant can bind, and the bytes are reachable only
    # through the job download route.
    #
    # Retention is unchanged: account-scoped owner rows never resolve
    # against `projections`, so the prune eligibility query treats these
    # artifacts exactly as before — the dangling-sweep `created_at` floor
    # (`artifact.prune_after_days`) is the retention window.
    #
    # Cleanup discipline mirrors `Artifact::Uploader.upload`: the shrine
    # put lands before the row insert (object storage cannot roll back),
    # and a failed insert deletes the object it put (best effort — the
    # `artifacts:reconcile` CLI sweeps misses).
    module Artifacts
      Log = ::Log.for("facet.import_export.artifacts")

      # The stored artifact. `path` is the shrine key; `size` the byte
      # count. `mime_type` goes on the row verbatim — the import/export
      # formats never arrive from a client, so no magic-byte sniff.
      record Put,
        artifact_id : String,
        path : String,
        size : Int64

      # Stores one byte stream as an `artifacts` row with account-scoped
      # provenance.
      #
      # The shrine put happens first; the `artifacts` row and the `_account`
      # owner row insert inside one short transaction. A system requester
      # (`requester.system?`) carries no account identity, so no owner row
      # is written — the artifact stays ownerless. On any failure after the
      # put, the object is deleted and the error re-raised. The IO must
      # support `rewind` — the digest pass and the shrine put each read it
      # once (the export temp file and the import spooled upload both do).
      def self.put(
        db : DB::Connection,
        io : IO,
        filename : String,
        mime_type : String,
        requester : ::Facet::RBAC::AuthContext,
      ) : Put
        path_uploaded : String? = nil

        begin
          # Wire the shrine storage from the config before any put — the
          # same idempotent warm-up `Artifact::Uploader.upload` runs.
          Artifact::Uploader.configure_storages!

          artifact_id = Util::ScriptHelpers.ulid

          # One pass for the digest and the size, chunked — memory stays
          # flat whatever the file size.
          digest = Digest::SHA256.new
          buf = Bytes.new(65_536)
          size = 0_i64
          while (read = io.read(buf)) > 0
            digest.update(buf[0, read])
            size += read
          end
          sha256 = digest.hexfinal
          io.rewind

          path = "#{sha256}/#{artifact_id}"

          uploaded = Shrine.upload(io, Artifact::Uploader.primary_storage_key, location: path)
          path_uploaded = uploaded.id

          Database.with_transaction(db) do
            Artifact::Store.insert_artifact(
              db, artifact_id, filename, mime_type, size, sha256, path,
            )
            unless requester.system?
              Artifact::Store.insert_owner_row_idempotent(
                db,
                artifact_id: artifact_id,
                domain: Artifact::Store::ACCOUNT_OWNER_DOMAIN,
                doc_type: Artifact::Store::ACCOUNT_OWNER_DOC_TYPE,
                doc_id: requester.account_id,
                field_path: Artifact::Store::ACCOUNT_OWNER_FIELD_PATH,
                view_tag: nil,
                created_by: requester.account_id,
              )
            end
          end

          Put.new(artifact_id: artifact_id, path: path, size: size)
        rescue ex
          Artifact::Uploader.delete(path_uploaded) if path_uploaded
          raise ex
        end
      end
    end
  end
end
