# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../util/script_helpers"
require "./uploader"
require "../doctype/doctype_definition"
require "../document/artifact_refs"

module Facet
  module Artifact
    # SQL persistence layer for `artifacts` and `artifact_owners`.
    #
    # This module owns every read/write against the four artifact tables
    # (the `artifact_grants` table lives with `Artifact::Grants`). Keeping
    # the SQL in one place keeps the access checks in `Artifact::Access`
    # and the HTTP routes in `Artifact::Routes` free of table layout — the
    # schema lives in `db/migrations/0003_artifacts.sql` and is documented
    # in `doc/backend/artifact.md`.
    module Store
      # Marker values used to bind a standalone-upload owner row to the
      # uploading account rather than to a document. The owner row stores
      # these in its `domain` / `doc_type` / `doc_id` / `field_path`
      # columns — the schema accepts any string, and `projections` never
      # carries a row whose `doc_type` is `ACCOUNT_OWNER_DOC_TYPE`, so such
      # rows never resolve to a live document in the prune eligibility query.
      #
      # `Artifact::Access.can_read?` short-circuits an account-scoped owner
      # row by matching `owner.doc_id` against the caller's `account_id`,
      # so the uploader can read their own dangling upload without an RBAC
      # permission scoped against a synthetic `_account` doctype. Once the
      # artifact is linked into a real document, the re-attach flow writes a
      # document-scoped owner row that carries the regular RBAC gate.
      #
      # These are intentionally string constants, not a new column —
      # invariant #2 (owner rows are append-only, removed only by cascade)
      # is preserved.
      ACCOUNT_OWNER_DOMAIN     = "core"
      ACCOUNT_OWNER_DOC_TYPE   = "_account"
      ACCOUNT_OWNER_FIELD_PATH = "upload"
      Log                      = ::Log.for("facet.artifact.store")

      # ── Records ────────────────────────────────────────────────────────

      # An `artifacts` row — content facts only. Never carries anything that
      # participates in an access decision (invariant #1, see `artifact.md`).
      record Artifact,
        id : String,
        filename : String,
        mime_type : String,
        size : Int64,
        signature_sha256 : String,
        path : String,
        deleted_at : Time?,
        created_at : Time

      # An `artifact_owners` row — provenance. Drives the access check. The
      # rows are append-only; they are removed only when their document or
      # their domain is removed (invariant #2).
      record OwnerRow,
        id : String,
        artifact_id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        field_path : String,
        view_tag : Array(String)?,
        created_by : String,
        created_at : Time

      # Error shape returned by `insert_artifact`.
      # The caller decides whether to forward as 4xx or 5xx.
      record Error, status : Int32, message : String

      # ── Queries ────────────────────────────────────────────────────────

      # Loads an `artifacts` row by id. Includes tombstoned rows (callers
      # that need only live rows filter on `deleted_at` themselves). Returns
      # `nil` when the id does not exist.
      def self.find_artifact(db : DB::Connection, id : String) : Artifact?
        row = db.query_one?(
          <<-SQL,
            SELECT id, filename, mime_type, size, signature_sha256, path,
                   deleted_at, created_at
            FROM artifacts
            WHERE id = $1
          SQL
          id,
          as: {String, String, String, Int64, String, String, Time?, Time},
        )
        artifact_from_row(row) if row
      end

      # Builds an `Artifact` from the fixed column order every `artifacts`
      # SELECT in this module returns.
      private def self.artifact_from_row(row : {String, String, String, Int64, String, String, Time?, Time}) : Artifact
        id_, filename, mime, size, sha, path, deleted_at, created_at = row
        Artifact.new(
          id: id_,
          filename: filename,
          mime_type: mime,
          size: size,
          signature_sha256: sha,
          path: path,
          deleted_at: deleted_at,
          created_at: created_at,
        )
      end

      # Loads every live `artifacts` row matching `signature_sha256`,
      # ordered by `created_at` ascending. Used by the upload dedup step:
      # the first row the caller can read is reused, skipping the shrine put.
      def self.find_candidates_by_sha256(db : DB::Connection, sha256 : String) : Array(Artifact)
        rows = db.query_all(
          <<-SQL,
            SELECT id, filename, mime_type, size, signature_sha256, path,
                   deleted_at, created_at
            FROM artifacts
            WHERE signature_sha256 = $1 AND deleted_at IS NULL
            ORDER BY created_at ASC
          SQL
          sha256,
          as: {String, String, String, Int64, String, String, Time?, Time},
        )
        rows.map { |row| artifact_from_row(row) }
      end

      # Loads every live `artifact_owners` row for the given artifact.
      # Used by `Artifact::Access.can_read?` to walk provenance.
      def self.find_owner_rows(db : DB::Connection, artifact_id : String) : Array(OwnerRow)
        rows = db.query_all(
          <<-SQL,
            SELECT id, artifact_id, domain, doc_type, doc_id, field_path,
                   view_tag, created_by, created_at
            FROM artifact_owners
            WHERE artifact_id = $1
            ORDER BY created_at ASC
          SQL
          artifact_id,
          as: {String, String, String, String, String, String, JSON::Any?, String, Time},
        )
        rows.map { |row| owner_row_from_row(row) }
      end

      # Builds an `OwnerRow` from the fixed column order every
      # `artifact_owners` SELECT in this module returns.
      private def self.owner_row_from_row(row : {String, String, String, String, String, String, JSON::Any?, String, Time}) : OwnerRow
        id_, aid, domain, doc_type, doc_id, field_path, view_tag_json, created_by, created_at = row
        OwnerRow.new(
          id: id_,
          artifact_id: aid,
          domain: domain,
          doc_type: doc_type,
          doc_id: doc_id,
          field_path: field_path,
          view_tag: parse_view_tag(view_tag_json),
          created_by: created_by,
          created_at: created_at,
        )
      end

      # Loads a single `artifact_owners` row by id. Returns `nil` when the
      # row does not exist. Used by the publish / revoke grants flow.
      def self.find_owner_row(db : DB::Connection, owner_id : String) : OwnerRow?
        row = db.query_one?(
          <<-SQL,
            SELECT id, artifact_id, domain, doc_type, doc_id, field_path,
                   view_tag, created_by, created_at
            FROM artifact_owners
            WHERE id = $1
          SQL
          owner_id,
          as: {String, String, String, String, String, String, JSON::Any?, String, Time},
        )
        owner_row_from_row(row) if row
      end

      # Returns true when a document projection row exists and is not
      # soft-deleted. The access check needs this to fail-closed an owner
      # whose underlying document was deleted (otherwise a tombstoned
      # document would keep bytes alive forever — see `doc/backend/artifact.md`).
      def self.document_live?(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Bool
        exists = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL LIMIT 1",
          domain, doc_type, doc_id,
          as: Int32,
        )
        !exists.nil?
      end

      # ── Inserts ────────────────────────────────────────────────────────

      # Inserts a new `artifacts` row. The caller supplies the `id` (a
      # minted ULID) so the shrine object key — which already references the
      # id — stays the source of truth. The id is also the partition key for
      # `artifact_owners` / `artifact_grants` / `artifact_references` (all FK
      # `ON DELETE CASCADE`), so supplying it on INSERT avoids a messy
      # post-insert UPDATE that would fire the FK constraint.
      #
      # The caller must have verified that no readable candidate exists —
      # dedup is enforced above this layer (the dedup index on
      # `signature_sha256` is NOT unique by design; two
      # unreadable-from-each-other uploaders may legitimately store the same
      # bytes).
      def self.insert_artifact(
        db : DB::Connection,
        id : String,
        filename : String,
        mime_type : String,
        size : Int64,
        signature_sha256 : String,
        path : String,
      ) : String
        db.query_one(
          <<-SQL,
            INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id
          SQL
          id, filename, mime_type, size, signature_sha256, path,
          as: String,
        )
      end

      # Inserts an `artifact_owners` row. Used by the upload flow and the
      # owner-append flows (`Document::Copy`, `Domain::Publish`).
      #
      # The caller supplies the normalized `field_path` (built by the same
      # normalizer as `Document::ArtifactRefs.extract_from_content`) and the
      # `view_tag` snapshot (the `FieldDefinition#tags` of the field at
      # upload time). Both are mandatory: `field_path` fails closed when it
      # stops resolving against the doctype (the access rule reads it), and
      # `view_tag` is the snapshot that prevents loosening tags from
      # retroactively widening previously-tighter artifacts.
      #
      # This is the **only** public owner-row insert in the module, and it
      # is deliberately idempotent. Re-uploading identical bytes to a
      # provenance that already owns them (e.g. the same account bound via
      # the standalone upload route, or the same document field) must
      # collapse to a no-op: the provenance already exists (invariant #2).
      # Rescuing a UNIQUE violation instead would abort the caller's
      # transaction in PostgreSQL and silently roll back the whole mutation,
      # so the idempotency is enforced at the SQL layer with
      # `ON CONFLICT DO NOTHING`.
      def self.insert_owner_row_idempotent(
        db : DB::Connection,
        artifact_id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        field_path : String,
        view_tag : Array(String)?,
        created_by : String,
      ) : Nil
        tag_json =
          if view_tag && !view_tag.empty?
            JSON.build do |b|
              b.array { view_tag.each { |t| b.string(t) } }
            end
          else
            nil
          end

        db.exec(
          <<-SQL,
            INSERT INTO artifact_owners (artifact_id, domain, doc_type, doc_id,
                                         field_path, view_tag, created_by)
            VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)
            ON CONFLICT (artifact_id, domain, doc_type, doc_id, field_path)
            DO NOTHING
          SQL
          artifact_id, domain, doc_type, doc_id, field_path, tag_json, created_by,
        )
      end

      # Atomically inserts the `artifacts` row (if new) and the
      # `artifact_owners` row. The caller has already decided whether to
      # dedup (skip the artifacts insert) or to write a fresh row — the
      # decision is captured by `ReuseDecision`.
      #
      # Inside the caller's transaction, so a rollback undoes both the
      # owner row and any inserted artifacts row. Best-effort shrine
      # delete of a put-but-rolled-back object is the caller's
      # responsibility (the database does not manage the object store).
      def self.persist_uploaded(
        db : DB::Connection,
        artifact : UploadPayload,
      ) : PersistResult
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          kind = artifact.kind
          case kind
          in PersistKind::ReuseCandidate
            # No artifacts insert — we are reusing an existing row.
            artifact_id = artifact.reuse_artifact_id
          in PersistKind::InsertFresh
            artifact_id = insert_artifact(
              txn,
              id: artifact.id,
              filename: artifact.filename,
              mime_type: artifact.mime_type,
              size: artifact.size,
              signature_sha256: artifact.signature_sha256,
              path: artifact.path,
            )
          end

          insert_owner_row_idempotent(
            txn,
            artifact_id: artifact_id,
            domain: artifact.domain,
            doc_type: artifact.doc_type,
            doc_id: artifact.doc_id,
            field_path: artifact.field_path,
            view_tag: artifact.view_tag,
            created_by: artifact.created_by,
          )

          PersistResult.new(artifact_id: artifact_id)
        end
      end

      # ── Internal types ────────────────────────────────────────────────

      enum PersistKind
        ReuseCandidate
        InsertFresh
      end

      # Input to `persist_uploaded`. Encapsulates the dedup-or-insert
      # decision and the owner-row values in one record so the persist
      # path reads top-to-bottom.
      record UploadPayload,
        kind : PersistKind,
        id : String,
        filename : String,
        mime_type : String,
        size : Int64,
        signature_sha256 : String,
        path : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        field_path : String,
        view_tag : Array(String)?,
        created_by : String,
        reuse_artifact_id : String = ""

      record PersistResult, artifact_id : String

      # Parses the `view_tag` column (a `JSON::Any` either nil, JSON null,
      # or an array of strings) into the typed form used outside this
      # module.
      private def self.parse_view_tag(raw : JSON::Any?) : Array(String)?
        return nil if raw.nil?
        arr = raw.as_a?
        return nil unless arr
        arr.map(&.as_s)
      end
    end
  end
end
