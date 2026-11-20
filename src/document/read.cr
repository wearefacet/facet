# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "opentelemetry"
require "../error"
require "../doctype/doctype_definition"
require "../doctype/derived_operators"
require "../mutation/client"
require "../iam/helpers"
require "./migrate"
require "../rbac"

module Facet
  module Document
    # Service for reading a single document by its ID.
    #
    # Automatically performs lazy schema migration when the document's
    # stored schema_version is lower than the doctype definition's
    # current schema_version.
    module Read
      record Result,
        projection : Mutation::Client::Projection,
        migrated : Bool

      # Reads a document, applying lazy migration if needed.
      #
      # Requires an `auth_context` for RBAC authorization. On denied access
      # returns 404 (non-disclosing). Applies field-level read mask.
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool = false,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.read" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["doc_id"] = doc_id

          # 0. Authorize the read (non-disclosing 404 on denial).
          # `skip_authorization` is set by callers that have ALREADY enforced
          # an equivalent (or stronger) gate at a higher layer — today only
          # the nested per-document sidecar route, which runs the host read
          # gate plus the nested sidecar grant before reaching this point.
          # Field-level read masking (`visible_tags`) is NOT skipped.
          if err = authorize_read(db, domain, doc_type, doc_id, auth_context, skip_authorization, authorize_path, authorize_root_id)
            return Telemetry.record_error(span, err)
          end

          # 1. Fetch the doctype definition
          doctype_id = "#{domain}.#{doc_type}"
          definition = Doctype::DefinitionStore.fetch!(db, doctype_id)
          return Telemetry.record_error(span, definition) if definition.is_a?(Facet::ServiceError)

          # 2. Fetch the projection
          proj = fetch_projection(db, domain, doc_type, doc_id)
          if proj.is_a?(Facet::ServiceError)
            return Telemetry.record_error(span, proj)
          end

          # 3. Check if document is deleted
          if deleted_at = proj.deleted_at
            return Telemetry.record_error(span, tombstone_error(doc_id, deleted_at, proj.display_name))
          end

          # 4+5. Run lazy migration (with the pre-flight re-check) when the
          # projection's schema_version lags the definition. The migration
          # block escalates as one unit: the row lock, the migration write,
          # and the follow-up read of the migrated row all run on a nested
          # rw connection (the read-only scope must never write). A current
          # document never escalates — the check is an in-memory comparison.
          if Document::Migrate.migration_needed?(proj, definition)
            result = Database.with_db(:read_write) do |rw_db|
              migrated = migrate_read(rw_db, span, domain, doc_type, doc_id, definition, proj, auth_context)
              Telemetry.record_error(span, migrated) if migrated.is_a?(Facet::ServiceError)
              migrated
            end
            result
          else
            result = build_read_result(db, proj, definition.as(Doctype::DoctypeDefinition), auth_context, false)
            span["migrated"] = result.migrated
            result
          end
        end
      end

      # Re-fetches the projection under a row lock (another fiber may have
      # migrated it already) and rejects tombstones. Returns the fresh
      # projection or the error to surface.
      private def self.refetch_after_migration_lock(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Mutation::Client::Projection | Facet::ServiceError
        db.exec("SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE", domain, doc_type, doc_id)
        proj = fetch_projection(db, domain, doc_type, doc_id)
        return proj if proj.is_a?(Facet::ServiceError)
        if deleted_at = proj.deleted_at
          return tombstone_error(doc_id, deleted_at, proj.display_name)
        end
        proj
      end

      # Runs lazy migration for a read whose schema_version lags the
      # definition: re-checks the migration-blocked marker under the row
      # lock, then either serves stale data or replays the migrations.
      private def self.migrate_read(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        doc_id : String,
        definition : Doctype::DoctypeDefinition,
        proj : Mutation::Client::Projection,
        auth_context : RBAC::AuthContext,
      ) : Result | Facet::ServiceError
        if Document::Migrate.migration_blocked?(proj)
          span["migration_blocked"] = true
        else
          proj = refetch_after_migration_lock(db, domain, doc_type, doc_id)
          return proj if proj.is_a?(Facet::ServiceError)
        end

        if Document::Migrate.migration_blocked?(proj)
          # Previously blocked — serve stale data
          result = build_read_result(db, proj, definition, auth_context, false)
          span["migrated"] = result.migrated
          return result
        end

        migrate_result = Document::Migrate.call(db, definition, proj)
        case migrate_result
        in Document::Migrate::Result
          result = build_read_result(db, migrate_result.projection, definition, auth_context, !migrate_result.migration_ids.empty?)
          span["migrated"] = result.migrated
          result
        in Facet::ServiceError
          # Mark the document so we don't retry on every read
          marked_proj = Document::Migrate.write_migration_error_marker(db, definition, proj, migrate_result.message, migrate_result.details)
          result = build_read_result(db, marked_proj, definition, auth_context, false)
          span["migration_blocked"] = true
          span["migrated"] = false
          result
        end
      end

      # Step-0 read gate. Returns `nil` when the caller is authorized, or the
      # non-disclosing 404 error otherwise. `skip_authorization` bypasses the
      # enforcer for callers that already enforced a stronger gate.
      # `authorize_path` overrides the gate path — the composition path on
      # nested child routes, the bare path on flat routes.
      # `authorize_root_id` is the `core.DocType` row id the nested route
      # descends from — see `ReadEnforcer.authorized?`.
      private def self.authorize_read(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
      ) : Facet::ServiceError?
        return nil if skip_authorization

        # Class-level denial — no read permission on the doctype at all
        # (role denial or app-grant ceiling) — answers 403 before any row
        # state is read, the same gate state the write side denies with
        # 403. Knowing the doctype exists is acceptable; the document
        # answer stays uniform for these callers either way.
        if RBAC::ReadEnforcer.read_denied?(domain, doc_type, auth_context, authorize_path, authorize_root_id)
          IAM::Helpers.write_layer1_denial(db, auth_context, "read", domain, authorize_path || [doc_type])
          return Facet::ServiceError.new(403, "Forbidden")
        end

        return nil if RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context, authorize_path, authorize_root_id)

        # An app-scoped denial is audited with app attribution.
        # No-op for ordinary browser-session denials (no app_id attached).
        IAM::Helpers.write_layer1_denial(db, auth_context, "read", domain, [doc_type])
        # The caller holds a read grant but cannot see this row (or the row
        # does not exist) — the non-disclosing 404 keeps an inaccessible
        # document indistinguishable from a missing one.
        Facet::ServiceError.new(404, "Document #{doc_id} not found")
      end

      # Builds a Read::Result with field-level read mask applied.
      private def self.build_read_result(
        db : DB::Connection,
        projection : Mutation::Client::Projection,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        migrated : Bool,
      ) : Result
        masked_content = RBAC::ReadEnforcer.mask_content(projection.content, auth_context, definition)
        masked_projection = projection.with_content(masked_content)
        Result.new(projection: masked_projection, migrated: migrated)
      end

      # Fetches a projection by domain/doc_type/id, rescuing a missing row
      # to a `404` `ServiceError` with the bare doc id in the message.
      private def self.fetch_projection(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Mutation::Client::Projection | Facet::ServiceError
        Mutation::Client.fetch_projection_or_404(db, domain, doc_type, doc_id, "Document #{doc_id} not found")
      end

      # Builds the tombstone error for a deleted document. The `410` body
      # carries the surviving label and deletion timestamp so clients (e.g.
      # the QuickView drawer) can render a "this has been deleted" state
      # without the content. Content is never included.
      private def self.tombstone_error(doc_id : String, deleted_at : Time, display_name : String?) : Facet::ServiceError
        meta = {"deleted_at" => deleted_at.to_rfc3339} of String => String
        if (label = display_name) && !label.empty?
          meta["display_name"] = label
        end
        Facet::ServiceError.new(410, "Document #{doc_id} was deleted", nil, meta)
      end
    end
  end
end
